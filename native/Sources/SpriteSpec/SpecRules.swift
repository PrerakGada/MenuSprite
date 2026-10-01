import AgentProtocol
import Foundation
import SystemMonitoring

extension SpecCompiler {
    static let ruleKeys = ["id", "name", "enabled", "when", "match", "then", "cases", "else"]
    static let caseKeys = ["when", "match", "then"]
    static let ruleActionKeys = ["target", "color", "hide", "show", "icon", "text", "opacity"]

    /// If / otherwise-if / otherwise rules. A rule's branches, conditions and actions have no ids in the
    /// spec (a condition is part of a sentence): they keep the ids of the rule with the same id in the
    /// sprite being replaced, position by position, and are derived from the rule's id otherwise. So a
    /// sprite read back and applied unchanged is the same down to the last id, and a spec applied twice
    /// builds the same design.
    func parseRules(_ raw: JSONValue?, face: DesignNode, board: BoardDesign?, existing: SpriteDesign?) -> [SpriteRule] {
        guard let raw else { return [] }
        guard let items = raw.items else {
            report.error("rules", "rules is a list ([…]) of rules, not \(raw.typeName).")
            return []
        }
        let targets = Set(face.flattened.map(\.id) + (board?.root.flattened.map(\.id) ?? []))
        existingConditions = Set(existing?.rules.flatMap { $0.branches.flatMap(\.conditions) }.map(Self.conditionKey) ?? [])
        var rules: [SpriteRule] = []
        var named: [String: String] = [:]
        for (index, item) in items.enumerated() {
            let path = SpecPath.index("rules", index)
            guard let object = SpecObject(item, path: path, report: report, what: "A rule") else { continue }
            var rule = SpriteRule(id: "", branches: [])
            if let id = object.string("id") {
                if !Self.isNodeID(id) { report.error(object.path("id"), "“\(id)” is not an id: use letters, digits, _ and -.") }
                else if let first = named[id] { report.error(object.path("id"), "Two rules have the id “\(id)” (the first is \(first)).") }
                else { named[id] = path; rule.id = id }
            }
            rule.name = object.string("name") ?? ""
            rule.enabled = object.bool("enabled") ?? true
            let simple = object["when"] != nil || object["then"] != nil
            if let cases = object["cases"] {
                if simple { report.error(path, "A rule has when and then, or cases, not both.", hint: "move the when and then into cases") }
                if let list = cases.items {
                    for (offset, item) in list.enumerated() {
                        guard let entry = SpecObject(item, path: SpecPath.index(object.path("cases"), offset), report: report, what: "A case") else { continue }
                        rule.branches.append(branch(entry, targets: targets))
                        entry.checkKeys(Self.caseKeys, what: "a case")
                    }
                } else {
                    report.error(object.path("cases"), "cases is a list of {\"when\": …, \"then\": […]}, not \(cases.typeName).")
                }
            } else if simple {
                rule.branches = [branch(object, targets: targets)]
            } else if object["else"] == nil {
                report.error(path, "A rule needs when and then, or cases.",
                             hint: "{\"when\": \"cpu > 80\", \"then\": [{\"target\": \"value\", \"color\": \"red\"}]}")
            }
            if object["match"] != nil, object["cases"] != nil { report.warning(object.path("match"), "match belongs on each case.") }
            if let otherwise = object["else"] { rule.otherwise = actions(otherwise, path: object.path("else"), targets: targets) }
            object.checkKeys(Self.ruleKeys, what: "a rule")
            rules.append(rule)
        }

        var taken = Set(named.keys)
        for index in rules.indices where rules[index].id.isEmpty { rules[index].id = Self.unique("r\(index)", &taken) }
        for index in rules.indices {
            let id = rules[index].id
            let old = existing?.rules.first { $0.id == id }
            for k in rules[index].branches.indices {
                let oldBranch = old?.branches[safe: k]
                rules[index].branches[k].id = oldBranch?.id ?? "\(id)-c\(k)"
                for j in rules[index].branches[k].conditions.indices {
                    rules[index].branches[k].conditions[j].id = oldBranch?.conditions[safe: j]?.id ?? "\(id)-c\(k)-w\(j)"
                }
                for m in rules[index].branches[k].actions.indices {
                    rules[index].branches[k].actions[m].id = oldBranch?.actions[safe: m]?.id ?? "\(id)-c\(k)-a\(m)"
                }
            }
            for m in rules[index].otherwise.indices {
                rules[index].otherwise[m].id = old?.otherwise[safe: m]?.id ?? "\(id)-e\(m)"
            }
        }
        return rules
    }

    /// One `when` with its `then`, from a case or from the rule itself.
    private func branch(_ object: SpecObject, targets: Set<String>) -> RuleBranch {
        var branch = RuleBranch(id: "", conditions: [], actions: [])
        let whenPath = object.path("when")
        var joined: RuleMatch?
        if let raw = object.raw("when"), !raw.isNull {
            if let text = raw.string {
                do {
                    let parsed = try SpecWhen.parse(text)
                    joined = parsed.match
                    if parsed.conditions.isEmpty { report.warning(whenPath, "An empty when never holds.") }
                    for condition in parsed.conditions {
                        guard checkCondition(condition, path: whenPath) else { continue }
                        branch.conditions.append(RuleCondition(id: "", variable: condition.variable, aspect: condition.aspect,
                                                               comparison: condition.comparison, operand: condition.operand))
                    }
                } catch {
                    report.error(whenPath, error.message, hint: error.hint)
                }
            } else {
                report.error(whenPath, "when is a sentence in quotes, such as \"cpu > 80\", not \(raw.typeName).")
            }
        } else {
            report.error(object.path, "This needs a when: the condition, such as \"cpu > 80\".")
        }
        branch.match = joined ?? .all
        if let match = choice(object, "match", RuleMatch.self) {
            if let joined, joined != match {
                report.error(object.path("match"), "match says \(match.rawValue), but the when joins with \(joined == .all ? "and" : "or").")
            }
            branch.match = match
        }
        if let then = object["then"] {
            branch.actions = actions(then, path: object.path("then"), targets: targets)
        } else if object.raw("then") == nil {
            report.warning(object.path, "Nothing happens when this holds: add \"then\".")
        }
        return branch
    }

    static func conditionKey(_ condition: RuleCondition) -> String {
        "\(condition.variable)\u{1}\(condition.aspect.rawValue)\u{1}\(condition.comparison.rawValue)\u{1}\(condition.operand)"
    }

    /// Whether a condition can be kept. One that can never hold is an error, unless the sprite being replaced
    /// already has it: the studio saves such conditions (it lets "pace" meet "above"), and reading a sprite back
    /// must not refuse what the studio made. Those are kept, with a warning.
    private func checkCondition(_ condition: SpecWhen.Condition, path: String) -> Bool {
        guard variableIDs.contains(condition.variable) else {
            report.error(path, "“\(condition.variable)” names no value.", hint: valueHint(condition.variable))
            return false
        }
        let known = existingConditions.contains(Self.conditionKey(RuleCondition(id: "", variable: condition.variable, aspect: condition.aspect,
                                                                                 comparison: condition.comparison, operand: condition.operand)))
        func refuse(_ message: String, hint: String?) -> Bool {
            if known { report.warning(path, message + " It never holds.", hint: hint); return true }
            report.error(path, message, hint: hint)
            return false
        }
        if condition.aspect == .pace, let variable = variable(condition.variable),
           variable.readingID.flatMap(environment.metric)?.group != .ai {
            report.warning(path, "\(condition.variable).pace is reported only for Claude and Codex limits, so it is never known here.")
        }
        guard condition.comparison.isNumeric else { return true }
        let symbol = SpecWhen.symbol(condition.comparison)
        if condition.aspect == .pace {
            return refuse("\(condition.variable).pace is a word (on track, ahead or over), so “\(symbol)” cannot compare it.",
                          hint: "use == or != with 'on track', 'ahead' or 'over'")
        }
        let operand = condition.operand.trimmingCharacters(in: .whitespaces)
        if operand.isEmpty {
            // What the studio saves for a condition just added: kept, since it is harmless.
            report.warning(path, "“\(symbol)” compares \(condition.variable) with nothing, so it never holds.", hint: "add a number, as in \(condition.variable) \(symbol) 80")
            return true
        }
        guard let number = Double(operand.replacingOccurrences(of: ",", with: ".")) else {
            let percent = operand.hasSuffix("%") && Double(operand.dropLast()) != nil
            return refuse("“\(symbol)” compares numbers, and “\(condition.operand)” is not one.",
                          hint: percent ? "write \(operand.dropLast()), without the %" : "use == or contains to compare text")
        }
        // A comma is a decimal point here ("0,5"), so a thousands separator silently reads as a fraction.
        if operand.wholeMatch(of: /-?\d{1,3},\d{3}/) != nil {
            report.warning(path, "“\(operand)” is read as \(SpecFormat.number(number)): a comma is a decimal point here.",
                           hint: "write \(operand.replacingOccurrences(of: ",", with: "")) for a number in the thousands")
        }
        return true
    }

    /// A list of `{target, effect…}` objects (one object alone is read as a list of one). Each effect
    /// becomes its own action, in the order written.
    private func actions(_ raw: JSONValue, path: String, targets: Set<String>) -> [RuleAction] {
        let items: [JSONValue]
        if let list = raw.items { items = list }
        else if raw.members != nil { items = [raw] }
        else {
            report.error(path, "This is a list of actions such as [{\"target\": \"value\", \"color\": \"red\"}], not \(raw.typeName).")
            return []
        }
        var result: [RuleAction] = []
        for (index, item) in items.enumerated() {
            guard let object = SpecObject(item, path: SpecPath.index(path, index), report: report, what: "An action") else { continue }
            var target: String?
            if let text = object.string("target") {
                if targets.contains(text) { target = text }
                else {
                    report.error(object.path("target"), "No face node or board block has the id “\(text)”.",
                                 hint: report.hint(text, in: explicitIDs.keys.sorted()) ?? "give the piece an \"id\" and name it here")
                }
            } else if object["target"] == nil {
                report.error(object.path, "An action names its target: the id of a face node or board block.")
            }
            var effects: [(RuleActionKind, String?)] = []
            var tried = false
            for member in object.members where member.key != "target" && !member.value.isNull {
                let effectPath = object.path(member.key)
                if Self.ruleActionKeys.contains(member.key) { tried = true }
                switch member.key {
                case "color":
                    if let color = color(member.value, path: effectPath, keywords: ["inherit", "auto"]) { effects.append((.color, color)) }
                case "hide", "show":
                    if member.value == .bool(true) { effects.append((member.key == "hide" ? .hide : .show, nil)) }
                    else if member.value == .bool(false) { report.error(effectPath, "Write \(member.key == "hide" ? "show" : "hide"): true instead of \(member.key): false.") }
                    else { report.error(effectPath, "“\(member.key)” takes true.") }
                case "icon":
                    if let symbol = member.value.string, !symbol.isEmpty { effects.append((.symbol, symbol)); checkSymbol(symbol, path: effectPath) }
                    else { report.error(effectPath, "“icon” takes an SF Symbol name.") }
                case "text":
                    if let segments = template(member.value, path: effectPath) { effects.append((.text, member.value.string ?? TextTemplate.string(segments))) }
                case "opacity":
                    if let number = member.value.number {
                        effects.append((.opacity, SpecFormat.number(clamped(number, 0...1, path: effectPath, what: "opacity"))))
                    } else if let text = member.value.string, Double(text) != nil {
                        effects.append((.opacity, text))
                    } else {
                        report.error(effectPath, "“opacity” takes a number from 0 to 1.")
                    }
                default:
                    report.warning(effectPath, "“\(member.key)” is not an effect, so it is ignored.",
                                   hint: SpecKeys.suggestion(for: member.key, among: Self.ruleActionKeys, report: report)
                                       ?? "effects: color, hide, show, icon, text, opacity")
                }
            }
            if effects.isEmpty, !tried {
                report.error(object.path, "An action needs an effect: color, hide, show, icon, text or opacity.")
            }
            guard let target else { continue }
            for (kind, value) in effects {
                result.append(value.map { RuleAction(id: "", kind: kind, target: target, value: $0) } ?? RuleAction(id: "", kind: kind, target: target))
            }
        }
        return result
    }
}
