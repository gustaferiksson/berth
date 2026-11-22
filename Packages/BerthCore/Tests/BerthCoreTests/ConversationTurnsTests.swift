@testable import BerthCore
import Testing

@Test func pollIsNotATurnPartAndReplyKeepsItsPlace() {
    let entries = [
        RemoteEntry(id: "p", kind: .prompt, text: "go"),
        RemoteEntry(id: "r1", kind: .toolUse, text: "{}", toolID: "t1", name: "REPL"),
        RemoteEntry(id: "r2", kind: .toolUse, text: "{}", toolID: "t2", name: "Poll"),
        RemoteEntry(id: "r3", kind: .reply, text: "Done so far"),
        RemoteEntry(id: "r4", kind: .toolUse, text: "{}", toolID: "t3", name: "REPL"),
    ]
    let parts = Turn.turns(from: entries)[0].parts

    #expect(parts.count == 3)
    #expect(parts[0].isWork && !parts[1].isWork && parts[2].isWork)
}
