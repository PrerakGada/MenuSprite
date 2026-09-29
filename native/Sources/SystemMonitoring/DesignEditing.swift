import Foundation

/// Where a dropped or inserted node goes relative to another: beside it (left/right) or
/// above/below it. Beside means the same row; above/below means the same column. When the target's
/// container runs the other way, the target is wrapped in a new container that runs the right way.
public enum DropEdge: String, Sendable, CaseIterable {
    case left, right, above, below
    var axis: DesignNodeKind { self == .left || self == .right ? .row : .column }
    var after: Bool { self == .right || self == .below }
}

extension SpriteDesign {
    /// Puts `node` at `edge` of `target`. Dropping on the root places it inside the root's run.
    @discardableResult
    public mutating func insert(_ node: DesignNode, at edge: DropEdge, of target: String) -> Bool {
        if target == root.id {
            if root.kind == edge.axis {
                if edge.after { root.children.append(node) } else { root.children.insert(node, at: 0) }
            } else {
                // The root keeps its identity (padding, colour); its content becomes one child.
                var content = root; content.id = DesignNode.newID(); content.name = ""
                content.style = NodeStyle(); content.style.gap = root.style.gap; content.style.justify = root.style.justify
                var wrapper = DesignNode(kind: edge.axis, name: "", children: edge.after ? [content, node] : [node, content])
                wrapper.style.gap = edge.axis == .column ? 1.5 : 4
                root.children = [wrapper]
                root.style.gap = 4
            }
            return true
        }
        guard let (parent, index) = root.parent(of: target) else { return false }
        if parent.kind == edge.axis {
            return root.update(parent.id) { $0.children.insert(node, at: edge.after ? index + 1 : index) }
        }
        return root.update(target) { existing in
            let moved = existing
            var wrapper = DesignNode(kind: edge.axis, children: edge.after ? [moved, node] : [node, moved])
            wrapper.style.gap = edge.axis == .column ? 1.5 : 4
            existing = wrapper
        }
    }

    /// Moves `id` to `edge` of `target`. Refuses to move a node into itself or its own contents.
    @discardableResult
    public mutating func move(_ id: String, to edge: DropEdge, of target: String) -> Bool {
        guard id != target, id != root.id, let moving = root.find(id), moving.find(target) == nil else { return false }
        var copy = self
        guard let removed = copy.root.remove(id) else { return false }
        copy.collapse()
        guard copy.root.find(target) != nil, copy.insert(removed, at: edge, of: target) else { return false }
        self = copy
        return true
    }

    /// Splits `id` into two: it and a new text beside it (a row) or beneath it (a column).
    /// Returns the new node's id.
    @discardableResult
    public mutating func split(_ id: String, axis: DesignNodeKind) -> String? {
        var fresh = DesignNode.text([.literal("Text")], size: axis == .column ? 9 : 12, name: "Text")
        fresh.style.tabular = false
        if let node = root.find(id), node.kind == .text {
            fresh.style.size = axis == .column ? min(node.style.size ?? 12, 9) : node.style.size
            fresh.style.weight = node.style.weight
        }
        let edge: DropEdge = axis == .row ? .right : .below
        return insert(fresh, at: edge, of: id) ? fresh.id : nil
    }

    /// Replaces a container by its children in its parent (the root is never unwrapped).
    @discardableResult
    public mutating func unwrap(_ id: String) -> Bool {
        guard id != root.id, let node = root.find(id), node.kind.isContainer, let (parent, index) = root.parent(of: id) else { return false }
        return root.update(parent.id) { $0.children.replaceSubrange(index...index, with: node.children) }
    }

    /// Joins a text with the text that follows it, keeping the first one's style.
    @discardableResult
    public mutating func mergeWithNext(_ id: String) -> Bool {
        guard let (parent, index) = root.parent(of: id), parent.children.indices.contains(index + 1),
              parent.children[index].kind == .text, parent.children[index + 1].kind == .text else { return false }
        let next = parent.children[index + 1]
        root.update(parent.id) { container in
            container.children[index].segments += next.segments
            container.children.remove(at: index + 1)
        }
        collapse()
        return true
    }
    public func canMergeWithNext(_ id: String) -> Bool {
        guard let (parent, index) = root.parent(of: id), parent.children.indices.contains(index + 1) else { return false }
        return parent.children[index].kind == .text && parent.children[index + 1].kind == .text
    }

    /// Removes `id` and tidies what it leaves behind. Rules aimed at it lose that action.
    @discardableResult
    public mutating func delete(_ id: String) -> Bool {
        guard id != root.id, root.remove(id) != nil else { return false }
        collapse()
        prune()
        return true
    }

    /// Inserts a copy of `id` right after it. Returns the copy's id.
    @discardableResult
    public mutating func duplicate(_ id: String) -> String? {
        guard id != root.id, let node = root.find(id), let (parent, index) = root.parent(of: id) else { return nil }
        let copy = node.reidentified()
        root.update(parent.id) { $0.children.insert(copy, at: index + 1) }
        return copy.id
    }

    /// Turns a row into a column or back.
    public mutating func flip(_ id: String) {
        root.update(id) { node in
            guard node.kind.isContainer else { return }
            node.kind = node.kind == .row ? .column : .row
            node.style.gap = node.kind == .column ? 1.5 : 4
            if node.kind == .row && node.style.justify == .even { node.style.justify = .center }
        }
    }

    /// Moves `id` one place earlier or later among its siblings.
    @discardableResult
    public mutating func shift(_ id: String, by offset: Int) -> Bool {
        guard let (parent, index) = root.parent(of: id) else { return false }
        let target = index + offset
        guard parent.children.indices.contains(target) else { return false }
        return root.update(parent.id) { $0.children.swapAt(index, target) }
    }

    /// Drops empty containers and folds a non-root container with one child into that child.
    public mutating func collapse() {
        func tidy(_ node: inout DesignNode, isRoot: Bool) {
            for index in node.children.indices { tidy(&node.children[index], isRoot: false) }
            node.children.removeAll { $0.kind.isContainer && $0.children.isEmpty }
            if !isRoot, node.kind.isContainer, node.name.isEmpty, node.children.count == 1, node.style == NodeStyle.plain(for: node.kind, gap: node.style.gap) {
                node = node.children[0]
            }
        }
        tidy(&root, isRoot: true)
    }

    /// A short description of a node for pickers and the outline: "Label “RAM”", "Value {cpu}".
    public func title(of node: DesignNode) -> String {
        let base = node.name.isEmpty ? node.kind.title : node.name
        switch node.kind {
        case .text:
            let text = node.segments.map { segment -> String in
                switch segment {
                case .literal(let literal): literal
                case .value(let id): "{\(variable(id)?.name ?? id)}"
                }
            }.joined()
            return "\(base) “\(text.prefix(24))”"
        case .icon: return "\(base) · \(node.symbol)"
        case .bar, .battery: return "\(base) · \(node.variable.flatMap(variable)?.name ?? "no value")"
        case .row, .column: return "\(base) · \(node.children.count) inside"
        }
    }
}

extension NodeStyle {
    /// A container's style with nothing but its gap set: folding one away loses nothing.
    static func plain(for kind: DesignNodeKind, gap: Double) -> NodeStyle {
        var style = NodeStyle(); style.gap = gap
        return style
    }
}
