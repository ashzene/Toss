import AppKit
import ApplicationServices

// The sidebar selectors were verified by user-triggered 0.1.5–0.2.1 runs. The
// 0.3.0 batched-read optimization has user-triggered success evidence. Missing semantics fail closed: there
// is no coordinate fallback, newest-chat fallback, AXValue write or submit action.
// Raw draft text and attachment labels stay in memory and must never be logged.

struct DraftSnapshot: Equatable {
    let text: String
    let attachmentMarkers: [String: Int]

    // The composer reports an empty draft as "" or "\n" depending on focus and
    // attachment chips (seen 2026-10-24: a pasted image flipped it and the run
    // stopped as "draft changed"). Only visible text is the user's draft: edge
    // whitespace/newlines, U+FFFC and zero-width characters are ignored.
    nonisolated static func visibleText(_ text: String) -> String {
        let invisible: Set<UInt32> = [0xFFFC, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !invisible.contains($0.value) })
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Codex reports its placeholder as the text box's value (equal to its description), and
    // the placeholder changes when the first attachment arrives ("和 Codex 一起工作" ->
    // "使用 ChatGPT Work"). That is not the user's text: read as empty (2026-10-25: a correct
    // paste was dropped as "draft changed" and its jelly cut off).
    nonisolated static func userText(_ raw: String, placeholders: [String?]) -> String {
        let visible = visibleText(raw)
        guard !visible.isEmpty else { return raw }
        for case let placeholder? in placeholders
            where ComposerLabelPolicy.accepts(placeholder) && visibleText(placeholder) == visible { return "" }
        return raw
    }

    nonisolated func sameDraft(as other: DraftSnapshot) -> Bool {
        Self.visibleText(text) == Self.visibleText(other.text) && attachmentMarkers == other.attachmentMarkers
    }

    // Diagnostics only: lengths, never content.
    nonisolated func textChangeSummary(from before: DraftSnapshot) -> String {
        "; text=\(before.text.count)->\(text.count) visible=\(Self.visibleText(before.text).count)->\(Self.visibleText(text).count)"
    }
}

struct TargetLease {
    let pid: pid_t
    let initialSnapshot: DraftSnapshot
    fileprivate let application: NSRunningApplication
    fileprivate let window: AXUIElement
    fileprivate let composer: AXUIElement
    fileprivate let webArea: AXUIElement
    fileprivate let conversation: ConversationIdentity<AXIdentityKey>
    fileprivate let originatingFrontmostPID: pid_t
    var isNewDraft: Bool { if case .newDraft = conversation { return true }; return false }
    func sameDestination(as other: any ChatLease) -> Bool {
        guard let other = other as? TargetLease else { return false }
        return pid == other.pid && CFEqual(window, other.window) && conversation == other.conversation
    }
}

// Equality is AX object equality, never a title, DOM position, route guess or
// recently used conversation. The wrapper retains the referenced AX element.
fileprivate struct AXIdentityKey: Equatable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
}

struct SidebarConversationProof<Key: Equatable>: Equatable {
    let button: Key
    let list: Key
    let webArea: Key
    let kind: ThreadListKind
    // Labels are only an additional change detector, never an identity. They stay
    // in process memory and are excluded from diagnostics.
    let buttonLabel: [String]
    let routeEvidence: [String]
}

enum ConversationIdentity<Key: Equatable>: Equatable {
    case route(String)
    case sidebar(SidebarConversationProof<Key>)
    case newDraft(NewDraftConversationProof<Key>)
}

struct NewDraftContextProof<Key: Equatable>: Equatable {
    let key: Key
    let labels: [String]
    let value: String?
    let selected: Bool?
}

struct NewDraftConversationProof<Key: Equatable>: Equatable {
    let composerPath: [Key]
    let homePath: [Key]
    let labels: [String]
    let context: [NewDraftContextProof<Key>]
}

// Exact editor labels from the installed 26.1013.40934 renderer and locales.
// These identify a composer only; a new draft also needs positive home evidence.
enum ComposerLabelPolicy {
    static let established: Set<String> = [
        // "和 Codex 一起工作" is the zh-CN text in the 2026-10-17 ChatGPT update.
        "Work with Codex", "与 Codex 协作", "和 Codex 一起工作", "與 Codex 協作",
        "Ask ChatGPT", "询问 ChatGPT", "問問 ChatGPT", "問 ChatGPT",
        "Work with ChatGPT", "使用 ChatGPT Work", "與 ChatGPT 協作", "與 ChatGPT 一起工作"
    ]
    static let newLabels: Set<String> = [
        "Do anything", "随心输入", "想做什麼都可以", "輸入任何任務",
        "New chat in this project", "此项目中的新聊天", "此專案中的新對話", "在此項目中開始新對話"
    ]
    // ChatGPT's "Your Dot" page: restricted.aeonMessaging.roomUi.messageInput in app 26.1027.
    // "Message" is a generic word, so it only counts together with the Dot row's proof
    // (SidebarIdentityPolicy) and only where no ordinary composer is present.
    // Only the languages whose attachment labels isRemoveMarker can read: elsewhere a paste could never be confirmed.
    static let dotLabels: Set<String> = ["Message", "消息", "訊息"]
    static func dot(_ label: String) -> Bool { dotLabels.contains(label) }
    static func existing(_ label: String) -> Bool { established.contains(label) }
    static func accepts(_ label: String) -> Bool {
        if existing(label) || newLabels.contains(label) || dot(label) { return true }
        return [("New chat in ", ""), ("在“", "”中新建聊天"), ("在 ", " 中開始新對話")].contains {
            label.hasPrefix($0.0) && label.hasSuffix($0.1) && label.count > $0.0.count + $0.1.count
        }
    }
}

enum NewDraftIdentityPolicy {
    static let homeClass = "[container-name:home-main-content]"
    static let modeLabels: Set<String> = ["Composer mode", "撰写器模式", "撰寫器模式"]
    static func isProjectSelector(_ label: String) -> Bool {
        if ["Choose project", "选择项目", "選擇專案"].contains(label) { return true }
        return ["Change project: ", "切换项目：", "更改项目：", "變更專案："].contains {
            label.hasPrefix($0) && label.count > $0.count
        }
    }

    // The recorded Codex placeholder changes after attaching an image. Permit that
    // one presentation-only transition at readback, only when explicit mode controls,
    // their values/selections, project context and every retained path are unchanged.
    // Pre-paste revalidation continues to require exact proof equality.
    static func matchesAfterAppend<Key: Equatable>(_ before: ConversationIdentity<Key>,
        _ after: ConversationIdentity<Key>, hasExpectedAddition: Bool) -> Bool {
        if before == after { return true }
        guard hasExpectedAddition, case .newDraft(let old) = before,
              case .newDraft(let new) = after,
              old.composerPath == new.composerPath, old.homePath == new.homePath,
              old.context == new.context,
              old.context.contains(where: { $0.labels.contains(where: modeLabels.contains) }),
              old.labels == ["和 Codex 一起工作"], new.labels == ["使用 ChatGPT Work"] else { return false }
        return true
    }

    static func analyze<Key: Equatable>(nodes: [SidebarIdentityNode<Key>], webArea: Int,
        composer: Int, composerLabels: [String], existing: SidebarIdentityAnalysis<Key>) -> ConversationIdentity<Key>? {
        guard existing.identity == nil, existing.currentCount == 0, existing.routeCount == 0,
              [.threadListUnavailable, .currentThreadUnavailable].contains(existing.failure),
              nodes.indices.contains(webArea), nodes[webArea].role == "AXWebArea",
              nodes.indices.contains(composer), ["AXTextArea", "AXTextField"].contains(nodes[composer].role),
              !composerLabels.isEmpty, composerLabels.allSatisfy(ComposerLabelPolicy.accepts) else { return nil }
        func path(_ start: Int) -> [Int]? {
            var result: [Int] = []; var seen = Set<Int>(); var next: Int? = start
            while let index = next {
                guard nodes.indices.contains(index), seen.insert(index).inserted, !nodes[index].hidden else { return nil }
                result.append(index)
                if nodes[index].role == "AXWebArea" { return index == webArea ? result : nil }
                next = nodes[index].parent
            }
            return nil
        }
        guard let composerPath = path(composer) else { return nil }
        let homes = nodes.indices.filter { nodes[$0].classes.contains(homeClass) && path($0) != nil }
        guard homes.count == 1, let home = homes.first, let homePath = path(home),
              !homePath.contains(composer) else { return nil }
        // The compact home composer is a sibling of the main landmark. Both
        // retained paths must belong to this one document; there must already be
        // exactly one eligible composer in inspect(). No sidebar absence fallback.
        var context: [NewDraftContextProof<Key>] = []
        let modes = nodes.indices.filter {
            nodes[$0].labels.contains(where: modeLabels.contains) &&
                path($0).map { !$0.contains(composer) } == true
        }
        guard modes.count <= 1 else { return nil }
        for index in nodes.indices {
            guard let chain = path(index), !chain.contains(composer) else { continue }
            let project = nodes[index].role == "AXButton" && nodes[index].labels.contains(where: isProjectSelector)
            let mode = modes.contains { chain.contains($0) }
            guard project || mode else { continue }
            context.append(NewDraftContextProof(key: nodes[index].key, labels: nodes[index].labels,
                value: nodes[index].value, selected: nodes[index].selected))
        }
        return .newDraft(NewDraftConversationProof(composerPath: composerPath.map { nodes[$0].key },
            homePath: homePath.map { nodes[$0].key }, labels: composerLabels.sorted(), context: context))
    }
}

enum ThreadListKind: String { case chats, pinned, threadRows, dot }

// This projection is also used by the pure tests. It contains no AX operations.
struct SidebarIdentityNode<Key: Equatable> {
    let key: Key
    let parent: Int?
    let role: String
    var labels: [String] = []
    var classes: Set<String> = []
    var current: String? = nil
    var route: String? = nil
    var hidden = false
    var value: String? = nil
    var selected: Bool? = nil
}

struct SidebarIdentityAnalysis<Key: Equatable> {
    let identity: ConversationIdentity<Key>?
    let failure: TargetFailure?
    let listKinds: Set<ThreadListKind>
    let listCount: Int
    let currentCount: Int
    let routeCount: Int
    var diagnostic: String {
        let categories = listKinds.map(\.rawValue).sorted().joined(separator: ",")
        let mode: String
        switch identity { case .route?: mode = "route"; case .sidebar?: mode = "sidebar"; case .newDraft?: mode = "new-draft"; case nil: mode = "none" }
        return "identity=\(mode); lists=\(listCount); listKinds=\(categories.isEmpty ? "none" : categories); current=\(currentCount); routes=\(routeCount)"
    }
}

enum SidebarIdentityPolicy {
    // This complete token occurs only in the installed app's thread-row renderer
    // _zo, which passes it to ORo with hasNavigationLink:false. It is an actual
    // DOM class, not an attempt to read an unexposed arbitrary data attribute.
    static let threadClass = "data-[app-action-sidebar-thread-selected=true]:bg-primary-ghost-hover"
    static let chatsLabels: Set<String> = ["Chats", "聊天", "對話"]
    static let pinnedLabels: Set<String> = ["Pinned", "置顶", "已固定", "已釘選"]

    static func analyze<Key: Equatable>(nodes: [SidebarIdentityNode<Key>], webArea: Int,
                                        composer: Int, documentRoutes: Set<String>,
                                        dotComposer: Bool = false, documentTitle: String? = nil) -> SidebarIdentityAnalysis<Key> {
        var kinds = Set<ThreadListKind>()
        var lists = Set<Int>()
        var candidates: [(button: Int, list: Int, kind: ThreadListKind)] = []
        func result(_ identity: ConversationIdentity<Key>? = nil, _ error: TargetFailure? = nil,
                    routes: Int? = nil) -> SidebarIdentityAnalysis<Key> {
            SidebarIdentityAnalysis(identity: identity, failure: error, listKinds: kinds,
                                    listCount: lists.count, currentCount: candidates.count,
                                    routeCount: routes ?? documentRoutes.count)
        }
        guard nodes.indices.contains(webArea), nodes.indices.contains(composer),
              nodes[webArea].role == "AXWebArea" else { return result(nil, .webAreaUnavailable) }

        // Reject malformed projections rather than walking a cycle or a different
        // document. Runtime projection parents come from the bounded AX traversal.
        func ancestors(_ index: Int) -> [Int]? {
            var chain: [Int] = []; var next = nodes[index].parent; var seen = Set([index])
            while let parent = next {
                guard nodes.indices.contains(parent), seen.insert(parent).inserted else { return nil }
                chain.append(parent); next = nodes[parent].parent
            }
            return chain
        }
        guard let composerAncestors = ancestors(composer),
              composerAncestors.first(where: { nodes[$0].role == "AXWebArea" }) == webArea else {
            return result(nil, .webAreaUnavailable)
        }
        for index in nodes.indices where nodes[index].role == "AXList" {
            guard !nodes[index].hidden, let chain = ancestors(index), !chain.contains(composer),
                  chain.first(where: { nodes[$0].role == "AXWebArea" }) == webArea else { continue }
            if nodes[index].labels.contains(where: chatsLabels.contains) { kinds.insert(.chats); lists.insert(index) }
            if nodes[index].labels.contains(where: pinnedLabels.contains) { kinds.insert(.pinned); lists.insert(index) }
        }
        for index in nodes.indices where nodes[index].role == "AXButton" {
            let node = nodes[index]
            // The Dot's row is not a thread row: page-current inside a sidebar list, named like the open
            // document, is its proof (the label may add an unread count after the name, and the Dot can be
            // renamed, so no fixed name). The nav rail's Home button is also current, but not in a list.
            if dotComposer, !node.hidden, node.current == "page", !node.classes.contains(threadClass),
               let title = documentTitle, !title.isEmpty, node.labels.contains(where: { $0.hasPrefix(title) }),
               let chain = ancestors(index), !chain.contains(composer),
               !chain.contains(where: { nodes[$0].hidden }),
               chain.first(where: { nodes[$0].role == "AXWebArea" }) == webArea,
               let listPosition = chain.firstIndex(where: { nodes[$0].role == "AXList" }),
               let webPosition = chain.firstIndex(of: webArea), listPosition < webPosition {
                kinds.insert(.dot); lists.insert(chain[listPosition])
                candidates.append((index, chain[listPosition], .dot))
                continue
            }
            guard !node.hidden, node.classes.contains("sidebar-item"), node.classes.contains(threadClass),
                  let chain = ancestors(index), !chain.contains(composer),
                  !chain.contains(where: { nodes[$0].hidden }),
                  chain.first(where: { nodes[$0].role == "AXWebArea" }) == webArea,
                  let listPosition = chain.firstIndex(where: { nodes[$0].role == "AXList" }),
                  let webPosition = chain.firstIndex(of: webArea), listPosition < webPosition else { continue }
            let list = chain[listPosition]
            let kind: ThreadListKind
            if nodes[list].labels.contains(where: chatsLabels.contains) { kind = .chats }
            else if nodes[list].labels.contains(where: pinnedLabels.contains) { kind = .pinned }
            else { kind = .threadRows }
            kinds.insert(kind); lists.insert(list)
            // "true" and AXSelected are deliberately not accepted as page identity.
            guard node.current == "page" else { continue }
            candidates.append((index, list, kind))
        }
        guard candidates.count <= 1 else { return result(nil, .currentThreadsAmbiguous) }
        guard documentRoutes.count <= 1 else { return result(nil, .conversationConflict) }
        // A composer labelled like the Dot's is only accepted on the Dot's page.
        if dotComposer, candidates.first?.kind != .dot {
            return result(nil, lists.isEmpty ? .threadListUnavailable : .currentThreadUnavailable)
        }
        guard let current = candidates.first else {
            if let route = documentRoutes.first { return result(.route(route)) }
            return result(nil, lists.isEmpty ? .threadListUnavailable : .currentThreadUnavailable)
        }
        var routes = documentRoutes
        if let route = nodes[current.button].route { routes.insert(route) }
        guard routes.count <= 1 else { return result(nil, .conversationConflict, routes: routes.count) }
        return result(.sidebar(SidebarConversationProof(button: nodes[current.button].key,
            list: nodes[current.list].key, webArea: nodes[webArea].key, kind: current.kind,
            // The Dot's row label carries its unread count, which changes while the press runs.
            buttonLabel: current.kind == .dot ? [] : nodes[current.button].labels,
            routeEvidence: routes.sorted())), routes: routes.count)
    }
}

enum AppendReadback { case pending, confirmed }

// Attachment labels are trusted only in the leased composer's document, outside
// editor content and with visible ancestry. A nested document or another window
// panel cannot acknowledge this transaction. The remove control itself may be
// opacity-hidden until hover, so visibility is required of its ancestors.
enum AttachmentMarkerScopePolicy {
    static func hasNativeCard<Key: Equatable>(nodes: [SidebarIdentityNode<Key>],
        webArea: Int, composer: Int, filename: String) -> Bool {
        let scan = AttachmentGeometryPolicy.removalScan(nodes: nodes,
            webArea: webArea, composer: composer, filename: filename)
        guard scan.reason == "remove-found" else { return false }
        // Semantic evidence does not depend on optional clipping/rectangle limits.
        return scan.ancestors.prefix(8).filter {
            AttachmentGeometryPolicy.cardClasses.isSubset(of: nodes[$0].classes)
        }.count == 1
    }

    static func contains<Key: Equatable>(_ index: Int, nodes: [SidebarIdentityNode<Key>],
                                        webArea: Int, composer: Int) -> Bool {
        guard nodes.indices.contains(index), nodes[index].role == "AXButton",
              nodes.indices.contains(webArea), nodes[webArea].role == "AXWebArea",
              nodes.indices.contains(composer) else { return false }
        var seen = Set<Int>(); var cursor = nodes[index].parent
        while let parent = cursor {
            guard nodes.indices.contains(parent), seen.insert(parent).inserted,
                  parent != composer, !nodes[parent].hidden else { return false }
            if nodes[parent].role == "AXWebArea" { return parent == webArea }
            cursor = nodes[parent].parent
        }
        return false
    }
}

// Optional decoration policy. This never selects an input field or changes
// append acknowledgement. It uses only the already inspected semantic tree.
enum AttachmentGeometryPolicy {
    struct Candidate: Equatable {
        let index: Int
        let clippingAncestors: [Int]
    }
    static let cardClasses: Set<String> = ["composer-attachment-surface", "group/composer-attachment"]

    struct RemovalScan {
        let removeCount: Int
        let ancestors: [Int]
        let reason: String
    }

    static func removalScan<Key: Equatable>(nodes: [SidebarIdentityNode<Key>], webArea: Int,
                                            composer: Int, filename: String) -> RemovalScan {
        func result(_ reason: String, count: Int = 0, ancestors: [Int] = []) -> RemovalScan {
            RemovalScan(removeCount: count, ancestors: ancestors, reason: reason)
        }
        guard !filename.isEmpty, nodes.indices.contains(webArea), nodes.indices.contains(composer),
              nodes[webArea].role == "AXWebArea" else { return result("invalid-scope") }
        let removeLabels: Set<String> = ["Remove \(filename)", "移除 \(filename)", "移除“\(filename)”"]
        func path(_ start: Int) -> [Int]? {
            var result: [Int] = []; var seen = Set<Int>(); var next: Int? = start
            while let index = next {
                guard nodes.indices.contains(index), seen.insert(index).inserted,
                      index != composer else { return nil }
                result.append(index)
                if nodes[index].role == "AXWebArea" { return index == webArea ? result : nil }
                next = nodes[index].parent
            }
            return nil
        }
        let removes = nodes.indices.filter { index in
            nodes[index].role == "AXButton" && nodes[index].labels.contains(where: removeLabels.contains) &&
                path(index) != nil
        }
        guard removes.count == 1, let remove = removes.first, let removePath = path(remove) else {
            return result(removes.isEmpty ? "remove-missing-in-scope" : "remove-ambiguous", count: removes.count)
        }
        // The renderer deliberately hides the remove control with opacity:0
        // until hover. Its own visibility is not the thumbnail's visibility.
        // Every containing ancestor, including the document, must remain visible.
        guard !removePath.dropFirst().contains(where: { nodes[$0].hidden }) else {
            return result("hidden-ancestor", count: 1)
        }
        return result("remove-found", count: 1, ancestors: Array(removePath.dropFirst().dropLast()))
    }

    static func candidate<Key: Equatable>(nodes: [SidebarIdentityNode<Key>], webArea: Int,
                                          composer: Int, filename: String) -> Candidate? {
        let scan = removalScan(nodes: nodes, webArea: webArea, composer: composer, filename: filename)
        guard scan.reason == "remove-found" else { return nil }
        let cards = scan.ancestors.prefix(8).filter { cardClasses.isSubset(of: nodes[$0].classes) }
        guard cards.count == 1, let card = cards.first,
              let cardOffset = scan.ancestors.firstIndex(of: card) else { return nil }
        let clips = scan.ancestors.dropFirst(cardOffset + 1).filter { nodes[$0].role == "AXScrollArea" }
        // Bound the optional work. Unusual nesting simply gets no overlay.
        guard clips.count <= 2 else { return nil }
        return Candidate(index: card, clippingAncestors: clips)
    }

    static func validFrame(_ frame: CGRect, window: CGRect, clippingFrames: [CGRect]) -> Bool {
        func valid(_ rect: CGRect) -> Bool {
            [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite) &&
                rect.size.width > 0 && rect.size.height > 0
        }
        guard valid(frame), valid(window), window.contains(frame) else { return false }
        return clippingFrames.allSatisfy { valid($0) && $0.contains(frame) }
    }
}

// Value decoding and cache bookkeeping are pure: these helpers never query an
// application. AX returns one slot per requested attribute, including explicit
// missing/error slots; omitting one must never shift a later attribute's meaning.
enum InspectionAttributeBatch {
    enum Slot {
        case value(CFTypeRef)
        case missing
    }

    static func decode(attributes: [String], values: [AnyObject]) throws -> [String: Slot] {
        guard !attributes.isEmpty, Set(attributes).count == attributes.count,
              values.count == attributes.count else { throw TargetFailure.treeUnavailable }
        var result: [String: Slot] = [:]
        for (attribute, raw) in zip(attributes, values) {
            if CFGetTypeID(raw) == CFNullGetTypeID() {
                result[attribute] = .missing
            } else if CFGetTypeID(raw) == AXValueGetTypeID(),
                      AXValueGetType(unsafeBitCast(raw, to: AXValue.self)) == .axError {
                var error = AXError.failure
                guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .axError, &error) else {
                    throw TargetFailure.treeUnavailable
                }
                guard error == .attributeUnsupported || error == .noValue else {
                    throw TargetFailure.treeUnavailable
                }
                result[attribute] = .missing
            } else {
                result[attribute] = .value(raw)
            }
        }
        return result
    }
}

struct InspectionAttributeCache {
    private var entries: [Int: [String: InspectionAttributeBatch.Slot]] = [:]

    func missingAttributes(node: Int, attributes: [String]) -> [String] {
        attributes.filter { entries[node]?[$0] == nil }
    }

    mutating func store(node: Int, slots: [String: InspectionAttributeBatch.Slot]) {
        entries[node, default: [:]].merge(slots) { _, new in new }
    }

    func values(node: Int, attributes: [String]) -> [String: CFTypeRef] {
        var result: [String: CFTypeRef] = [:]
        for attribute in attributes {
            if case .value(let value)? = entries[node]?[attribute] { result[attribute] = value }
        }
        return result
    }
}

enum TargetFailure: LocalizedError, Equatable {
    case denied, appUnavailable, windowsAmbiguous, windowUnavailable
    case treeUnavailable, composerUnavailable, conversationUnavailable
    case webAreaUnavailable, threadListUnavailable, currentThreadUnavailable
    case currentThreadsAmbiguous, conversationConflict, conversationChanged
    case accessibilityPreparationFailed, accessibilityPreparationChanged, accessibilityPreparationBusy
    case targetChanged, draftChanged, selectionUnavailable, selectedText
    case modalPresent, focusFailed, attachmentMismatch
    // Claude: two chat tiles side by side and nothing says which one is meant.
    case composersAmbiguous

    var errorDescription: String? {
        switch self {
        case .denied: return L("Toss needs Accessibility. Nothing pasted.", "Toss 需要辅助功能，什么都没贴。")
        case .appUnavailable: return L("ChatGPT / Codex or Claude isn't running.", "ChatGPT / Codex 或 Claude 没在运行。")
        case .windowsAmbiguous: return L("Several windows. Bring the one you want forward.", "有好几个窗口，把要贴的切到前面。")
        case .windowUnavailable: return L("The chat window is hidden or minimized.", "聊天窗口被隐藏或最小化了。")
        case .treeUnavailable: return L("Can't read the chat yet. Try again shortly.", "还读不到聊天窗口，等一下再试。")
        case .composerUnavailable: return L("No message box. Open a chat and try again.", "找不到输入框，打开一个聊天再试。")
        case .conversationUnavailable: return L("Unsure which chat. Stopped to avoid a mistake.", "确认不了是哪个聊天，已停止。")
        case .webAreaUnavailable: return L("No message box. Open a chat and try again.", "找不到输入框，打开一个聊天再试。")
        case .threadListUnavailable: return L("Can't find the sidebar. Show it and retry.", "认不出侧栏，展开它再试。")
        case .currentThreadUnavailable: return L("Unsure which chat is open. Nothing pasted.", "认不出当前聊天，什么都没贴。")
        case .currentThreadsAmbiguous: return L("Several chats look current. Stopped.", "好几个聊天都像当前的，已停止。")
        case .conversationConflict: return L("Sidebar and page disagree. Nothing pasted.", "侧栏和页面对不上，什么都没贴。")
        case .conversationChanged: return L("The chat changed meanwhile. Nothing pasted.", "截图时聊天变了，什么都没贴。")
        case .accessibilityPreparationFailed: return L("Accessibility not confirmed. Shortcuts off.", "辅助功能没确认，快捷键已关闭。")
        case .accessibilityPreparationChanged: return L("ChatGPT / Codex restarted. Turn shortcuts on.", "ChatGPT / Codex 重启了，请再打开快捷键。")
        case .accessibilityPreparationBusy: return L("Still preparing Accessibility. Please wait.", "辅助功能还在准备，请稍等。")
        case .targetChanged: return L("The window or chat changed. Stopped.", "窗口或聊天变了，已停止。")
        case .draftChanged: return L("The draft changed. Stopped, no retry.", "草稿变了，已停止，不重试。")
        case .selectionUnavailable: return L("Couldn't check for selected text. Nothing pasted.", "确认不了有没有选中文字。")
        case .selectedText: return L("Text is selected. Nothing pasted.", "输入框里有选中的文字，没贴。")
        case .modalPresent: return L("A dialog is open. Nothing pasted.", "窗口开着对话框，什么都没贴。")
        case .focusFailed: return L("Couldn't focus the box. Click it, try again.", "没能聚焦输入框，点一下再试。")
        case .attachmentMismatch: return L("The attachment looks off. Check your draft.", "附件不太对，请看看草稿。")
        case .composersAmbiguous: return L("Two Claude chats side by side. Click one.", "开着两个并排的 Claude，点一下要贴的。")
        }
    }
}

@MainActor
final class StrictTarget {
    static let bundleID = "com.openai.codex"
    private(set) var diagnosticSummary = "stage=idle"
    // AX global top-left coordinates, sampled only after a confirmed append.
    // Consumers must use immediately; these are never a target-selection input.
    private(set) var latestConfirmedAttachmentFrame: CGRect?
    private(set) var latestConfirmedAttachmentFrameTimestamp: TimeInterval?
    private(set) var latestAttachmentGeometryStatus = "not-requested"
    // A consumption receipt is weaker than preserved-draft success. The caller
    // may use it to restore its clipboard after a user edit, never to claim success.
    private(set) var latestPasteConsumptionConfirmed = false
    // Text the user typed into the leased composer while the screenshot was on its way
    // (Ashley 2026-10-28: never give up, paste in the original place). The readback compares
    // against it instead of the text at the keypress.
    private var acceptedDraftText: String?
    private(set) var latestPasteConsumptionFilename: String?
    private(set) var accessibilityPreparationSummary = "method=AXEnhancedUserInterface; settableStatus=not-queried; setStatus=not-attempted; phase=idle"
    private var accessibilitySettableStatus = "not-queried"
    private var accessibilitySetStatus = "not-attempted"
    private var accessibilityPreparationInFlight = false
    private var preparedAccessibilityApplication: NSRunningApplication?
    private var preparedAccessibilityLaunchDate: Date?
    private var preparedAccessibilityRequestUncertain = false
    // Synchronous inspections run on MainActor and never overlap. Every AX read
    // gets at most 80 ms and is skipped once this monotonic total budget expires.
    private var inspectionDeadline: TimeInterval?

    // Exact labels from the installed 26.1007.30912 JavaScript and translations.
    // Neither a generic text field nor the label "Ask ..." is accepted.
    static let composerLabels = ComposerLabelPolicy.established

    private struct Node {
        let element: AXUIElement
        let parent: Int?
        let role: String
    }
    private struct AttachmentGeometryProbe {
        let nodes: [Node]
        let projected: [SidebarIdentityNode<AXIdentityKey>]
        let webAreaIndex: Int
        let composerIndex: Int
        let filename: String
        let hasComposerAttachmentCard: Bool
    }

    // Called only when the user enables this companion. Chromium's
    // BrowserCrApplication accepts AXEnhancedUserInterface and schedules complete
    // screen-reader mode after two seconds. Waiting is asynchronous; repeating the
    // setter would keep resetting that timer. This is an accessibility-mode request,
    // not a preference, permission grant, window activation, or draft mutation.
    // The setter's success is NOT proof that aria-current will be available: locate
    // and every subsequent lease check still require the actual semantic evidence.
    func prepareAccessibility() async throws {
        try Task.checkCancellation()
        guard !accessibilityPreparationInFlight else { throw TargetFailure.accessibilityPreparationBusy }
        guard AXIsProcessTrusted() else {
            recordAccessibilityPreparation(phase: "permission-denied")
            throw TargetFailure.denied
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .filter { !$0.isTerminated }
        guard apps.count == 1, let application = apps.first else {
            recordAccessibilityPreparation(phase: "app-unavailable")
            throw TargetFailure.appUnavailable
        }
        let launchDate = application.launchDate
        if let prepared = preparedAccessibilityApplication, !prepared.isTerminated,
           prepared.processIdentifier == application.processIdentifier, prepared == application,
           preparedAccessibilityLaunchDate == launchDate {
            recordAccessibilityPreparation(phase: preparedAccessibilityRequestUncertain ? "request-uncertain" : "cached")
            return
        }
        preparedAccessibilityApplication = nil
        preparedAccessibilityLaunchDate = nil
        preparedAccessibilityRequestUncertain = false
        accessibilityPreparationInFlight = true
        defer { accessibilityPreparationInFlight = false }
        accessibilitySettableStatus = "not-queried"
        accessibilitySetStatus = "not-attempted"
        recordAccessibilityPreparation(phase: "preparing")

        func sameApplicationIsRunning() -> Bool {
            guard !application.isTerminated, application.bundleIdentifier == Self.bundleID,
                  application.launchDate == launchDate else { return false }
            let current = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
                .filter { !$0.isTerminated }
            return current.count == 1 && current[0] == application &&
                current[0].processIdentifier == application.processIdentifier && current[0].launchDate == launchDate
        }

        do {
            let applicationAX = AXUIElementCreateApplication(application.processIdentifier)
            // Bound both synchronous AX operations. There is no AX window-tree
            // traversal, getter loop, focus operation, keyboard event or fallback.
            let timeoutStatus = AXUIElementSetMessagingTimeout(applicationAX, 0.25)
            guard timeoutStatus == .success else {
                accessibilitySetStatus = "timeout-setup-\(Self.accessibilityStatusName(timeoutStatus))"
                recordAccessibilityPreparation(phase: "failed")
                throw TargetFailure.accessibilityPreparationFailed
            }
            var settable = DarwinBoolean(false)
            let attribute = "AXEnhancedUserInterface" as CFString
            let settableStatus = AXUIElementIsAttributeSettable(applicationAX, attribute, &settable)
            accessibilitySettableStatus = settableStatus == .success
                ? (settable.boolValue ? "yes" : "no") : Self.accessibilityStatusName(settableStatus)
            // Chromium overrides this setter and then calls super. Keep the
            // settable result so the one observed inherited not-implemented return
            // can be distinguished from unsupported or rejected requests.
            try Task.checkCancellation()
            guard sameApplicationIsRunning() else {
                recordAccessibilityPreparation(phase: "process-changed")
                throw TargetFailure.accessibilityPreparationChanged
            }
            let setStatus = AXUIElementSetAttributeValue(applicationAX, attribute, kCFBooleanTrue)
            accessibilitySetStatus = Self.accessibilityStatusName(setStatus)
            let requestUncertain = setStatus == .notImplemented &&
                settableStatus == .success && settable.boolValue
            guard setStatus == .success || requestUncertain else {
                recordAccessibilityPreparation(phase: "failed")
                throw TargetFailure.accessibilityPreparationFailed
            }
            // The user's 0.1.4 run returned settable=yes / not-implemented. The
            // Chromium handler schedules its mode change before delegating to
            // super, so wait once without claiming it worked or resending it.
            // Actual current-thread semantics remain mandatory in locate().
            recordAccessibilityPreparation(phase: requestUncertain ? "request-uncertain" : "waiting")
            try await Task.sleep(nanoseconds: 2_500_000_000)
            try Task.checkCancellation()
            guard sameApplicationIsRunning() else {
                recordAccessibilityPreparation(phase: "process-changed")
                throw TargetFailure.accessibilityPreparationChanged
            }
            preparedAccessibilityApplication = application
            preparedAccessibilityLaunchDate = launchDate
            preparedAccessibilityRequestUncertain = requestUncertain
            recordAccessibilityPreparation(phase: requestUncertain ? "request-uncertain" : "ready")
        } catch is CancellationError {
            recordAccessibilityPreparation(phase: "cancelled")
            throw CancellationError()
        }
        // No false write on disable/exit: that could interfere with VoiceOver or
        // another accessibility client. Nothing is persisted to app preferences.
    }

    private func recordAccessibilityPreparation(phase: String) {
        accessibilityPreparationSummary = "method=AXEnhancedUserInterface; settableStatus=\(accessibilitySettableStatus); setStatus=\(accessibilitySetStatus); phase=\(phase)"
    }

    nonisolated private static func accessibilityStatusName(_ status: AXError) -> String {
        switch status {
        case .success: return "success"
        case .attributeUnsupported: return "attribute-unsupported"
        case .cannotComplete: return "cannot-complete"
        case .apiDisabled: return "api-disabled"
        case .invalidUIElement: return "invalid-element"
        case .illegalArgument: return "illegal-argument"
        case .notImplemented: return "not-implemented"
        case .noValue: return "no-value"
        case .failure: return "failure"
        default: return "code-\(status.rawValue)"
        }
    }

    func locate() throws -> TargetLease {
        acceptedDraftText = nil
        diagnosticSummary = "stage=locate"
        guard AXIsProcessTrusted() else { throw TargetFailure.denied }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .filter { !$0.isTerminated }
        guard apps.count == 1, let app = apps.first,
              let foreground = NSWorkspace.shared.frontmostApplication else {
            throw TargetFailure.appUnavailable
        }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 0.08)
        let windows = try windowCandidates(app: app, appAX: appAX)
        let window: AXUIElement
        if foreground.processIdentifier == app.processIdentifier {
            guard let focused = element(appAX, "AXFocusedWindow"),
                  windows.contains(where: { CFEqual($0, focused) }) else {
                throw TargetFailure.windowUnavailable
            }
            window = focused
        } else {
            guard windows.count == 1 else { throw TargetFailure.windowsAmbiguous }
            window = windows[0]
        }
        let (composer, webArea, conversation, snapshot, _) = try inspect(window)
        return TargetLease(pid: app.processIdentifier, initialSnapshot: snapshot,
                           application: app, window: window, composer: composer,
                           webArea: webArea, conversation: conversation,
                           originatingFrontmostPID: foreground.processIdentifier)
    }

    // The app is already in front (TargetActivator, as for any press). Bring the lease's own window
    // forward if it still exists; waits up to ~0.5 s for it to become the focused window.
    func raiseWindow(_ lease: TargetLease) async throws {
        guard AXIsProcessTrusted(), !lease.application.isTerminated,
              let windows = elements(AXUIElementCreateApplication(lease.pid), "AXWindows"),
              windows.contains(where: { CFEqual($0, lease.window) }) else { throw TargetFailure.windowUnavailable }
        let appAX = AXUIElementCreateApplication(lease.pid)
        if let focused = element(appAX, "AXFocusedWindow"), CFEqual(focused, lease.window) { return }
        if bool(lease.window, "AXMinimized") == true {
            guard AXUIElementSetAttributeValue(lease.window, "AXMinimized" as CFString, kCFBooleanFalse) == .success else {
                throw TargetFailure.windowUnavailable
            }
        }
        _ = AXUIElementSetAttributeValue(lease.window, "AXMain" as CFString, kCFBooleanTrue)
        guard AXUIElementPerformAction(lease.window, "AXRaise" as CFString) == .success else { throw TargetFailure.focusFailed }
        for _ in 0..<25 {
            try Task.checkCancellation()
            if let focused = element(appAX, "AXFocusedWindow"), CFEqual(focused, lease.window) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TargetFailure.focusFailed
    }

    // Press this exact chat's sidebar item / link once (Codex app: the very AX element and labels
    // recorded in its sidebar proof; Claude: the exact document URL), only in the lease's own window
    // and page, never through a dialog, and only if exactly one item matches.
    func openConversation(_ lease: TargetLease) throws {
        guard !lease.isNewDraft else { throw TargetFailure.conversationChanged }
        let previousDeadline = inspectionDeadline
        inspectionDeadline = ProcessInfo.processInfo.systemUptime + 1
        defer { inspectionDeadline = previousDeadline }
        let nodes = try tree(lease.window)
        for node in nodes where node.role == "AXSheet" || node.role == "AXDialog" ||
            string(node.element, "AXSubrole") == "AXDialog" || bool(node.element, "AXModal") == true {
            _ = node; throw TargetFailure.modalPresent
        }
        func ancestry(_ index: Int) -> [Int] {
            var chain: [Int] = []; var next = nodes[index].parent
            while let parent = next { chain.append(parent); next = nodes[parent].parent }
            return chain
        }
        let candidates = nodes.indices.filter { index in
            let node = nodes[index]
            guard ["AXButton", "AXLink"].contains(node.role), bool(node.element, "AXHidden") != true,
                  bool(node.element, "AXEnabled") != false else { return false }
            let chain = ancestry(index)
            guard !chain.contains(where: { bool(nodes[$0].element, "AXHidden") == true }),
                  let webIndex = chain.first(where: { nodes[$0].role == "AXWebArea" }),
                  CFEqual(nodes[webIndex].element, lease.webArea) else { return false }
            switch lease.conversation {
            case .sidebar(let proof) where proof.kind == .dot:
                return CFEqual(node.element, proof.button.element) &&
                    chain.contains(where: { CFEqual(nodes[$0].element, proof.list.element) })
            case .sidebar(let proof):
                let labels = ["AXDescription", "AXTitle"].compactMap { string(node.element, $0) }
                let classes = value(node.element, "AXDOMClassList") as? [String] ?? []
                return CFEqual(node.element, proof.button.element) && labels == proof.buttonLabel &&
                    classes.contains("sidebar-item") && classes.contains(SidebarIdentityPolicy.threadClass) &&
                    chain.contains(where: { CFEqual(nodes[$0].element, proof.list.element) })
            case .route(let expected):
                guard let raw = urlString(node.element, "AXURL"), Self.conversationRoute(raw) == expected else { return false }
                let classes = value(node.element, "AXDOMClassList") as? [String] ?? []
                return node.role == "AXLink" || classes.contains(SidebarIdentityPolicy.threadClass)
            case .newDraft: return false
            }
        }
        guard candidates.count == 1, let index = candidates.first,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid,
              let focused = element(AXUIElementCreateApplication(lease.pid), "AXFocusedWindow"), CFEqual(focused, lease.window),
              AXUIElementPerformAction(nodes[index].element, "AXPress" as CFString) == .success else {
            throw TargetFailure.conversationChanged
        }
    }

    // Call once after capture, again after focus, and immediately before Cmd+V.
    // It never silently refreshes the transaction to a newly selected chat.
    func revalidate(_ lease: TargetLease, requireFocused: Bool = false) throws {
        diagnosticSummary = "stage=revalidate-window"
        try validateWindow(lease, requireFocused: requireFocused)
        let (composer, webArea, conversation, snapshot, _) = try inspect(lease.window)
        // AX traversal may take seconds while another process handles user input.
        // Recheck the window/focus after those synchronous cross-process reads.
        try validateWindow(lease, requireFocused: requireFocused)
        guard CFEqual(composer, lease.composer), CFEqual(webArea, lease.webArea) else { throw TargetFailure.targetChanged }
        guard conversation == lease.conversation else {
            diagnosticSummary += "; lease=changed"
            throw TargetFailure.conversationChanged
        }
        // Same chat and composer: typing there is the user's own text, kept as it is; the
        // picture is only added. Changed attachments still stop (the readback counts them).
        guard snapshot.attachmentMarkers == lease.initialSnapshot.attachmentMarkers else {
            diagnosticSummary += snapshot.textChangeSummary(from: lease.initialSnapshot)
            throw TargetFailure.draftChanged
        }
        if !snapshot.sameDraft(as: lease.initialSnapshot) {
            diagnosticSummary += snapshot.textChangeSummary(from: lease.initialSnapshot) + "; typed=kept"
            acceptedDraftText = snapshot.text
        } else {
            acceptedDraftText = nil // typed text deleted again: the readback expects the original
        }
    }

    // Focus only. No text mutation, selection mutation, mouse click or submit.
    func focus(_ lease: TargetLease) async throws {
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid else {
            throw TargetFailure.targetChanged
        }
        // When this exact composer already owns keyboard input (0.7.1: usually,
        // because it was focused while the screenshot was in flight), return
        // without a full tree read: the caller performs a full validation with
        // requireFocused after publishing the clipboard, right before its sole
        // paste event, so a third identical read here only added latency.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid {
            let appAX = AXUIElementCreateApplication(lease.pid)
            if let window = element(appAX, "AXFocusedWindow"), CFEqual(window, lease.window),
               let focused = element(appAX, "AXFocusedUIElement"), CFEqual(focused, lease.composer),
               bool(lease.composer, "AXFocused") == true,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid {
                try Task.checkCancellation()
                return
            }
        }
        try revalidate(lease)
        try Task.checkCancellation()
        // If the user switched away while activation was settling, do not raise
        // our window again or steal focus back from their new foreground app.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid else {
            throw TargetFailure.targetChanged
        }
        // The app must already have the exact leased window focused. Validation
        // never selects a replacement window or a newly displayed conversation.
        try validateWindow(lease, requireFocused: false, requireForeground: true)
        // Raising precisely the leased window is allowed; activateAllWindows is not.
        guard AXUIElementPerformAction(lease.window, "AXRaise" as CFString) == .success else {
            throw TargetFailure.focusFailed
        }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid else {
            throw TargetFailure.targetChanged
        }
        guard AXUIElementSetAttributeValue(lease.composer, "AXFocused" as CFString,
                                          kCFBooleanTrue) == .success else {
            throw TargetFailure.focusFailed
        }
        // Chromium applies AX focus asynchronously. Poll for it (min 20 ms,
        // max 150 ms) instead of a fixed 70 ms; revalidate() still decides.
        let focusDeadline = ProcessInfo.processInfo.systemUptime + 0.15
        try await Task.sleep(nanoseconds: 20_000_000)
        while ProcessInfo.processInfo.systemUptime < focusDeadline {
            try Task.checkCancellation()
            let appAX = AXUIElementCreateApplication(lease.pid)
            if let focused = element(appAX, "AXFocusedUIElement"), CFEqual(focused, lease.composer),
               bool(lease.composer, "AXFocused") == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
        try revalidate(lease, requireFocused: true)
    }

    // Only an exact extra remove-button label for this capture's unique filename
    // confirms append. A posted Cmd+V event is never treated as success by itself.
    // Polling this read-only method is safe; the caller must never repeat Cmd+V.
    func verifyAppend(_ lease: TargetLease, expectedFilename: String) throws -> AppendReadback {
        latestConfirmedAttachmentFrame = nil
        latestConfirmedAttachmentFrameTimestamp = nil
        latestAttachmentGeometryStatus = "pending-confirmation"
        latestPasteConsumptionConfirmed = false
        latestPasteConsumptionFilename = nil
        // The one paste already required the exact composer focus in front. Readback reads that
        // same window, composer and chat, in front or not (2026-10-28: a click on another app right
        // after Cmd+V turned real attachments into "check your draft"); a user click on an
        // attachment control must not masquerade as a focus failure.
        try validateWindow(lease, requireFocused: false)
        let (composer, webArea, conversation, current, geometry) = try inspect(lease.window,
            geometryFilename: expectedFilename, requireEmptySelection: false)
        try validateWindow(lease, requireFocused: false)
        guard CFEqual(composer, lease.composer), CFEqual(webArea, lease.webArea) else { throw TargetFailure.targetChanged }
        // Unknown or duplicate additions remain real errors, even when the user
        // also edited text/deleted an older attachment during readback.
        let consumed = try Self.hasUniqueExpectedAddition(
            before: lease.initialSnapshot.attachmentMarkers, after: current.attachmentMarkers,
            expectedFilename: expectedFilename)
        // An exact filename somewhere in the window is insufficient: it must be
        // the app's native composer attachment card in the leased document.
        if consumed && geometry?.hasComposerAttachmentCard != true {
            throw TargetFailure.attachmentMismatch
        }
        guard NewDraftIdentityPolicy.matchesAfterAppend(lease.conversation, conversation,
                                                       hasExpectedAddition: consumed) else {
            diagnosticSummary += "; lease=changed"
            throw TargetFailure.conversationChanged
        }
        latestPasteConsumptionConfirmed = consumed
        if consumed { latestPasteConsumptionFilename = expectedFilename }
        guard DraftSnapshot.visibleText(current.text) == DraftSnapshot.visibleText(acceptedDraftText ?? lease.initialSnapshot.text) else {
            diagnosticSummary += current.textChangeSummary(from: lease.initialSnapshot)
            throw TargetFailure.draftChanged
        }
        let result = try Self.compareAttachmentMarkers(before: lease.initialSnapshot.attachmentMarkers,
                                                       after: current.attachmentMarkers,
                                                       expectedFilename: expectedFilename)
        // Best effort, after ALL existing acknowledgement checks. No second
        // tree traversal and no optional geometry failure can turn success into
        // an error, retry, or a different target.
        if result == .confirmed, let geometry,
           let rect = optionalAttachmentFrame(geometry, lease: lease) {
            latestConfirmedAttachmentFrame = rect
            latestConfirmedAttachmentFrameTimestamp = ProcessInfo.processInfo.systemUptime
        }
        return result
    }

    // Pure, separately testable policy. It does not contact an application.
    nonisolated static func compareAttachmentMarkers(before: [String: Int], after: [String: Int],
                                                     expectedFilename: String) throws -> AppendReadback {
        let consumed = try hasUniqueExpectedAddition(before: before, after: after, expectedFilename: expectedFilename)
        for (marker, count) in before where after[marker, default: 0] < count {
            throw TargetFailure.draftChanged
        }
        return consumed ? .confirmed : .pending
    }

    nonisolated static func hasUniqueExpectedAddition(before: [String: Int], after: [String: Int],
                                                      expectedFilename: String) throws -> Bool {
        guard !expectedFilename.isEmpty else { throw TargetFailure.attachmentMismatch }
        var found = false
        for (marker, count) in after {
            let added = count - before[marker, default: 0]
            guard added > 0 else { continue }
            guard added == 1, !found, isRemoveLabel(marker, filename: expectedFilename) else {
                throw TargetFailure.attachmentMismatch
            }
            found = true
        }
        return found
    }

    // Only routes actually present in this installed app are accepted. Titles,
    // visible message text, newest-thread history and generic home URLs are not IDs.
    // Query parameters (including Electron's initialRoute) never supply a route.
    nonisolated static func conversationRoute(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw) else { return nil }
        let scheme = components.scheme?.lowercased()
        // Restrict parsing to the app's document URLs or proven current thread rows.
        guard scheme == nil || ["app", "codex", "https", "file"].contains(scheme!) else { return nil }
        if scheme == "https", !["chatgpt.com", "chat.openai.com"].contains(components.host ?? "") { return nil }
        var path = components.path
        if scheme == "codex", components.host == "threads" { path = "/local" + path }
        let prefixes = ["/local/", "/remote/", "/c/"]
        for prefix in prefixes where path.hasPrefix(prefix) {
            let id = String(path.dropFirst(prefix.count))
            guard !id.isEmpty, !id.contains("/"), id.range(of: #"^[A-Za-z0-9_-]{8,128}$"#,
                      options: .regularExpression) != nil else { return nil }
            return prefix + id
        }
        return nil
    }

    private func validateWindow(_ lease: TargetLease, requireFocused: Bool,
                                requireForeground: Bool = false) throws {
        guard AXIsProcessTrusted() else { throw TargetFailure.denied }
        guard !lease.application.isTerminated,
              lease.application.bundleIdentifier == Self.bundleID else { throw TargetFailure.targetChanged }
        let appAX = AXUIElementCreateApplication(lease.pid)
        let windows = try windowCandidates(app: lease.application, appAX: appAX)
        guard windows.contains(where: { CFEqual($0, lease.window) }) else { throw TargetFailure.targetChanged }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if requireForeground && frontPID != lease.pid { throw TargetFailure.targetChanged }
        guard frontPID == lease.originatingFrontmostPID || frontPID == lease.pid else {
            throw TargetFailure.targetChanged
        }
        if frontPID == lease.pid {
            guard let focusedWindow = element(appAX, "AXFocusedWindow"), CFEqual(focusedWindow, lease.window) else {
                throw TargetFailure.targetChanged
            }
        } else if windows.count != 1 { throw TargetFailure.windowsAmbiguous }
        if requireFocused {
            guard frontPID == lease.pid,
                  let focused = element(appAX, "AXFocusedUIElement"), CFEqual(focused, lease.composer),
                  bool(lease.composer, "AXFocused") == true else { throw TargetFailure.focusFailed }
        }
    }

    private func windowCandidates(app: NSRunningApplication, appAX: AXUIElement) throws -> [AXUIElement] {
        guard !app.isHidden, let windows = elements(appAX, "AXWindows") else {
            throw TargetFailure.windowUnavailable
        }
        // On-screen WindowServer metadata is used ONLY to exclude hidden/other-space
        // windows. No screenshot is taken and no geometry selects the composer.
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            throw TargetFailure.windowUnavailable
        }
        let bounds = records.compactMap { record -> CGRect? in
            guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let rawBounds = record[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: rawBounds as CFDictionary), rect.width > 0, rect.height > 0 else { return nil }
            return rect
        }
        return windows.filter { window in
            guard string(window, "AXRole") == "AXWindow", bool(window, "AXMinimized") == false,
                  bool(window, "AXHidden") != true, bool(window, "AXModal") != true,
                  let rect = frame(window) else { return false }
            return bounds.contains { abs($0.minX - rect.minX) < 2 && abs($0.minY - rect.minY) < 2 &&
                abs($0.width - rect.width) < 2 && abs($0.height - rect.height) < 2 }
        }
    }

    private func inspect(_ window: AXUIElement, geometryFilename: String? = nil,
                         requireEmptySelection: Bool = true) throws ->
        (AXUIElement, AXUIElement, ConversationIdentity<AXIdentityKey>, DraftSnapshot, AttachmentGeometryProbe?) {
        let previousDeadline = inspectionDeadline
        inspectionDeadline = ProcessInfo.processInfo.systemUptime + 3.0
        defer { inspectionDeadline = previousDeadline }
        diagnosticSummary = "stage=read-tree"
        let nodes = try tree(window)
        // Stack-local and confined to this synchronous inspection. Nothing is
        // cached across an await, another inspection, or a target transaction.
        var attributes = InspectionAttributeCache()
        diagnosticSummary = "stage=find-composer; nodes=\(nodes.count)"
        for index in nodes.indices {
            guard nodes[index].role != "AXSheet", nodes[index].role != "AXDialog" else {
                throw TargetFailure.modalPresent
            }
            let values = try inspectionAttributes(index, nodes: nodes,
                names: ["AXSubrole", "AXModal"], cache: &attributes)
            if values["AXSubrole"] as? String == "AXDialog" || values["AXModal"] as? Bool == true {
                throw TargetFailure.modalPresent
            }
        }
        var composers: [Int] = []
        var dotComposers: [Int] = []
        for index in nodes.indices {
            let node = nodes[index]
            guard ["AXTextArea", "AXTextField"].contains(node.role) else { continue }
            let labels = ["AXDescription", "AXTitle", "AXHelp", "AXPlaceholderValue"]
            let values = try inspectionAttributes(index, nodes: nodes,
                names: ["AXEnabled", "AXHidden"] + labels, cache: &attributes)
            guard values["AXEnabled"] as? Bool == true, values["AXHidden"] as? Bool != true else { continue }
            let found = labels.compactMap { values[$0] as? String }.filter(ComposerLabelPolicy.accepts)
            if found.contains(where: { !ComposerLabelPolicy.dot($0) }) { composers.append(index) }
            else if !found.isEmpty { dotComposers.append(index) }
        }
        try checkInspectionBudget()
        // A stray "Message" field never competes with an ordinary composer.
        if composers.isEmpty { composers = dotComposers }
        diagnosticSummary += "; composers=\(composers.count)"
        guard composers.count == 1, let index = composers.first else { throw TargetFailure.composerUnavailable }
        let composer = nodes[index].element
        guard let raw = string(composer, "AXValue") else { throw TargetFailure.treeUnavailable }
        let text = DraftSnapshot.userText(raw, placeholders: [string(composer, "AXDescription"),
                                                              string(composer, "AXPlaceholderValue")])
        if requireEmptySelection {
            guard let selection = range(composer, "AXSelectedTextRange") else { throw TargetFailure.selectionUnavailable }
            guard selection.length == 0 else { throw TargetFailure.selectedText }
        }
        var ancestor = nodes[index].parent
        var webAreaIndex: Int?
        while let current = ancestor {
            if nodes[current].role == "AXWebArea" { webAreaIndex = current; break }
            ancestor = nodes[current].parent
        }
        guard let webAreaIndex else {
            diagnosticSummary += "; webArea=missing"
            throw TargetFailure.webAreaUnavailable
        }
        let webArea = nodes[webAreaIndex].element
        let labelValues = try inspectionAttributes(index, nodes: nodes,
            names: ["AXDescription", "AXTitle", "AXHelp", "AXPlaceholderValue"], cache: &attributes)
        let editorLabels = Array(Set(labelValues.values.compactMap { $0 as? String }
            .filter(ComposerLabelPolicy.accepts))).sorted()
        let (conversation, identityNodes) = try identity(webAreaIndex: webAreaIndex, composerIndex: index,
                                                         composerLabels: editorLabels, nodes: nodes, cache: &attributes)
        var projected = identityNodes
        var markers: [String: Int] = [:]
        // identity() has read visibility and labels for document buttons and all
        // their ancestors. Reuse that bounded projection instead of trusting every
        // Remove label in the complete window tree.
        for button in nodes.indices where AttachmentMarkerScopePolicy.contains(button,
            nodes: projected, webArea: webAreaIndex, composer: index) {
            if let label = projected[button].labels.first(where: Self.isRemoveMarker) {
                markers[label, default: 0] += 1
            }
        }
        try checkInspectionBudget()
        var geometry: AttachmentGeometryProbe?
        if let filename = geometryFilename {
            let scan = AttachmentGeometryPolicy.removalScan(nodes: projected,
                webArea: webAreaIndex, composer: index, filename: filename)
            // The semantic card is mandatory confirmation evidence; rectangle
            // reads remain optional decoration and can still fail independently.
            if scan.reason == "remove-found" {
                for ancestor in scan.ancestors.prefix(8) {
                    let values = try inspectionAttributes(ancestor, nodes: nodes,
                        names: ["AXDOMClassList"], cache: &attributes)
                    projected[ancestor].classes = Set(values["AXDOMClassList"] as? [String] ?? [])
                }
            }
            let hasCard = AttachmentMarkerScopePolicy.hasNativeCard(nodes: projected,
                webArea: webAreaIndex, composer: index, filename: filename)
            geometry = AttachmentGeometryProbe(nodes: nodes, projected: projected,
                webAreaIndex: webAreaIndex, composerIndex: index, filename: filename,
                hasComposerAttachmentCard: hasCard)
        }
        return (composer, webArea, conversation, DraftSnapshot(text: text, attachmentMarkers: markers), geometry)
    }

    private func identity(webAreaIndex: Int, composerIndex: Int, composerLabels: [String], nodes: [Node],
                          cache: inout InspectionAttributeCache) throws ->
        (ConversationIdentity<AXIdentityKey>, [SidebarIdentityNode<AXIdentityKey>]) {
        var documentIDs = Set<String>()
        for attribute in ["AXURL", "AXDocument"] {
            if let raw = urlString(nodes[webAreaIndex].element, attribute),
               let route = Self.conversationRoute(raw) { documentIDs.insert(route) }
        }
        var projected = nodes.map {
            SidebarIdentityNode(key: AXIdentityKey(element: $0.element), parent: $0.parent, role: $0.role)
        }
        let dotComposer = !composerLabels.isEmpty && composerLabels.allSatisfy(ComposerLabelPolicy.dot)
        var classesSupported = 0; var classesUnavailable = 0
        var currentSupported = 0; var currentUnavailable = 0
        func belongsToComposerDocument(_ index: Int) -> Bool {
            var ancestor = nodes[index].parent
            while let parent = ancestor {
                if parent == composerIndex { return false }
                if nodes[parent].role == "AXWebArea" { return parent == webAreaIndex }
                ancestor = nodes[parent].parent
            }
            return false
        }
        var relevant = Set(nodes.indices.filter {
            (nodes[$0].role == "AXButton" || nodes[$0].role == "AXList") && belongsToComposerDocument($0)
        })
        for index in Array(relevant) {
            var ancestor = nodes[index].parent
            while let parent = ancestor { relevant.insert(parent); ancestor = nodes[parent].parent }
        }
        diagnosticSummary = "stage=read-sidebar-semantics"
        for index in relevant.sorted() {
            try checkInspectionBudget()
            let node = nodes[index]
            var names = ["AXHidden"]
            if ["AXButton", "AXList"].contains(node.role) { names += ["AXDescription", "AXTitle"] }
            if node.role == "AXButton" { names.append("AXDOMClassList") }
            let values = try inspectionAttributes(index, nodes: nodes, names: names, cache: &cache)
            projected[index].hidden = values["AXHidden"] as? Bool == true
            guard ["AXButton", "AXList"].contains(node.role) else { continue }
            projected[index].labels = ["AXDescription", "AXTitle"].compactMap { values[$0] as? String }
            guard node.role == "AXButton" else { continue }
            if let classes = values["AXDOMClassList"] as? [String] {
                classesSupported += 1; projected[index].classes = Set(classes)
            } else { classesUnavailable += 1 }
            if projected[index].classes.contains(SidebarIdentityPolicy.threadClass) {
                let threadValues = try inspectionAttributes(index, nodes: nodes,
                    names: ["AXARIACurrent", "AXURL"], cache: &cache)
                if let current = threadValues["AXARIACurrent"] as? String {
                    currentSupported += 1; projected[index].current = current
                } else { currentUnavailable += 1 }
                if let raw = Self.urlString(from: threadValues["AXURL"]) {
                    projected[index].route = Self.conversationRoute(raw)
                }
            } else if dotComposer {
                let rowValues = try inspectionAttributes(index, nodes: nodes, names: ["AXARIACurrent"], cache: &cache)
                projected[index].current = rowValues["AXARIACurrent"] as? String
            }
        }
        try checkInspectionBudget()
        let analysis = SidebarIdentityPolicy.analyze(nodes: projected, webArea: webAreaIndex,
                                                     composer: composerIndex, documentRoutes: documentIDs,
                                                     dotComposer: dotComposer,
                                                     documentTitle: string(nodes[webAreaIndex].element, "AXTitle"))
        diagnosticSummary = "stage=identity; \(analysis.diagnostic); buttonClassSupported=\(classesSupported); buttonClassUnavailable=\(classesUnavailable); threadCurrentSupported=\(currentSupported); threadCurrentUnavailable=\(currentUnavailable)"
        // A stale selected sidebar row must not turn a visible new-home page
        // into an established-chat identity. Inspect only actual main landmarks.
        let mainLandmarks = nodes.indices.filter { index in
            guard belongsToComposerDocument(index) else { return false }
            return nodes[index].role == "AXLandmarkMain" ||
                cache.values(node: index, attributes: ["AXSubrole"])["AXSubrole"] as? String == "AXLandmarkMain"
        }
        for index in mainLandmarks {
            let values = try inspectionAttributes(index, nodes: nodes,
                names: ["AXDOMClassList", "AXHidden"], cache: &cache)
            projected[index].classes = Set(values["AXDOMClassList"] as? [String] ?? [])
            projected[index].hidden = values["AXHidden"] as? Bool == true
        }
        if let identity = analysis.identity {
            guard composerLabels.contains(where: { ComposerLabelPolicy.existing($0) || ComposerLabelPolicy.dot($0) }),
                  !mainLandmarks.contains(where: {
                      projected[$0].classes.contains(NewDraftIdentityPolicy.homeClass) && !projected[$0].hidden
                  }) else { throw TargetFailure.conversationConflict }
            return (identity, projected)
        }
        guard !dotComposer, [.threadListUnavailable, .currentThreadUnavailable].contains(analysis.failure) else {
            throw analysis.failure ?? TargetFailure.conversationUnavailable
        }
        // Existing chats only add the main-landmark conflict check above. For an unthreaded composer,
        // inspect its ancestors and explicit main landmarks, never every DOM node.
        var structural = Set<Int>([composerIndex, webAreaIndex])
        var cursor = nodes[composerIndex].parent
        while let index = cursor { structural.insert(index); cursor = nodes[index].parent }
        for index in nodes.indices where belongsToComposerDocument(index) {
            let values = cache.values(node: index, attributes: ["AXSubrole"])
            if nodes[index].role == "AXLandmarkMain" || values["AXSubrole"] as? String == "AXLandmarkMain" {
                structural.insert(index)
                var ancestor = nodes[index].parent
                while let parent = ancestor { structural.insert(parent); ancestor = nodes[parent].parent }
            }
        }
        for index in structural.sorted() {
            let values = try inspectionAttributes(index, nodes: nodes,
                names: ["AXDOMClassList", "AXHidden"], cache: &cache)
            projected[index].classes = Set(values["AXDOMClassList"] as? [String] ?? [])
            projected[index].hidden = values["AXHidden"] as? Bool == true
        }
        // Project controls were already labelled above. Read mode groups and their
        // controls only for this new-draft branch; ordinary send/attachment state
        // must not invalidate an otherwise successful paste acknowledgement.
        var modes = Set<Int>()
        for index in nodes.indices where belongsToComposerDocument(index) && nodes[index].role == "AXGroup" {
            let values = try inspectionAttributes(index, nodes: nodes,
                names: ["AXDescription", "AXTitle", "AXHidden"], cache: &cache)
            projected[index].labels = ["AXDescription", "AXTitle"].compactMap { values[$0] as? String }
            projected[index].hidden = values["AXHidden"] as? Bool == true
            if projected[index].labels.contains(where: NewDraftIdentityPolicy.modeLabels.contains) { modes.insert(index) }
        }
        for index in nodes.indices where belongsToComposerDocument(index) {
            var ancestor: Int? = index; var inMode = false
            while let current = ancestor { if modes.contains(current) { inMode = true; break }; ancestor = nodes[current].parent }
            let isProject = nodes[index].role == "AXButton" && projected[index].labels.contains(where: NewDraftIdentityPolicy.isProjectSelector)
            guard inMode || isProject else { continue }
            let values = try inspectionAttributes(index, nodes: nodes,
                names: ["AXDescription", "AXTitle", "AXHidden", "AXValue", "AXSelected"], cache: &cache)
            projected[index].labels = ["AXDescription", "AXTitle"].compactMap { values[$0] as? String }
            projected[index].hidden = values["AXHidden"] as? Bool == true
            projected[index].value = (values["AXValue"] as? String) ?? (values["AXValue"] as? NSNumber)?.stringValue
            projected[index].selected = values["AXSelected"] as? Bool
        }
        try checkInspectionBudget()
        guard let draft = NewDraftIdentityPolicy.analyze(nodes: projected, webArea: webAreaIndex,
            composer: composerIndex, composerLabels: composerLabels, existing: analysis) else {
            diagnosticSummary += "; newDraft=unproven"
            throw analysis.failure ?? TargetFailure.conversationUnavailable
        }
        diagnosticSummary += "; newDraft=confirmed"
        return (draft, projected)
    }

    private func optionalAttachmentFrame(_ probe: AttachmentGeometryProbe, lease: TargetLease) -> CGRect? {
        // This optional work starts only after a fully preserved append receipt.
        // The native renderer can initially expose an anonymous div, so anchor
        // to its unique exact remove control and inspect only existing ancestors.
        // The entire class/frame probe shares a 25 ms budget; no new tree walk.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.025
        var projected = probe.projected
        let scan = AttachmentGeometryPolicy.removalScan(nodes: projected, webArea: probe.webAreaIndex,
            composer: probe.composerIndex, filename: probe.filename)
        var classReads = 0; var classSupported = 0; var cardCount = 0
        func status(_ reason: String) {
            // All reasons are fixed implementation literals. No text, filename,
            // path, identity, class string or coordinates enter diagnostics.
            latestAttachmentGeometryStatus = "reason=\(reason); removes=\(scan.removeCount); ancestors=\(scan.ancestors.count); class_reads=\(classReads); class_supported=\(classSupported); cards=\(cardCount)"
        }
        func current() -> Bool {
            !Task.isCancelled && NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid
        }
        guard current() else { status("target-changed"); return nil }
        guard scan.reason == "remove-found" else { status(scan.reason); return nil }
        func read(_ element: AXUIElement, names: [String]) -> [String: InspectionAttributeBatch.Slot]? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining >= 0.001 else { status("budget-exhausted"); return nil }
            guard AXUIElementSetMessagingTimeout(element, Float(min(0.006, remaining))) == .success else {
                status("timeout-setup-failed"); return nil
            }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw) == .success else {
                status("attribute-read-failed"); return nil
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                status("budget-exhausted"); return nil
            }
            guard let values = raw as? [AnyObject],
                  let slots = try? InspectionAttributeBatch.decode(attributes: names, values: values) else {
                status("attribute-decode-failed"); return nil
            }
            return slots
        }
        for index in scan.ancestors.prefix(8) {
            // Button classes were already read by mandatory identity inspection.
            // Other ancestors need only this one attribute, never their labels.
            if projected[index].role == "AXButton" { continue }
            classReads += 1
            guard let slots = read(probe.nodes[index].element, names: ["AXDOMClassList"]) else { return nil }
            if case .value(let raw)? = slots["AXDOMClassList"] {
                guard let classes = raw as? [String] else { status("class-type-invalid"); return nil }
                projected[index].classes = Set(classes); classSupported += 1
            }
        }
        cardCount = scan.ancestors.prefix(8).filter {
            AttachmentGeometryPolicy.cardClasses.isSubset(of: projected[$0].classes)
        }.count
        guard cardCount == 1 else {
            status(cardCount == 0 ? "card-class-missing" : "card-class-ambiguous"); return nil
        }
        guard let candidate = AttachmentGeometryPolicy.candidate(nodes: projected,
            webArea: probe.webAreaIndex, composer: probe.composerIndex, filename: probe.filename) else {
            status("card-ancestry-rejected"); return nil
        }
        func readFrame(_ element: AXUIElement, missingReason: String) -> CGRect? {
            guard let slots = read(element, names: ["AXPosition", "AXSize", "AXHidden"]) else { return nil }
            guard case .value(let position)? = slots["AXPosition"],
                  case .value(let size)? = slots["AXSize"],
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
                status(missingReason); return nil
            }
            if case .value(let hidden)? = slots["AXHidden"], hidden as? Bool == true {
                status("frame-hidden"); return nil
            }
            let pointValue = unsafeBitCast(position, to: AXValue.self)
            let sizeValue = unsafeBitCast(size, to: AXValue.self)
            guard AXValueGetType(pointValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else {
                status(missingReason); return nil
            }
            var point = CGPoint.zero; var dimensions = CGSize.zero
            guard AXValueGetValue(pointValue, .cgPoint, &point),
                  AXValueGetValue(sizeValue, .cgSize, &dimensions) else { status(missingReason); return nil }
            return CGRect(origin: point, size: dimensions)
        }
        guard let card = readFrame(probe.nodes[candidate.index].element, missingReason: "card-frame-missing"),
              let window = readFrame(lease.window, missingReason: "window-frame-missing") else { return nil }
        var clips: [CGRect] = []
        for index in candidate.clippingAncestors {
            guard let frame = readFrame(probe.nodes[index].element, missingReason: "clip-frame-missing") else { return nil }
            clips.append(frame)
        }
        guard current() else { status("target-changed"); return nil }
        guard ProcessInfo.processInfo.systemUptime < deadline else { status("budget-exhausted"); return nil }
        guard AttachmentGeometryPolicy.validFrame(card, window: window, clippingFrames: clips) else {
            status("frame-outside-bounds"); return nil
        }
        status("frame-ready")
        return card
    }

    private func inspectionAttributes(_ index: Int, nodes: [Node], names: [String],
                                      cache: inout InspectionAttributeCache) throws -> [String: CFTypeRef] {
        try checkInspectionBudget()
        let missing = cache.missingAttributes(node: index, attributes: names)
        if !missing.isEmpty {
            let slots = try copyInspectionAttributes(nodes[index].element, names: missing)
            cache.store(node: index, slots: slots)
        }
        return cache.values(node: index, attributes: names)
    }

    private func copyInspectionAttributes(_ element: AXUIElement,
                                          names: [String]) throws -> [String: InspectionAttributeBatch.Slot] {
        try checkInspectionBudget()
        guard prepareAXRead(element) else { throw TargetFailure.treeUnavailable }
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw)
        try checkInspectionBudget()
        if status == .notImplemented {
            // Compatibility only for a process that does not implement batching.
            // Messaging failures, malformed results and denied reads never become
            // an optimistic empty value. Children retain their separate strict API.
            var values: [AnyObject] = []
            for name in names {
                try checkInspectionBudget()
                guard prepareAXRead(element) else { throw TargetFailure.treeUnavailable }
                var single: CFTypeRef?
                let singleStatus = AXUIElementCopyAttributeValue(element, name as CFString, &single)
                if singleStatus == .attributeUnsupported || singleStatus == .noValue {
                    values.append(kCFNull)
                } else {
                    guard singleStatus == .success, let single else { throw TargetFailure.treeUnavailable }
                    values.append(single)
                }
            }
            try checkInspectionBudget()
            return try InspectionAttributeBatch.decode(attributes: names, values: values)
        }
        guard status == .success, let values = raw as? [AnyObject] else {
            throw TargetFailure.treeUnavailable
        }
        return try InspectionAttributeBatch.decode(attributes: names, values: values)
    }

    private func tree(_ root: AXUIElement) throws -> [Node] {
        var nodes = [Node(element: root, parent: nil, role: string(root, "AXRole") ?? "")]
        var cursor = 0
        while cursor < nodes.count {
            try checkInspectionBudget()
            guard nodes.count <= 4_096 else { throw TargetFailure.treeUnavailable }
            let current = nodes[cursor].element
            let children = try childElements(current)
            if !children.isEmpty {
                for child in children {
                    try checkInspectionBudget()
                    // Avoid cycles without silently accepting an incomplete graph.
                    if nodes.contains(where: { CFEqual($0.element, child) }) { continue }
                    guard nodes.count < 4_096 else { throw TargetFailure.treeUnavailable }
                    nodes.append(Node(element: child, parent: cursor, role: string(child, "AXRole") ?? ""))
                }
            }
            cursor += 1
        }
        return nodes
    }

    private func childElements(_ element: AXUIElement) throws -> [AXUIElement] {
        try checkInspectionBudget()
        guard prepareAXRead(element) else { throw TargetFailure.treeUnavailable }
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &result)
        if status == .attributeUnsupported || status == .noValue { return [] }
        guard status == .success, let array = result as? [AnyObject], array.count <= 4_096,
              array.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
            throw TargetFailure.treeUnavailable
        }
        return array.map { unsafeBitCast($0, to: AXUIElement.self) }
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard prepareAXRead(element) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func checkInspectionBudget() throws {
        try Task.checkCancellation()
        if let deadline = inspectionDeadline,
           ProcessInfo.processInfo.systemUptime >= deadline { throw TargetFailure.treeUnavailable }
    }

    private func prepareAXRead(_ element: AXUIElement) -> Bool {
        var timeout: TimeInterval = 0.08
        if let deadline = inspectionDeadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            timeout = min(timeout, remaining)
        }
        // Avoid a near-zero timeout being interpreted by AX as its default timeout.
        guard timeout >= 0.001 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(timeout)) == .success
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String? { value(element, attribute) as? String }
    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? { value(element, attribute) as? Bool }
    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let object = value(element, attribute), CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(object, to: AXUIElement.self)
    }
    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard let array = value(element, attribute) as? [AnyObject] else { return nil }
        guard array.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
        return array.map { unsafeBitCast($0, to: AXUIElement.self) }
    }
    private func urlString(_ element: AXUIElement, _ attribute: String) -> String? {
        Self.urlString(from: value(element, attribute))
    }
    nonisolated private static func urlString(from value: CFTypeRef?) -> String? {
        if let string = value as? String { return string }
        return (value as? URL)?.absoluteString
    }
    private func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let ax = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(ax) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(ax, .cfRange, &range) ? range : nil
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    nonisolated private static func isRemoveMarker(_ label: String) -> Bool {
        label == "Remove" || label.hasPrefix("Remove ") || label == "移除" || label.hasPrefix("移除 ") || label.hasPrefix("移除“")
    }
    nonisolated private static func isRemoveLabel(_ label: String, filename: String) -> Bool {
        ["Remove \(filename)", "移除 \(filename)", "移除“\(filename)”"].contains(label)
    }
}

extension TargetLease {
    var composerElement: AXUIElement { composer }
}
