import Foundation
import ApplicationServices

// Pure synthetic projections only. No adapter instance, application/window AX
// query, clipboard access, input event, capture, activation, or UI operation.
@main
struct NewDraftPolicyTests {
    typealias Node = SidebarIdentityNode<Int>
    static var assertions = 0
    static let composerIndex = 4

    static func main() {
        testComposerLabels()
        testStableDraftProof()
        testPostPastePlaceholderTransition()
        testContextChanges()
        testHomeScope()
        testExistingConversationConflicts()
        // 2026-10-25: user input after Cmd+V no longer voids a confirmed paste on a new draft.
        expect(AppendConfirmationPolicy.acceptsConfirmed(isNewDraft: true, observing: true, intervened: true),
              "confirmed readback + key/click after the paste: success (sound, ✓, jelly)")
        expect(AppendConfirmationPolicy.acceptsConfirmed(isNewDraft: true, observing: true, intervened: false), "confirmed, no input: success")
        expect(!AppendConfirmationPolicy.acceptsConfirmed(isNewDraft: true, observing: false, intervened: false),
              "a new draft whose input watch failed is never trusted")
        expect(AppendConfirmationPolicy.acceptsConfirmed(isNewDraft: false, observing: false, intervened: true), "existing drafts unchanged")
        expect(AppendConfirmationPolicy.interruptsUnconfirmed(intervened: true), "unconfirmed + input: still interrupted")
        expect(!AppendConfirmationPolicy.interruptsUnconfirmed(intervened: false), "unconfirmed, no input: keeps waiting")

        print("New draft identity policy: \(assertions) pure assertions passed; no application access.")
    }

    static func expect(_ value: Bool, _ message: String = "Policy expectation failed",
                       file: StaticString = #file, line: UInt = #line) {
        assertions += 1
        precondition(value, message, file: file, line: line)
    }

    static func node(_ key: Int, _ parent: Int?, _ role: String,
                     labels: [String] = [], classes: Set<String> = [],
                     current: String? = nil, route: String? = nil,
                     hidden: Bool = false, value: String? = nil,
                     selected: Bool? = nil) -> Node {
        var result = Node(key: key, parent: parent, role: role, labels: labels,
                          classes: classes, current: current, route: route, hidden: hidden)
        result.value = value
        result.selected = selected
        return result
    }

    static func fixture() -> [Node] {
        [node(100, nil, "AXWindow"),
         node(101, 0, "AXWebArea"),
         node(102, 1, "AXGroup", classes: [NewDraftIdentityPolicy.homeClass]),
         node(103, 2, "AXGroup"),
         node(104, 3, "AXTextArea", labels: ["Do anything"]),
         node(105, 2, "AXButton", labels: ["Choose project"]),
         node(106, 2, "AXGroup", labels: ["Composer mode"]),
         node(107, 6, "AXRadioButton", labels: ["Codex"], selected: true),
         node(108, 6, "AXRadioButton", labels: ["Work"], selected: false),
         node(109, 2, "AXButton", labels: ["Send"])]
    }

    static func proof(_ nodes: [Node], labels: [String]? = nil,
                      routes: Set<String> = [], existing: SidebarIdentityAnalysis<Int>? = nil)
        -> ConversationIdentity<Int>? {
        let analysis = existing ?? SidebarIdentityPolicy.analyze(nodes: nodes,
            webArea: 1, composer: composerIndex, documentRoutes: routes)
        return NewDraftIdentityPolicy.analyze(nodes: nodes, webArea: 1,
            composer: composerIndex, composerLabels: labels ?? nodes[composerIndex].labels,
            existing: analysis)
    }

    static func changed(_ original: Node, key: Int? = nil, parent: Int? = nil,
                        role: String? = nil) -> Node {
        node(key ?? original.key, parent ?? original.parent, role ?? original.role,
             labels: original.labels, classes: original.classes, current: original.current,
             route: original.route, hidden: original.hidden, value: original.value,
             selected: original.selected)
    }

    static func testComposerLabels() {
        for label in ["Do anything", "随心输入", "想做什麼都可以", "Ask ChatGPT",
                      "询问 ChatGPT", "Work with Codex", "与 Codex 协作", "和 Codex 一起工作",
                      "輸入任何任務", "在此項目中開始新對話",
                      "Work with ChatGPT", "New chat in this project",
                      "此项目中的新聊天", "此專案中的新對話",
                      "New chat in Synthetic project", "在“合成项目”中新建聊天",
                      "在 合成專案 中開始新對話"] {
            expect(ComposerLabelPolicy.accepts(label), "Missing verified composer label")
        }
        for label in ["", "Search", "Ask anything", "Do anything else",
                      "New chat in ", "prefix New chat in Synthetic project",
                      "New chat", "在“”中新建聊天", "在  中開始新對話",
                      "Find in conversation"] {
            expect(!ComposerLabelPolicy.accepts(label), "Unverified generic label accepted")
        }
        expect(NewDraftIdentityPolicy.modeLabels.contains("Composer mode"))
        expect(NewDraftIdentityPolicy.modeLabels.contains("撰写器模式"))
        expect(NewDraftIdentityPolicy.modeLabels.contains("撰寫器模式"))
        expect(NewDraftIdentityPolicy.isProjectSelector("Choose project"))
        expect(NewDraftIdentityPolicy.isProjectSelector("Change project: Synthetic project"))
        expect(!NewDraftIdentityPolicy.isProjectSelector("Send"))
        expect(!NewDraftIdentityPolicy.isProjectSelector("Remove image.png"))
    }

    static func testStableDraftProof() {
        let nodes = fixture(), base = proof(nodes)
        if case .newDraft? = base { expect(true) }
        else { expect(false, "Positive home composer must get a new-draft proof") }
        expect(proof(fixture()) == base)

        // Draft contents never create identity. Empty and nonempty values use
        // the same semantic proof; StrictTarget separately preserves AXValue.
        var modified = nodes
        modified[composerIndex].value = "Synthetic unsent draft"
        expect(proof(modified) == base)
        modified[composerIndex].value = ""
        expect(proof(modified) == base)

        // Adding a native attachment must not replace the draft identity.
        modified.append(node(110, 2, "AXButton", labels: ["Remove synthetic-image.png"]))
        expect(proof(modified) == base)
        modified[9].labels = ["Send message"]
        modified[9].value = "busy"
        expect(proof(modified) == base)

        for index in [1, 2, 3, composerIndex] {
            modified = nodes
            modified[index] = changed(nodes[index], key: nodes[index].key + 1000)
            expect(proof(modified) != base, "Remounted target must not inherit a lease")
        }
        modified = nodes
        modified[composerIndex].labels = ["Ask ChatGPT"]
        expect(proof(modified) != base, "Changed mode label must invalidate proof")
        expect(proof(nodes, labels: ["Search"]) == nil)
        expect(proof(nodes, labels: []) == nil)
        modified[composerIndex] = changed(modified[composerIndex], role: "AXButton")
        expect(proof(modified) == nil)
    }

    static func testPostPastePlaceholderTransition() {
        var nodes = fixture()
        nodes[composerIndex].labels = ["和 Codex 一起工作"]
        let before = proof(nodes)!
        nodes[composerIndex].labels = ["使用 ChatGPT Work"]
        let after = proof(nodes)!
        expect(before != after, "Pre-paste identity remains strict")
        expect(NewDraftIdentityPolicy.matchesAfterAppend(before, after, hasExpectedAddition: true))
        expect(!NewDraftIdentityPolicy.matchesAfterAppend(before, after, hasExpectedAddition: false),
               "Changing a label without an exact attachment receipt cannot prove success")
        for change in 0..<5 {
            var modified = nodes
            switch change {
            case 0: modified[5].labels = ["Change project: other"]
            case 1: modified[7].selected = false; modified[8].selected = true
            case 2: modified[composerIndex] = changed(modified[composerIndex], key: 999)
            case 3: modified[composerIndex].labels = ["Ask ChatGPT"]
            default: modified[2] = changed(modified[2], key: 999)
            }
            expect(!NewDraftIdentityPolicy.matchesAfterAppend(before, proof(modified)!, hasExpectedAddition: true),
                   "Receipt must not hide mode/project/remount or other label changes")
        }
        // Without positive mode evidence, even this known placeholder alias is
        // ambiguous and cannot authorize a relaxed conversation comparison.
        var noModeBefore = fixture(); noModeBefore[6].labels = []
        noModeBefore[composerIndex].labels = ["和 Codex 一起工作"]
        var noModeAfter = noModeBefore; noModeAfter[composerIndex].labels = ["使用 ChatGPT Work"]
        expect(!NewDraftIdentityPolicy.matchesAfterAppend(proof(noModeBefore)!, proof(noModeAfter)!,
                                                         hasExpectedAddition: true))
        expect(NewDraftIdentityPolicy.matchesAfterAppend(before, before, hasExpectedAddition: false))
    }

    static func testContextChanges() {
        let nodes = fixture(), base = proof(nodes)
        var modified = nodes
        modified[5].labels = ["Change project: Synthetic project"]
        expect(proof(modified) != base)
        modified = nodes; modified[5].value = "Synthetic project"
        expect(proof(modified) != base)
        modified = nodes; modified[5] = changed(nodes[5], key: 205)
        expect(proof(modified) != base)
        modified = nodes; modified[6].value = "work"
        expect(proof(modified) != base)
        modified = nodes; modified[7].selected = false; modified[8].selected = true
        expect(proof(modified) != base)
        modified = nodes; modified[7].labels = ["Chat"]
        expect(proof(modified) != base)
        modified = nodes; modified[7] = changed(nodes[7], key: 207)
        expect(proof(modified) != base)
        modified = nodes; modified[6].labels = ["撰写器模式"]
        expect(proof(modified) != nil && proof(modified) != base)
        modified = nodes; modified[5].hidden = true
        expect(proof(modified) != base)
        modified = nodes; modified[6].hidden = true
        expect(proof(modified) != base)
        modified = nodes
        modified.append(node(110, 2, "AXGroup", labels: ["Composer mode"]))
        expect(proof(modified) == nil, "Duplicate mode selectors are ambiguous")
    }

    static func testHomeScope() {
        let nodes = fixture()
        var modified = nodes
        modified[2].classes = []
        expect(proof(modified) == nil, "A generic text box is not a new-chat proof")
        modified[2].classes = [NewDraftIdentityPolicy.homeClass + "-extra"]
        expect(proof(modified) == nil)
        for index in [1, 2, 3, composerIndex] {
            modified = nodes; modified[index].hidden = true
            expect(proof(modified) == nil, "Hidden target ancestry must be rejected")
        }
        modified = nodes
        modified.append(node(110, 1, "AXGroup", classes: [NewDraftIdentityPolicy.homeClass]))
        expect(proof(modified) == nil, "Duplicate home scopes are ambiguous")
        modified = nodes; modified[2] = changed(nodes[2], parent: composerIndex)
        expect(proof(modified) == nil, "Cyclic ancestry must be rejected")
        modified = nodes; modified[3] = changed(nodes[3], parent: 3)
        expect(proof(modified) == nil)
        modified = nodes; modified[3] = changed(nodes[3], parent: 999)
        expect(proof(modified) == nil)
        modified = nodes
        modified[composerIndex] = changed(nodes[composerIndex], parent: 1)
        expect(proof(modified) != nil, "Compact composer may be a sibling of home main")
        modified[2] = changed(nodes[2], parent: composerIndex)
        expect(proof(modified) == nil, "A home marker inside the editor is untrusted content")
        modified = nodes
        modified.append(node(110, 1, "AXWebArea"))
        modified[2] = changed(nodes[2], parent: 10)
        expect(proof(modified) == nil, "Nested WebArea must not supply the home marker")
        modified = nodes
        modified.append(node(110, 1, "AXWebArea"))
        modified[composerIndex] = changed(nodes[composerIndex], parent: 10)
        expect(proof(modified) == nil, "Composer must belong to the requested WebArea")
        modified = nodes
        modified[1] = changed(nodes[1], role: "AXGroup")
        expect(proof(modified) == nil)

        // Controls in a different document or inside the editor cannot become
        // mode/project identity evidence for this document.
        let base = proof(nodes)
        modified = nodes
        modified.append(node(110, 1, "AXWebArea"))
        modified.append(node(111, 10, "AXButton", labels: ["Choose project"]))
        expect(proof(modified) == base)
        modified.append(node(112, composerIndex, "AXButton", labels: ["Choose project"]))
        expect(proof(modified) == base)
        modified.append(node(113, composerIndex, "AXGroup", labels: ["Composer mode"]))
        expect(proof(modified) == base)
    }

    static func testExistingConversationConflicts() {
        let nodes = fixture()
        expect(proof(nodes, routes: ["/local/aaaaaaaa"]) == nil)
        expect(proof(nodes, routes: ["/local/aaaaaaaa", "/local/bbbbbbbb"]) == nil)
        let classes: Set<String> = ["sidebar-item", SidebarIdentityPolicy.threadClass]
        var modified = nodes
        modified.append(node(110, 1, "AXList"))
        modified.append(node(111, 10, "AXButton", labels: ["Synthetic existing chat"],
                             classes: classes, current: "page"))
        expect(proof(modified) == nil)
        modified.append(node(112, 10, "AXButton", labels: ["Another synthetic existing chat"],
                             classes: classes, current: "page"))
        expect(proof(modified) == nil)
        let conflict = SidebarIdentityAnalysis<Int>(identity: nil, failure: .conversationConflict,
            listKinds: [], listCount: 0, currentCount: 0, routeCount: 0)
        expect(proof(nodes, existing: conflict) == nil)
        let unavailable = SidebarIdentityAnalysis<Int>(identity: nil, failure: .webAreaUnavailable,
            listKinds: [], listCount: 0, currentCount: 0, routeCount: 0)
        expect(proof(nodes, existing: unavailable) == nil)
    }
}
