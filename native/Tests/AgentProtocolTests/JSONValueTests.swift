import Testing
@testable import AgentProtocol

@Test func jsonValueKeepsKeyOrderAndRoundTrips() throws {
    let text = #"{"menusprite":1,"name":"PRs","values":[{"id":"prs","command":"echo 3","every":"5m"}],"files":{"b.py":"x\n","a.py":"é\"q"},"n":-1.5e2,"t":true,"z":null}"#
    let value = try JSONValue.parse(text)
    #expect(value.keys == ["menusprite", "name", "values", "files", "n", "t", "z"])
    #expect(value["files"]?.keys == ["b.py", "a.py"])
    #expect(value["files"]?["a.py"]?.string == "é\"q")
    #expect(value["n"]?.number == -150)
    #expect(try JSONValue.parse(value.serialized()) == value)
    #expect(try JSONValue.parse(value.serialized(pretty: true)) == value)
}

@Test func jsonParseErrorsSayWhere() {
    do { _ = try JSONValue.parse("{\n  \"a\": 1,\n}"); Issue.record("parsed") }
    catch let error as JSONParseError { #expect(error.line == 3); #expect(error.message.contains("trailing")) }
    catch { Issue.record("wrong error") }
    #expect(throws: JSONParseError.self) { try JSONValue.parse("{'a': 1}") }
    #expect(throws: JSONParseError.self) { try JSONValue.parse("[1, 2] x") }
}

@Test func envelopesKeepSpecOrder() throws {
    let spec = try JSONValue.parse(#"{"menusprite":1,"name":"PRs","icon":"bolt","values":[]}"#)
    let request = AgentRequest(.apply, args: .object([JSONMember("spec", spec)]))
    #expect(try JSONValue.parse(request.envelope.serialized())["args"]?["spec"]?.keys == ["menusprite", "name", "icon", "values"])
    let reply = try AgentResponse(envelope: JSONValue.parse(#"{"ok":true,"result":{"spec":{"menusprite":1,"name":"PRs","icon":"bolt"}}}"#))
    #expect(reply.result?["spec"]?.keys == ["menusprite", "name", "icon"])
    let failure = try AgentResponse(envelope: JSONValue.parse(#"{"ok":false,"error":{"code":"notFound","message":"No sprite"}}"#))
    #expect(failure.error?.code == .notFound)
}

@Test func loneHighSurrogateKeepsTheEscapeAfterIt() throws {
    // Backslashes are built at run time so no tool or literal decodes the escapes before the parser sees them.
    let slash = "\\"
    func parsed(_ body: String) throws -> String? { try JSONValue.parse("\"" + body + "\"").string }
    #expect(try parsed("a\(slash)ud83d\(slash)u0042c") == "a\u{FFFD}Bc")
    #expect(try parsed("\(slash)ud83d\(slash)ud83d\(slash)ude00") == "\u{FFFD}\u{1F600}")
    #expect(try parsed("\(slash)ud83d\(slash)u00e9") == "\u{FFFD}é")
    #expect(try parsed("\(slash)ud83d\(slash)ude00") == "\u{1F600}")
    #expect(try parsed("a\(slash)ud83dBc") == "a\u{FFFD}Bc")
    #expect(try parsed("\(slash)ude00x") == "\u{FFFD}x")
    // The escape after a lone surrogate is still checked.
    #expect(throws: JSONParseError.self) { try parsed("\(slash)ud83d\(slash)uZZZZ") }
}
