import Foundation
import ApplicationServices

// Pure policy/value tests only: no StrictTarget instance, AX application query,
// window query, pasteboard, activation, keyboard event or live target access.
@main
struct StrictTargetPolicyTests {
    static var assertions = 0
    static func main() throws {
        let id = "01a13e1f-fd91-7240-8fc6-a930d29e3676"
        expect(StrictTarget.conversationRoute("app://./local/\(id)") == "/local/\(id)")
        expect(StrictTarget.conversationRoute("codex://threads/\(id)") == "/local/\(id)")
        expect(StrictTarget.conversationRoute("https://chatgpt.com/c/\(id)") == "/c/\(id)")
        expect(StrictTarget.conversationRoute("app://./remote/\(id)") == "/remote/\(id)")
        for invalid in ["app://./", "app://./local/", "app://./local/new", "app://./local/\(id)/edit",
                        "https://evil.example/c/\(id)", "javascript:/local/\(id)", "file:///tmp/editor.html",
                        "app://./settings", "app://./hotkey-window/thread/\(id)",
                        "app://./index.html?initialRoute=/local/\(id)"] {
            expect(StrictTarget.conversationRoute(invalid) == nil)
        }
        // Empty composer reported as "" or "\n" (2026-10-24); only visible text is the draft.
        let empty = DraftSnapshot(text: "\n", attachmentMarkers: [:])
        expect(DraftSnapshot.visibleText("\n") == "")

        // Codex's placeholder is reported as the value; it is never the user's text (2026-10-25).
        expect(DraftSnapshot.userText("和 Codex 一起工作", placeholders: ["和 Codex 一起工作", nil]) == "")
        expect(DraftSnapshot.userText("使用 ChatGPT Work\n", placeholders: ["使用 ChatGPT Work", nil]) == "")
        expect(DraftSnapshot.userText("hello", placeholders: ["使用 ChatGPT Work", nil]) == "hello")
        // Descriptions can contain user-provided or unrelated text. Equality by
        // itself must not turn a real draft into an empty one.
        expect(DraftSnapshot.userText("hello", placeholders: ["hello", "Ask ChatGPT"]) == "hello")
        expect(DraftSnapshot.userText("Search", placeholders: ["Search", nil]) == "Search")
        expect(DraftSnapshot.userText("\n", placeholders: [nil, nil]) == "\n")
        expect(DraftSnapshot.visibleText("\u{FFFC}\u{200B} hello world \n") == "hello world")
        expect(empty.sameDraft(as: DraftSnapshot(text: "", attachmentMarkers: [:])))
        expect(empty.sameDraft(as: DraftSnapshot(text: "\n\n\u{FFFC}", attachmentMarkers: [:])))
        expect(DraftSnapshot(text: "hi\n", attachmentMarkers: [:]).sameDraft(as: DraftSnapshot(text: "hi", attachmentMarkers: [:])))
        expect(!DraftSnapshot(text: "hi", attachmentMarkers: [:]).sameDraft(as: DraftSnapshot(text: "hi there", attachmentMarkers: [:])))
        expect(!DraftSnapshot(text: "a b", attachmentMarkers: [:]).sameDraft(as: DraftSnapshot(text: "ab", attachmentMarkers: [:])))
        expect(!empty.sameDraft(as: DraftSnapshot(text: "x", attachmentMarkers: [:])))
        expect(!empty.sameDraft(as: DraftSnapshot(text: "\n", attachmentMarkers: ["Remove a.png": 1])))
        expect(DraftSnapshot(text: "abc", attachmentMarkers: [:]).textChangeSummary(from: empty) == "; text=1->3 visible=0->3")
        let old = ["Remove existing.png": 2, "移除 notes.pdf": 1]
        let filename = "iPad-unique-capture.png"
        expect(try StrictTarget.compareAttachmentMarkers(before: old, after: old,
                                                          expectedFilename: filename) == .pending)
        for label in ["Remove \(filename)", "移除 \(filename)", "移除“\(filename)”"] {
            var appended = old; appended[label] = 1
            expect(try StrictTarget.compareAttachmentMarkers(before: old, after: appended,
                                                              expectedFilename: filename) == .confirmed)
        }
        expectThrows { try StrictTarget.compareAttachmentMarkers(before: old,
            after: ["Remove existing.png": 1, "移除 notes.pdf": 1, "Remove \(filename)": 1], expectedFilename: filename) }
        var wrong = old; wrong["Remove another.png"] = 1
        expectThrows { try StrictTarget.compareAttachmentMarkers(before: old, after: wrong, expectedFilename: filename) }
        var duplicated = old; duplicated["Remove \(filename)"] = 2
        expectThrows { try StrictTarget.compareAttachmentMarkers(before: old, after: duplicated, expectedFilename: filename) }
        expectThrows { try StrictTarget.compareAttachmentMarkers(before: old, after: old, expectedFilename: "") }
        // A simultaneous deletion must not hide an unknown/duplicate addition.
        expectFailure(.attachmentMismatch) {
            try StrictTarget.compareAttachmentMarkers(before: old,
                after: ["Remove other.png": 1], expectedFilename: filename)
        }
        expectFailure(.attachmentMismatch) {
            try StrictTarget.compareAttachmentMarkers(before: old,
                after: ["Remove \(filename)": 2], expectedFilename: filename)
        }
        expectFailure(.attachmentMismatch) {
            try StrictTarget.compareAttachmentMarkers(before: old,
                after: ["Remove \(filename)": 1, "Remove other.png": 1], expectedFilename: filename)
        }
        expectFailure(.draftChanged) {
            try StrictTarget.compareAttachmentMarkers(before: old,
                after: ["Remove \(filename)": 1], expectedFilename: filename)
        }
        expectFailure(.draftChanged) {
            try StrictTarget.compareAttachmentMarkers(before: old, after: [:], expectedFilename: filename)
        }
        expect(try StrictTarget.hasUniqueExpectedAddition(before: old,
            after: ["Remove \(filename)": 1], expectedFilename: filename))
        expect(try !StrictTarget.hasUniqueExpectedAddition(before: old, after: [:], expectedFilename: filename))
        expect(try !StrictTarget.hasUniqueExpectedAddition(before: old, after: old, expectedFilename: filename))
        testSidebarIdentity()
        testAttachmentMarkerScope()
        testAttachmentGeometry()
        try testInspectionBatch()
        print("Strict target policy: \(assertions) pure assertions passed; no application access.")
    }
    static func expect(_ condition: Bool) { assertions += 1; precondition(condition) }
    static func expectThrows(_ body: () throws -> AppendReadback) {
        assertions += 1
        do { _ = try body(); preconditionFailure("Expected fail-closed result") }
        catch is TargetFailure { }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }
    static func expectFailure(_ expected: TargetFailure, _ body: () throws -> AppendReadback) {
        assertions += 1
        do { _ = try body(); preconditionFailure("Expected \(expected)") }
        catch let failure as TargetFailure { precondition(failure == expected) }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }

    static func testInspectionBatch() throws {
        func errorValue(_ value: AXError) -> AnyObject {
            var value = value
            return AXValueCreate(.axError, &value)!
        }
        func rejects(_ attributes: [String], _ values: [AnyObject]) {
            assertions += 1
            do {
                _ = try InspectionAttributeBatch.decode(attributes: attributes, values: values)
                preconditionFailure("Malformed or failed batch must be rejected")
            } catch TargetFailure.treeUnavailable { }
            catch { preconditionFailure("Unexpected batch error: \(error)") }
        }
        let names = ["AXDescription", "AXTitle", "AXHidden", "AXHelp"]
        let slots = try InspectionAttributeBatch.decode(attributes: names,
            values: ["synthetic label" as NSString, kCFNull,
                     errorValue(.attributeUnsupported), errorValue(.noValue)])
        if case .value(let raw)? = slots["AXDescription"] { expect(raw as? String == "synthetic label") }
        else { preconditionFailure("Description slot was shifted or lost") }
        for name in names.dropFirst() {
            if case .missing? = slots[name] { expect(true) }
            else { preconditionFailure("Missing value slot was not retained") }
        }
        rejects(["A", "B"], ["one" as NSString])
        rejects(["A"], ["one" as NSString, "two" as NSString])
        rejects(["A", "A"], [kCFNull, kCFNull])
        rejects([], [])
        for error in [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .failure,
                      .illegalArgument, .notImplemented, .success] {
            rejects(["A"], [errorValue(error)])
        }

        // AXValue types other than AXError are ordinary values, not missing slots.
        var range = CFRange(location: 4, length: 0)
        let rangeValue = AXValueCreate(.cfRange, &range)!
        let rangeSlots = try InspectionAttributeBatch.decode(attributes: ["AXSelectedTextRange"],
                                                              values: [rangeValue])
        if case .value(let raw)? = rangeSlots["AXSelectedTextRange"] {
            expect(CFGetTypeID(raw) == AXValueGetTypeID())
            expect(AXValueGetType(unsafeBitCast(raw, to: AXValue.self)) == .cfRange)
        } else { preconditionFailure("A normal AXValue was treated as an AX error") }

        var cache = InspectionAttributeCache()
        expect(cache.missingAttributes(node: 7, attributes: names) == names)
        cache.store(node: 7, slots: slots)
        expect(cache.missingAttributes(node: 7, attributes: names).isEmpty)
        expect(cache.values(node: 7, attributes: names)["AXDescription"] as? String == "synthetic label")
        expect(cache.values(node: 7, attributes: names)["AXTitle"] == nil)
        expect(cache.missingAttributes(node: 8, attributes: names) == names)
        expect(cache.missingAttributes(node: 7, attributes: ["AXDescription", "AXURL"]) == ["AXURL"])
        let nextInspection = InspectionAttributeCache()
        expect(nextInspection.missingAttributes(node: 7, attributes: names) == names)
        expect(nextInspection.values(node: 7, attributes: names).isEmpty)
    }

    static func testAttachmentMarkerScope() {
        typealias Node = SidebarIdentityNode<Int>
        let base = [Node(key: 0, parent: nil, role: "AXWindow"),
                    Node(key: 1, parent: 0, role: "AXWebArea"),
                    Node(key: 2, parent: 1, role: "AXTextArea"),
                    Node(key: 3, parent: 1, role: "AXGroup"),
                    Node(key: 4, parent: 3, role: "AXButton", labels: ["Remove exact-capture.png"])]
        func accepts(_ nodes: [Node]) -> Bool {
            AttachmentMarkerScopePolicy.contains(4, nodes: nodes, webArea: 1, composer: 2)
        }
        expect(accepts(base))
        var nodes = base; nodes[4].hidden = true
        expect(accepts(nodes)) // native hover-only remove button
        for index in [1, 3] {
            nodes = base; nodes[index].hidden = true
            expect(!accepts(nodes))
        }
        func move(_ index: Int, _ parent: Int) {
            nodes[index] = Node(key: nodes[index].key, parent: parent,
                role: nodes[index].role, labels: nodes[index].labels)
        }
        nodes = base; nodes.append(Node(key: 5, parent: 0, role: "AXWebArea")); move(3, 5)
        expect(!accepts(nodes)) // other document in the same window
        nodes = base; nodes.append(Node(key: 5, parent: 1, role: "AXWebArea")); move(3, 5)
        expect(!accepts(nodes)) // nested document
        nodes = base; move(3, 2)
        expect(!accepts(nodes)) // user-authored editor contents
        nodes = base; move(3, 3)
        expect(!accepts(nodes)) // malformed cycle
        nodes = base; move(3, 99)
        expect(!accepts(nodes))
        nodes = base; move(3, 0)
        expect(!accepts(nodes)) // window panel outside the document
        expect(!AttachmentMarkerScopePolicy.contains(99, nodes: base, webArea: 1, composer: 2))
    }

    static func testAttachmentGeometry() {
        typealias Node = SidebarIdentityNode<Int>
        let filename = "iPad-synthetic-unique.png"
        func fixture() -> [Node] {
            [Node(key: 0, parent: nil, role: "AXWindow"),
             Node(key: 1, parent: 0, role: "AXWebArea"),
             Node(key: 2, parent: 1, role: "AXTextArea"),
             Node(key: 3, parent: 1, role: "AXScrollArea"),
             Node(key: 4, parent: 3, role: "AXButton", labels: [filename],
                  classes: AttachmentGeometryPolicy.cardClasses),
             Node(key: 5, parent: 4, role: "AXButton", labels: ["Remove \(filename)"])]
        }
        func moved(_ node: Node, parent: Int? = nil, role: String? = nil) -> Node {
            Node(key: node.key, parent: parent ?? node.parent, role: role ?? node.role,
                 labels: node.labels, classes: node.classes, current: node.current,
                 route: node.route, hidden: node.hidden)
        }
        func candidate(_ nodes: [Node], filename value: String? = nil) -> AttachmentGeometryPolicy.Candidate? {
            AttachmentGeometryPolicy.candidate(nodes: nodes, webArea: 1, composer: 2,
                                                filename: value ?? filename)
        }
        expect(candidate(fixture()) == .init(index: 4, clippingAncestors: [3]))
        func nativeCard(_ nodes: [Node]) -> Bool {
            AttachmentMarkerScopePolicy.hasNativeCard(nodes: nodes,
                webArea: 1, composer: 2, filename: filename)
        }
        expect(nativeCard(fixture()))
        var unrelated = fixture(); unrelated[4].classes = ["message-attachment"]
        expect(!nativeCard(unrelated)) // Transcript labels cannot acknowledge a composer attachment
        unrelated = fixture(); unrelated[4].classes = []
        expect(!nativeCard(unrelated)) // Exact filename alone is insufficient
        unrelated = fixture(); unrelated.append(Node(key: 6, parent: 1, role: "AXWebArea"))
        unrelated[4] = moved(unrelated[4], parent: 6)
        expect(!nativeCard(unrelated))

        var nodes = fixture(); nodes[4] = moved(nodes[4], parent: 1)
        expect(candidate(nodes) == .init(index: 4, clippingAncestors: []))
        for label in ["移除 \(filename)", "移除“\(filename)”"] {
            nodes = fixture(); nodes[5].labels = [label]
            expect(candidate(nodes) != nil)
        }
        expect(candidate(fixture(), filename: "") == nil)
        expect(candidate(fixture(), filename: "other.png") == nil)
        nodes = fixture(); nodes.append(Node(key: 6, parent: 3, role: "AXButton",
            labels: [filename], classes: AttachmentGeometryPolicy.cardClasses))
        // Unrelated cards with the same title cannot own this unique removal.
        expect(candidate(nodes) == .init(index: 4, clippingAncestors: [3]))
        nodes = fixture(); nodes[3].classes = AttachmentGeometryPolicy.cardClasses
        expect(candidate(nodes) == nil)
        for required in AttachmentGeometryPolicy.cardClasses {
            nodes = fixture(); nodes[4].classes.remove(required)
            expect(candidate(nodes) == nil)
        }
        nodes = fixture(); nodes[4].classes = ["composer-attachment-surface", "group/composer-attachment-extra"]
        expect(candidate(nodes) == nil)
        nodes = fixture(); nodes[4] = moved(nodes[4], role: "AXGroup"); nodes[4].labels = []
        expect(candidate(nodes) == .init(index: 4, clippingAncestors: [3]))
        nodes = fixture(); nodes[4].labels = ["preview " + filename]
        expect(candidate(nodes) == .init(index: 4, clippingAncestors: [3]))
        nodes = fixture(); nodes.append(Node(key: 6, parent: 0, role: "AXWebArea")); nodes[4] = moved(nodes[4], parent: 6)
        expect(candidate(nodes) == nil)
        nodes = fixture(); nodes[5] = moved(nodes[5], parent: 3)
        expect(candidate(nodes) == nil)
        nodes = fixture(); nodes.append(Node(key: 6, parent: 0, role: "AXWebArea")); nodes[5] = moved(nodes[5], parent: 6)
        expect(candidate(nodes) == nil)
        nodes = fixture(); nodes[5].labels = ["Remove other.png"]
        expect(candidate(nodes) == nil)
        nodes = fixture(); nodes.append(Node(key: 6, parent: 4, role: "AXButton", labels: ["Remove \(filename)"]))
        expect(candidate(nodes) == nil)
        nodes = fixture(); nodes[4] = moved(nodes[4], parent: 2)
        expect(candidate(nodes) == nil)
        // Native remove buttons use opacity:0 until hover; their own hidden
        // status is not the containing thumbnail's visibility.
        nodes = fixture(); nodes[5].hidden = true
        expect(candidate(nodes) == .init(index: 4, clippingAncestors: [3]))
        for hidden in [1, 3, 4] {
            nodes = fixture(); nodes[hidden].hidden = true
            expect(candidate(nodes) == nil)
        }
        nodes = fixture(); nodes[4] = moved(nodes[4], parent: 4)
        expect(candidate(nodes) == nil)
        nodes = fixture(); nodes[4] = moved(nodes[4], parent: 100)
        expect(candidate(nodes) == nil)
        nodes = fixture(); nodes.append(Node(key: 6, parent: 3, role: "AXScrollArea"))
        nodes.append(Node(key: 7, parent: 6, role: "AXScrollArea")); nodes[4] = moved(nodes[4], parent: 7)
        expect(candidate(nodes) == nil)
        expect(nativeCard(nodes)) // Geometry clipping limits do not veto semantic confirmation

        // The optional search does not climb more than eight existing parents.
        nodes = fixture()
        for index in 6...13 { nodes.append(Node(key: index, parent: index == 6 ? 4 : index - 1, role: "AXGroup")) }
        nodes[5] = moved(nodes[5], parent: 13)
        expect(candidate(nodes) == nil)
        nodes[5] = moved(nodes[5], parent: 12)
        expect(candidate(nodes) == .init(index: 4, clippingAncestors: [3]))
        func scan(_ nodes: [Node]) -> AttachmentGeometryPolicy.RemovalScan {
            AttachmentGeometryPolicy.removalScan(nodes: nodes, webArea: 1, composer: 2, filename: filename)
        }
        expect(scan(fixture()).reason == "remove-found")
        expect(scan(fixture()).removeCount == 1)
        expect(scan(fixture()).ancestors == [4, 3])
        nodes = fixture(); nodes[5].labels = []
        expect(scan(nodes).reason == "remove-missing-in-scope")
        expect(scan(nodes).removeCount == 0)
        nodes = fixture(); nodes.append(Node(key: 6, parent: 3, role: "AXButton", labels: ["Remove \(filename)"]))
        expect(scan(nodes).reason == "remove-ambiguous")
        expect(scan(nodes).removeCount == 2)
        nodes = fixture(); nodes[4].hidden = true
        expect(scan(nodes).reason == "hidden-ancestor")

        let window = CGRect(x: -1000, y: -200, width: 2000, height: 1600)
        let card = CGRect(x: 20, y: 30, width: 122, height: 122)
        let clip = CGRect(x: 0, y: 0, width: 500, height: 200)
        expect(AttachmentGeometryPolicy.validFrame(card, window: window, clippingFrames: [clip]))
        expect(AttachmentGeometryPolicy.validFrame(card, window: window, clippingFrames: []))
        expect(!AttachmentGeometryPolicy.validFrame(card, window: window,
            clippingFrames: [CGRect(x: 0, y: 0, width: 100, height: 200)]))
        expect(!AttachmentGeometryPolicy.validFrame(card, window: .zero, clippingFrames: []))
        expect(!AttachmentGeometryPolicy.validFrame(card, window: window, clippingFrames: [.zero]))
        for invalid in [CGRect(x: 20, y: 30, width: 0, height: 122),
                        CGRect(x: 20, y: 30, width: -122, height: 122),
                        CGRect(x: 20, y: 30, width: 122, height: -1),
                        CGRect(x: CGFloat.nan, y: 30, width: 122, height: 122),
                        CGRect(x: 20, y: 30, width: CGFloat.infinity, height: 122),
                        CGRect(x: 2000, y: 30, width: 122, height: 122)] {
            expect(!AttachmentGeometryPolicy.validFrame(invalid, window: window, clippingFrames: []))
        }
    }

    static func testSidebarIdentity() {
        typealias Node = SidebarIdentityNode<Int>
        let routeA = "/local/aaaaaaaa", routeB = "/local/bbbbbbbb"
        let threadClasses: Set<String> = ["sidebar-item", SidebarIdentityPolicy.threadClass]
        func fixture() -> [Node] {
            [Node(key: 100, parent: nil, role: "AXWindow"),
             Node(key: 101, parent: 0, role: "AXWebArea"),
             Node(key: 102, parent: 1, role: "AXTextArea"),
             Node(key: 103, parent: 1, role: "AXList"),
             Node(key: 104, parent: 3, role: "AXButton", labels: ["Same synthetic title"],
                  classes: threadClasses, current: "page"),
             Node(key: 105, parent: 3, role: "AXButton", labels: ["Same synthetic title"],
                  classes: threadClasses)]
        }
        func check(_ nodes: [Node], routes: Set<String> = []) -> SidebarIdentityAnalysis<Int> {
            SidebarIdentityPolicy.analyze(nodes: nodes, webArea: 1, composer: 2, documentRoutes: routes)
        }
        let base = check(fixture())
        expect(base.failure == nil && base.listCount == 1 && base.currentCount == 1)
        if case let .sidebar(proof)? = base.identity {
            expect(proof.button == 104 && proof.list == 103 && proof.webArea == 101 && proof.kind == .threadRows)
        } else { preconditionFailure("Unnamed unified thread list must use a retained sidebar proof") }
        expect(check(fixture()).identity == base.identity)

        // Identical visible titles must not equate different selected objects.
        var nodes = fixture(); nodes[4].current = nil; nodes[5].current = "page"
        expect(check(nodes).identity != base.identity)
        nodes = fixture(); nodes[5].current = "page"
        expect(check(nodes).failure == .currentThreadsAmbiguous)
        expect(check(nodes, routes: [routeA]).failure == .currentThreadsAmbiguous)

        // A re-mounted row or list cannot inherit the earlier lease.
        nodes = fixture(); nodes[4] = Node(key: 204, parent: 3, role: "AXButton", labels: nodes[4].labels,
                                          classes: threadClasses, current: "page")
        expect(check(nodes).identity != base.identity)
        nodes = fixture(); nodes[3] = Node(key: 203, parent: 1, role: "AXList")
        expect(check(nodes).identity != base.identity)
        nodes = fixture(); nodes[1] = Node(key: 201, parent: 0, role: "AXWebArea")
        expect(check(nodes).identity != base.identity)
        nodes = fixture(); nodes[4].labels = ["Renamed synthetic title"]
        expect(check(nodes).identity != base.identity)

        // Browser-side document selection and composer mention lists never qualify.
        nodes = fixture(); nodes.append(Node(key: 106, parent: 1, role: "AXWebArea"))
        nodes[3] = Node(key: 103, parent: 6, role: "AXList")
        expect(check(nodes).failure == .threadListUnavailable)
        nodes = fixture(); nodes[3] = Node(key: 103, parent: 2, role: "AXList")
        expect(check(nodes).failure == .threadListUnavailable)
        nodes = fixture(); nodes[4].classes = ["sidebar-item"]
        nodes[5].classes = ["sidebar-item"]
        expect(check(nodes).failure == .threadListUnavailable)
        nodes[3].labels = ["Unrelated synthetic list"]
        expect(check(nodes).failure == .threadListUnavailable)

        // "Selected" without aria-current and aria-current=true do not prove page.
        nodes = fixture(); nodes[4].current = nil
        expect(check(nodes).failure == .currentThreadUnavailable)
        nodes[4].current = "true"
        expect(check(nodes).failure == .currentThreadUnavailable)
        nodes[4].current = "step"
        expect(check(nodes).failure == .currentThreadUnavailable)
        nodes = fixture(); nodes[4] = Node(key: 104, parent: 3, role: "AXLink", classes: threadClasses, current: "page")
        expect(check(nodes).failure == .currentThreadUnavailable)
        nodes = fixture(); nodes[4].hidden = true
        expect(check(nodes).failure == .currentThreadUnavailable)
        nodes = fixture(); nodes[3].hidden = true
        expect(check(nodes).failure == .threadListUnavailable)

        // Unknown current controls outside a thread list cannot supply route identity.
        nodes = fixture(); nodes[4].current = nil
        nodes.append(Node(key: 106, parent: 1, role: "AXButton", current: "page", route: routeA))
        expect(check(nodes).failure == .currentThreadUnavailable)

        // URL integrity is retained and checked without following initialRoute.
        nodes = fixture(); nodes[4].route = routeA
        let routed = check(nodes, routes: [routeA])
        expect(routed.failure == nil && routed.routeCount == 1)
        expect(check(nodes, routes: [routeB]).failure == .conversationConflict)
        expect(check(nodes, routes: [routeA, routeB]).failure == .conversationConflict)
        expect(routed.identity != base.identity)
        nodes = fixture(); nodes[4].current = nil
        expect(check(nodes, routes: [routeA]).identity == .route(routeA))
        expect(check(nodes, routes: [routeA, routeB]).failure == .conversationConflict)

        for label in ["Chats", "聊天", "對話"] {
            nodes = fixture(); nodes[3].labels = [label]
            expect(check(nodes).listKinds == [.chats])
        }
        for label in ["Pinned", "置顶", "已固定", "已釘選"] {
            nodes = fixture(); nodes[3].labels = [label]
            expect(check(nodes).listKinds == [.pinned])
        }
        // A label alone can explain a missing current marker but cannot identify it.
        nodes = fixture(); nodes[3].labels = ["聊天"]
        nodes[4].classes = []; nodes[5].classes = []
        expect(check(nodes).failure == .currentThreadUnavailable)
        nodes = fixture(); nodes[2] = Node(key: 102, parent: 0, role: "AXTextArea")
        expect(check(nodes).failure == .webAreaUnavailable)
        nodes = fixture(); nodes[3] = Node(key: 103, parent: 3, role: "AXList")
        expect(check(nodes).failure == .threadListUnavailable)
        // A list outside the current document cannot own a button inside it.
        nodes = fixture(); nodes[3] = Node(key: 103, parent: 0, role: "AXList")
        nodes[1] = Node(key: 101, parent: 3, role: "AXWebArea")
        nodes[4] = Node(key: 104, parent: 1, role: "AXButton", classes: threadClasses, current: "page")
        nodes[5] = Node(key: 105, parent: 1, role: "AXButton", classes: threadClasses)
        expect(check(nodes).failure == .threadListUnavailable)
        expect(!base.diagnostic.contains("Same synthetic title") && !routed.diagnostic.contains(routeA))
    }
}
