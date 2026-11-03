import ApplicationServices

// Run with scripts/test-claude-policy.sh. Pure policy only; no app is contacted.
@main
enum ClaudePolicyTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }
    static func throwsError(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    static func main() {
        let uuid = "0e74ef51-647d-4795-90b1-a5ec8ea28686"
        // Routes
        check(ClaudePolicy.route("https://claude.ai/chat/\(uuid)")?.kind == .chat, "chat route")
        check(ClaudePolicy.route("https://claude.ai/epitaxy/local_\(uuid)")?.kind == .codeSession, "code session route")
        check(ClaudePolicy.route("https://claude.ai/new")?.kind == .newChat, "new chat route")
        check(ClaudePolicy.route("https://claude.ai/new")?.isDraft == true, "new chat is a draft")
        check(ClaudePolicy.route("https://claude.ai/epitaxy")?.kind == .newCodeSession, "new Code session route")
        check(ClaudePolicy.route("https://claude.ai/epitaxy")?.isDraft == true, "new Code session is a draft")
        check(ClaudePolicy.route("https://claude.ai/epitaxy/local_\(uuid)")?.isDraft == false, "started Code session is not a draft")
        check(ClaudePolicy.route("https://claude.ai/epitaxy/project/chan_0123ABCdefGHI")?.kind == .projectPage, "project page route")
        check(ClaudePolicy.route("https://claude.ai/epitaxy/project/\(uuid)")?.kind == .projectPage, "project page route with uuid id")
        check(ClaudePolicy.route("https://claude.ai/epitaxy/project/chan_0123ABCdefGHI")?.isDraft == true, "project page is a draft")
        check(ClaudePolicy.routeShape("https://claude.ai/project/\(uuid)?q=secret") == "https://claude.ai/project/<id>", "shape hides id and query")
        check(ClaudePolicy.routeShape("https://claude.ai/epitaxy/local_\(uuid)") == "https://claude.ai/epitaxy/<id>", "shape hides session id")
        check(ClaudePolicy.routeShape("https://evil.example/a/b") == "https://<host>/a/b", "shape hides unknown host")
        check(ClaudePolicy.route("https://claude.ai/chat/\(uuid)")?.isDraft == false, "chat is not a draft")
        check(ClaudePolicy.route("https://claude.ai/chat/\(uuid)?q=1")?.url == "https://claude.ai/chat/\(uuid)?q=1",
              "full URL kept for exact comparison")
        for bad in ["https://claude.ai/", "https://claude.ai/recents", "https://claude.ai/chat/abc",
                    "https://claude.ai/chat/\(uuid)/x", "http://claude.ai/chat/\(uuid)",
                    "https://evil.example/chat/\(uuid)", "https://claude.ai/project/\(uuid)",
                    "https://claude.ai/epitaxy/\(uuid)", "https://claude.ai/chat/\(uuid)#frag",
                    "file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html",
                    "https://claude.ai/downloads", "https://claude.ai/epitaxy/project",
                    "https://claude.ai/epitaxy/project/", "https://claude.ai/epitaxy/project/chan_1/x",
                    "https://claude.ai/epitaxy/project/a.b", "https://claude.ai/epitaxy/project/chan_1#frag",
                    "https://claude.ai/epitaxy/project/" + String(repeating: "a", count: 129)] {
            check(ClaudePolicy.route(bad) == nil, "rejects \(bad)")
        }
        // Composer: structure first, label only as an alternative proof
        let classes = ["tiptap", "ProseMirror", "ProseMirror-focused"]
        check(ClaudePolicy.isComposer(role: "AXTextArea", label: "提示词", classes: classes, insideComposerCard: false), "verified label alone")
        check(ClaudePolicy.isComposer(role: "AXTextArea", label: "Write your prompt to Claude", classes: classes, insideComposerCard: true), "any language inside card")
        check(ClaudePolicy.isComposer(role: "AXTextArea", label: nil, classes: classes, insideComposerCard: true), "no label inside card")
        check(!ClaudePolicy.isComposer(role: "AXTextArea", label: "Edit message", classes: classes, insideComposerCard: false), "unknown label outside card rejected")
        check(!ClaudePolicy.isComposer(role: "AXTextField", label: "提示词", classes: classes, insideComposerCard: true), "role must be text area")
        check(!ClaudePolicy.isComposer(role: "AXTextArea", label: "提示词", classes: ["ProseMirror"], insideComposerCard: true), "needs tiptap class")
        // Attachment markers by file extension, any wording
        let name = "iPad-\(uuid).png"
        for label in ["移除 \(name)", "Remove \(name)", "Supprimer \(name)", name, "1792378332002_\(name)",
                      "移除 1792378332002_\(name)", "削除「\(name)」", "截屏2026-10-19 上午10.47.02.png", "notes.PDF"] {
            check(ClaudePolicy.isAttachmentMarker(label), "marker: \(label)")
        }
        for label in ["附加的图片 1", "发送", "Remove", ".png", "上下文 28%"] {
            check(!ClaudePolicy.isAttachmentMarker(label), "not a marker: \(label)")
        }
        // Which file a label names
        for label in [name, "移除 \(name)", "Remove \(name)", "Entfernen \(name)", "1792378332002_\(name)",
                      "移除 1792378332002_\(name)", "削除「\(name)」", "移除“\(name)”"] {
            check(ClaudePolicy.refersToFile(label, filename: name), "refers: \(label)")
        }
        for label in ["移除 x_\(name)", "移除 12_\(name)", "移除 \(name).png", "移除 other.png", "x\(name)", "移除 a\(name)"] {
            check(!ClaudePolicy.refersToFile(label, filename: name), "does not refer: \(label)")
        }
        check(!ClaudePolicy.refersToFile("移除 \(name)", filename: ""), "empty filename rejected")
        check(ClaudePolicy.isRemoveLabel("移除 \(name)", filename: name) && !ClaudePolicy.isRemoveLabel(name, filename: name), "remove wording")
        // Marker comparison
        let old = ["移除 旧图.png": 1, "旧图.png": 1]
        let added = ["移除 旧图.png": 1, "旧图.png": 1, "移除 1792378332002_\(name)": 1]
        check((try? ClaudePolicy.compareAttachmentMarkers(before: old, after: added, expectedFilename: name)) == .confirmed,
              "one expected addition confirms")
        let addedWithCard = added.merging(["1792378332002_\(name)": 1]) { a, _ in a }
        check((try? ClaudePolicy.compareAttachmentMarkers(before: old, after: addedWithCard, expectedFilename: name)) == .confirmed,
              "card + remove button for the same file confirms")
        check((try? ClaudePolicy.compareAttachmentMarkers(before: old, after: old, expectedFilename: name)) == .pending,
              "no addition is pending")
        check(throwsError { _ = try ClaudePolicy.compareAttachmentMarkers(before: old,
              after: ["移除 \(name)": 1], expectedFilename: name) }, "removed old attachment is draftChanged")
        check(throwsError { _ = try ClaudePolicy.compareAttachmentMarkers(before: old,
              after: ["移除 旧图.png": 1, "旧图.png": 1, "移除 \(name)": 2], expectedFilename: name) }, "duplicate addition rejected")
        check(throwsError { _ = try ClaudePolicy.compareAttachmentMarkers(before: old,
              after: ["移除 旧图.png": 1, "旧图.png": 1, "移除 \(name)": 1, "移除 别的.png": 1], expectedFilename: name) },
              "unknown extra addition rejected")
        check(throwsError { _ = try ClaudePolicy.compareAttachmentMarkers(before: [:],
              after: ["移除 别的.png": 1], expectedFilename: name) }, "wrong addition rejected")

        // Two chat tiles side by side (2026-10-22): 0 window, 1 sidebar, 2/3 chat
        // columns, 4/6 composer cards, 5/7 composers, 8 message list in column 3.
        let parent: [Int?] = [nil, 0, 0, 0, 2, 4, 3, 6, 3]
        check(ClaudePolicy.chatColumns(of: [5, 7], parent: parent) == [2, 3], "each composer's own chat column")
        check(ClaudePolicy.chatColumns(of: [5], parent: parent) == [0], "a single composer owns the whole window")
        check(ClaudePolicy.isInside(8, 3, parent: parent), "message list is inside the right column")
        check(!ClaudePolicy.isInside(8, 2, parent: parent), "message list is not inside the left column")
        check(!ClaudePolicy.isInside(1, 2, parent: parent) && !ClaudePolicy.isInside(1, 3, parent: parent),
              "sidebar is in neither column")
        check(ClaudePolicy.isInside(7, 7, parent: parent), "a node is inside itself")
        // 0 web area, 1 history, 2 card A, 3 composer A, 4 card B, 5 composer B,
        // 6 historical file button, 7 current file button. Only 2 can prove A's attachment.
        let attachmentParents: [Int?] = [nil, 0, 0, 2, 0, 4, 1, 2]
        check(ClaudePolicy.attachmentScope(composer: 3, card: 2, webArea: 0,
              composers: [3, 5], parent: attachmentParents) == 2, "attachment scope stays in the leased card")
        check(ClaudePolicy.attachmentScope(composer: 3, card: nil, webArea: 0,
              composers: [3, 5], parent: attachmentParents) == nil, "missing card cannot fall back to sent files in web area")
        check(ClaudePolicy.attachmentScope(composer: 3, card: 0, webArea: 0,
              composers: [3, 5], parent: attachmentParents) == nil, "web area is never an attachment card")
        check(ClaudePolicy.attachmentScope(composer: 3, card: 4, webArea: 0,
              composers: [3, 5], parent: attachmentParents) == nil, "another composer's card is rejected")
        let sharedCard: [Int?] = [nil, 0, 1, 1]
        check(ClaudePolicy.attachmentScope(composer: 2, card: 1, webArea: 0,
              composers: [2, 3], parent: sharedCard) == nil, "shared card cannot borrow another tile's attachments")
        check(!ClaudePolicy.isInside(6, 2, parent: attachmentParents) &&
              ClaudePolicy.isInside(7, 2, parent: attachmentParents), "history excluded and own file retained")
        check((try? ClaudePolicy.treeChildren([1, 2], error: nil)) == [1, 2], "complete child list retained")
        check((try? ClaudePolicy.treeChildren(nil as [Int]?, error: .attributeUnsupported)) == [], "unsupported leaf has no children")
        check((try? ClaudePolicy.treeChildren(nil as [Int]?, error: .noValue)) == [], "empty leaf has no children")
        for error in [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .failure] {
            check(throwsError { _ = try ClaudePolicy.treeChildren(nil as [Int]?, error: error) },
                  "AX read failure cannot hide a subtree: \(error.rawValue)")
        }
        check(throwsError { _ = try ClaudePolicy.treeChildren(nil as [Int]?, error: nil) },
              "malformed child value is not an empty subtree")
        typealias Candidate = ClaudePolicy.ComposerCandidate
        let plain = Candidate(onScreen: true)
        check(ClaudePolicy.chooseComposer([Candidate(holdsFocus: true, onScreen: true), plain]) == 0, "focus column picks left")
        check(ClaudePolicy.chooseComposer([plain, Candidate(holdsFocus: true, onScreen: true)]) == 1, "focus column picks right")
        check(ClaudePolicy.chooseComposer([Candidate(holdsFocus: true), Candidate(holdsFocus: true)]) == nil, "focus tie is ambiguous")
        check(ClaudePolicy.chooseComposer([Candidate(lastPasted: true, onScreen: true), Candidate(holdsFocus: true, onScreen: true)]) == 1,
              "focus beats the last pasted composer")
        check(ClaudePolicy.chooseComposer([plain, Candidate(lastPasted: true, onScreen: true)]) == 1, "last pasted composer when nothing is focused")
        check(ClaudePolicy.chooseComposer([plain, plain]) == nil, "last pasted composer no longer present is ambiguous")
        check(ClaudePolicy.chooseComposer([plain, Candidate(lastPasted: true, onScreen: false)]) == nil, "last pasted composer off screen is ambiguous")
        check(ClaudePolicy.chooseComposer([Candidate(lastPasted: true, onScreen: true), Candidate(lastPasted: true, onScreen: true)]) == nil,
              "last pasted tie is ambiguous")
        check(ClaudePolicy.chooseComposer([plain, Candidate(lastPasted: true, onScreen: true)], allowLastPasted: false) == nil,
              "without rule (b) only focus decides")
        check(ClaudePolicy.chooseComposer([]) == nil, "no candidates")
        check(TargetFailure.composersAmbiguous.errorDescription == "Two Claude chats side by side. Click one.", "ambiguity hint text")
        print("Claude policy: \(checks) pure assertions passed; no application access.")
    }
}
