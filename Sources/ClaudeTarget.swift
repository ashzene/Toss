import AppKit
import ApplicationServices

// Claude desktop (com.anthropic.claudefordesktop 2.42304.0) target. Semantics were
// read from the user's own app with a read-only structure export on 2026-10-19:
// * The chat UI is an inner AXWebArea whose AXURL is the claude.ai route:
//   /chat/<uuid> (chat), /epitaxy/local_<uuid> (Code session), /new (new chat),
//   /epitaxy (new Code session before its first message).
//   /epitaxy/project/<id> (a project page; its composer starts a new thread, so it
//   is handled like a new chat; seen in Toss diagnostics on 2026-10-21).
// * The composer is an AXTextArea with DOM classes "tiptap ProseMirror" inside the
//   composer card (an ancestor with DOM class "bg-surface-3"). Its label
//   ("提示词" / "输入您发送给 Claude 的提示词" in Chinese) is not required, so any
//   UI language works.
// * Each composer attachment tile has a card button titled "<filename>" and a
//   remove button "<localized verb> <filename>"; chat uploads prefix the name
//   with "<digits>_", Code keeps it unchanged. Markers are recognised by the
//   attachment file extension, never by the localized verb.
// Missing semantics fail closed. No coordinate fallback, AXValue write, click
// on a sidebar row, Enter or submit exists here. Draft text stays in memory.

struct ClaudeLease: ChatLease {
    let pid: pid_t
    let initialSnapshot: DraftSnapshot
    fileprivate let application: NSRunningApplication
    fileprivate let window: AXUIElement
    fileprivate let webArea: AXUIElement
    fileprivate let composer: AXUIElement
    fileprivate let route: ClaudeRoute
    fileprivate let originatingFrontmostPID: pid_t
    var isNewDraft: Bool { route.isDraft }
    func sameDestination(as other: any ChatLease) -> Bool {
        guard let other = other as? ClaudeLease else { return false }
        return pid == other.pid && CFEqual(window, other.window) && route == other.route
    }
}

struct ClaudeRoute: Equatable {
    enum Kind: Equatable { case chat, codeSession, newChat, newCodeSession, projectPage }
    let kind: Kind
    // The complete document URL. Every later check compares it exactly.
    let url: String
    // Routes without a conversation ID: the new-draft interaction rules apply.
    var isDraft: Bool { kind == .newChat || kind == .newCodeSession || kind == .projectPage }
}

enum ClaudePolicy {
    // Composer labels observed in the installed app (Chinese UI); a match is
    // sufficient structure evidence on its own, other languages need the card.
    static let composerLabels: Set<String> = ["提示词", "输入您发送给 Claude 的提示词"]
    static let composerCardClass = "bg-surface-3"

    static func isEditor(role: String, classes: [String]) -> Bool {
        role == "AXTextArea" && classes.contains("ProseMirror") && classes.contains("tiptap")
    }

    static func isComposer(role: String, label: String?, classes: [String], insideComposerCard: Bool) -> Bool {
        isEditor(role: role, classes: classes) && (insideComposerCard || label.map(composerLabels.contains) == true)
    }

    // Several composers and none focused: two chat tiles side by side (seen
    // 2026-10-22, Claude 3.1623.1). Rule (b) below; false requires a click instead.
    static let usesLastPastedComposer = true

    struct ComposerCandidate: Equatable {
        var holdsFocus = false // The focused element is inside this candidate's chat column.
        var lastPasted = false // The composer of the last confirmed paste in this window.
        var onScreen = false
    }

    // Picks only when the structure says which: (a) focus inside exactly one
    // candidate's chat column, else (b) the last confirmed paste's composer if
    // it is still a candidate and on screen. Anything else is ambiguous: nil.
    static func chooseComposer(_ candidates: [ComposerCandidate],
                               allowLastPasted: Bool = usesLastPastedComposer) -> Int? {
        let focused = candidates.indices.filter { candidates[$0].holdsFocus }
        if focused.count == 1 { return focused[0] }
        guard focused.isEmpty, allowLastPasted else { return nil }
        let last = candidates.indices.filter { candidates[$0].lastPasted && candidates[$0].onScreen }
        return last.count == 1 ? last[0] : nil
    }

    // Each candidate's chat column: its highest ancestor that holds no other
    // candidate. Structural only; parent[i] is node i's parent index.
    static func chatColumns(of candidates: [Int], parent: [Int?]) -> [Int] {
        candidates.map { candidate in
            var column = candidate
            var current = parent[candidate]
            while let node = current,
                  !candidates.contains(where: { $0 != candidate && isInside($0, node, parent: parent) }) {
                column = node
                current = parent[node]
            }
            return column
        }
    }

    static func isInside(_ node: Int, _ ancestor: Int, parent: [Int?]) -> Bool {
        var current: Int? = node
        while let value = current {
            if value == ancestor { return true }
            current = parent[value]
        }
        return false
    }

    // Attachment evidence must belong to this editor's card. A web area can
    // also contain sent messages, Code output and another chat tile.
    static func attachmentScope(composer: Int, card: Int?, webArea: Int,
                                composers: [Int], parent: [Int?]) -> Int? {
        guard let card, card != webArea,
              isInside(card, webArea, parent: parent),
              isInside(composer, card, parent: parent),
              composers.filter({ isInside($0, card, parent: parent) }) == [composer] else { return nil }
        return card
    }

    // An unsupported children attribute is normal for a leaf. A failed or
    // timed-out read is not an empty subtree: it may hide another composer,
    // a modal or an attachment that changed while capturing.
    static func treeChildren<Element>(_ children: [Element]?, error: AXError?) throws -> [Element] {
        if let children { return children }
        guard error == .attributeUnsupported || error == .noValue else { throw TargetFailure.treeUnavailable }
        return []
    }

    // Only the observed route shapes identify a conversation. Titles,
    // sidebar order and message text never do.
    static func route(_ raw: String) -> ClaudeRoute? {
        guard let components = URLComponents(string: raw), components.scheme == "https",
              components.host == "claude.ai", components.fragment == nil else { return nil }
        let path = components.path
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        if path.range(of: "^/chat/\(uuid)$", options: .regularExpression) != nil {
            return ClaudeRoute(kind: .chat, url: raw)
        }
        if path.range(of: "^/epitaxy/local_\(uuid)$", options: .regularExpression) != nil {
            return ClaudeRoute(kind: .codeSession, url: raw)
        }
        if path == "/new" { return ClaudeRoute(kind: .newChat, url: raw) }
        if path == "/epitaxy" { return ClaudeRoute(kind: .newCodeSession, url: raw) }
        if path.range(of: "^/epitaxy/project/[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil {
            return ClaudeRoute(kind: .projectPage, url: raw)
        }
        return nil
    }

    // Diagnostics only: the route's shape with every identifier-like segment
    // replaced, e.g. "claude.ai/project/<id>". No query, fragment or ID survives.
    static func routeShape(_ raw: String) -> String {
        guard let components = URLComponents(string: raw) else { return "unparseable" }
        let segments = components.path.split(separator: "/").prefix(4).map { segment -> String in
            let text = String(segment)
            let identifierLike = text.count > 24 || text.rangeOfCharacter(from: .decimalDigits) != nil
            return identifierLike || text.range(of: "^[A-Za-z_-]{1,24}$", options: .regularExpression) == nil
                ? "<id>" : text
        }
        let host = ["claude.ai", "localhost"].contains(components.host ?? "") ? components.host! : "<host>"
        return "\(components.scheme ?? "?")://\(host)/" + segments.joined(separator: "/")
    }

    static let attachmentExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "pdf",
                                       "txt", "md", "csv", "json", "docx", "xlsx", "pptx", "py", "swift"]

    // An attachment card or its remove button: a button label naming a file.
    static func isAttachmentMarker(_ label: String) -> Bool {
        var trimmed = label.trimmingCharacters(in: .whitespaces)
        while let last = trimmed.last, "”\"」』)）".contains(last) { trimmed.removeLast() }
        guard let dot = trimmed.lastIndex(of: "."), dot != trimmed.startIndex else { return false }
        return attachmentExtensions.contains(trimmed[trimmed.index(after: dot)...].lowercased())
    }

    // The label names exactly this capture's unique PNG, alone or after a
    // localized verb ("移除 ", "Remove "...), optionally behind the numeric upload
    // prefix the chat UI adds ("1792378332002_") and inside closing quotes.
    static func refersToFile(_ label: String, filename: String) -> Bool {
        guard !filename.isEmpty else { return false }
        var text = label
        while let last = text.last, "”\"」』)）".contains(last) { text.removeLast() }
        guard text.hasSuffix(filename) else { return false }
        var head = String(text.dropLast(filename.count))
        if head.hasSuffix("_") {
            head.removeLast()
            let digits = head.reversed().prefix { $0.isASCII && $0.isNumber }
            guard (6...20).contains(digits.count) else { return false }
            head.removeLast(digits.count)
        }
        guard let boundary = head.last else { return true }
        return boundary.isWhitespace || "“\"「『(（:：".contains(boundary)
    }

    // Kept for the remove-button wording verified in the Chinese and English UI.
    static func isRemoveLabel(_ label: String, filename: String) -> Bool {
        (label.hasPrefix("移除 ") || label.hasPrefix("Remove ")) && refersToFile(label, filename: filename)
    }

    // Confirmed when the only new markers are this file's card and/or remove
    // button, each appearing once. Anything else new is a mismatch.
    static func hasUniqueExpectedAddition(before: [String: Int], after: [String: Int],
                                          expectedFilename: String) throws -> Bool {
        guard !expectedFilename.isEmpty else { throw TargetFailure.attachmentMismatch }
        var added = 0
        for (marker, count) in after {
            let increase = count - before[marker, default: 0]
            guard increase > 0 else { continue }
            guard increase == 1, refersToFile(marker, filename: expectedFilename) else {
                throw TargetFailure.attachmentMismatch
            }
            added += 1
        }
        guard added <= 2 else { throw TargetFailure.attachmentMismatch }
        return added > 0
    }

    static func compareAttachmentMarkers(before: [String: Int], after: [String: Int],
                                         expectedFilename: String) throws -> AppendReadback {
        let consumed = try hasUniqueExpectedAddition(before: before, after: after, expectedFilename: expectedFilename)
        for (marker, count) in before where after[marker, default: 0] < count {
            throw TargetFailure.draftChanged
        }
        return consumed ? .confirmed : .pending
    }
}

@MainActor
final class ClaudeTarget {
    static let bundleID = "com.anthropic.claudefordesktop"
    private(set) var diagnosticSummary = "stage=idle"
    private(set) var latestConfirmedAttachmentFrame: CGRect?
    private(set) var latestAttachmentGeometryStatus = "not-requested"
    private(set) var latestPasteConsumptionConfirmed = false
    // Text typed into the leased composer before the paste; kept, see StrictTarget.
    private var acceptedDraftText: String?
    private(set) var latestPasteConsumptionFilename: String?
    private(set) var accessibilityPreparationSummary = "method=AXManualAccessibility; phase=idle"
    private var preparedPID: pid_t?
    private var preparedLaunchDate: Date?
    private var preparing = false
    private var inspectionDeadline: TimeInterval?
    // Candidates seen by the latest inspection, for capture-history.jsonl.
    private(set) var lastComposerCount: Int?
    // Rule (b): the composer of the last confirmed paste. Memory only; it applies
    // only to the same Claude process and window.
    private var lastPasted: (pid: pid_t, launchDate: Date?, window: AXUIElement, composer: AXUIElement)?

    private struct Node {
        let element: AXUIElement
        let parent: Int?
        let role: String
    }

    // Electron builds its full accessibility tree only after a client sets
    // AXManualAccessibility. Requested once per Claude process; it changes no
    // window, draft or preference. locate() still requires the real semantics.
    func prepareAccessibility() async throws {
        guard AXIsProcessTrusted() else { throw TargetFailure.denied }
        guard let app = runningApplication() else {
            accessibilityPreparationSummary = "method=AXManualAccessibility; phase=app-unavailable"
            throw TargetFailure.appUnavailable
        }
        if preparedPID == app.processIdentifier, preparedLaunchDate == app.launchDate { return }
        guard !preparing else { throw TargetFailure.accessibilityPreparationBusy }
        preparing = true
        defer { preparing = false }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 0.25)
        let status = AXUIElementSetAttributeValue(appAX, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        accessibilityPreparationSummary = "method=AXManualAccessibility; set=\(status.rawValue); phase=waiting"
        guard status == .success else {
            accessibilityPreparationSummary = "method=AXManualAccessibility; set=\(status.rawValue); phase=failed"
            throw TargetFailure.accessibilityPreparationFailed
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        guard !app.isTerminated, runningApplication() == app else {
            accessibilityPreparationSummary = "method=AXManualAccessibility; phase=process-changed"
            throw TargetFailure.accessibilityPreparationChanged
        }
        preparedPID = app.processIdentifier
        preparedLaunchDate = app.launchDate
        accessibilityPreparationSummary = "method=AXManualAccessibility; set=0; phase=ready"
    }

    func locate() throws -> ClaudeLease {
        acceptedDraftText = nil
        diagnosticSummary = "target=claude; stage=locate"
        guard AXIsProcessTrusted() else { throw TargetFailure.denied }
        guard let app = runningApplication(), let foreground = NSWorkspace.shared.frontmostApplication else {
            throw TargetFailure.appUnavailable
        }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 0.08)
        let windows = try windowCandidates(app: app, appAX: appAX)
        let window: AXUIElement
        if foreground.processIdentifier == app.processIdentifier {
            guard let focused = element(appAX, "AXFocusedWindow"),
                  windows.contains(where: { CFEqual($0, focused) }) else { throw TargetFailure.windowUnavailable }
            window = focused
        } else {
            guard windows.count == 1 else { throw TargetFailure.windowsAmbiguous }
            window = windows[0]
        }
        var remembered: AXUIElement?
        if let lastPasted {
            if lastPasted.pid == app.processIdentifier, lastPasted.launchDate == app.launchDate,
               CFEqual(lastPasted.window, window) {
                remembered = lastPasted.composer
            } else { self.lastPasted = nil } // Claude restarted or another window.
        }
        let inspection = try inspect(window, appAX: appAX, focusedInFront: foreground.processIdentifier == app.processIdentifier,
                                     rememberedComposer: remembered)
        return ClaudeLease(pid: app.processIdentifier, initialSnapshot: inspection.snapshot, application: app,
                           window: window, webArea: inspection.webArea, composer: inspection.composer,
                           route: inspection.route, originatingFrontmostPID: foreground.processIdentifier)
    }

    // The app is already in front (TargetActivator, as for any press). Bring the lease's own window
    // forward if it still exists; waits up to ~0.5 s for it to become the focused window.
    func raiseWindow(_ lease: ClaudeLease) async throws {
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
    func openConversation(_ lease: ClaudeLease) throws {
        guard !lease.isNewDraft else { throw TargetFailure.conversationChanged }
        let previousDeadline = inspectionDeadline
        inspectionDeadline = ProcessInfo.processInfo.systemUptime + 1
        defer { inspectionDeadline = previousDeadline }
        let nodes = try tree(lease.window)
        for node in nodes where node.role == "AXSheet" || node.role == "AXDialog" ||
            ["AXDialog", "AXApplicationDialog"].contains(string(node.element, "AXSubrole") ?? "") ||
            bool(node.element, "AXModal") == true {
            _ = node; throw TargetFailure.modalPresent
        }
        let candidates = nodes.indices.filter { index in
            let node = nodes[index]
            guard ["AXLink", "AXButton"].contains(node.role), bool(node.element, "AXHidden") != true,
                  bool(node.element, "AXEnabled") != false,
                  let raw = urlString(node.element), ClaudePolicy.route(raw) == lease.route else { return false }
            var ancestor = node.parent
            while let parent = ancestor {
                if bool(nodes[parent].element, "AXHidden") == true { return false }
                if nodes[parent].role == "AXWebArea" { return CFEqual(nodes[parent].element, lease.webArea) }
                ancestor = nodes[parent].parent
            }
            return false
        }
        guard candidates.count == 1, let index = candidates.first,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid,
              let focused = element(AXUIElementCreateApplication(lease.pid), "AXFocusedWindow"), CFEqual(focused, lease.window),
              AXUIElementPerformAction(nodes[index].element, "AXPress" as CFString) == .success else {
            throw TargetFailure.conversationChanged
        }
    }

    func revalidate(_ lease: ClaudeLease, requireFocused: Bool = false) throws {
        diagnosticSummary = "target=claude; stage=revalidate-window"
        try validateWindow(lease, requireFocused: requireFocused)
        let inspection = try inspect(lease.window, appAX: AXUIElementCreateApplication(lease.pid),
                                     focusedInFront: NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid,
                                     expectedComposer: lease.composer)
        // AX inspection can block while the user changes the active window.
        // Do not authorize a paste from a foreground observation made before it.
        try validateWindow(lease, requireFocused: requireFocused)
        guard CFEqual(inspection.composer, lease.composer), CFEqual(inspection.webArea, lease.webArea) else {
            throw TargetFailure.targetChanged
        }
        guard inspection.route == lease.route else {
            diagnosticSummary += "; lease=changed"
            throw TargetFailure.conversationChanged
        }
        guard inspection.snapshot.attachmentMarkers == lease.initialSnapshot.attachmentMarkers else {
            throw TargetFailure.draftChanged
        }
        // Latest typed text in the leased composer (nil once it matches the original again).
        acceptedDraftText = inspection.snapshot.text != lease.initialSnapshot.text ? inspection.snapshot.text : nil
    }

    // Focus only: activate Claude, raise the leased window, focus the leased
    // composer. No click, selection change, text change or submit.
    func focus(_ lease: ClaudeLease) async throws {
        try Task.checkCancellation()
        // TargetActivator already selected the target before issuing the lease.
        // A later app switch is user input, not a reason to steal focus back.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid else {
            throw TargetFailure.targetChanged
        }
        // Already focused: no full tree read here; the caller's requireFocused
        // validation right before the sole paste is the authoritative check.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid {
            let appAX = AXUIElementCreateApplication(lease.pid)
            if let window = element(appAX, "AXFocusedWindow"), CFEqual(window, lease.window),
               let focused = element(appAX, "AXFocusedUIElement"), CFEqual(focused, lease.composer),
               bool(lease.composer, "AXFocused") == true {
                return
            }
        }
        try revalidate(lease)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid else {
            throw TargetFailure.targetChanged
        }
        try validateWindow(lease, requireFocused: false, requireForeground: true)
        guard AXUIElementPerformAction(lease.window, "AXRaise" as CFString) == .success else {
            throw TargetFailure.focusFailed
        }
        guard AXUIElementSetAttributeValue(lease.composer, "AXFocused" as CFString, kCFBooleanTrue) == .success else {
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

    func verifyAppend(_ lease: ClaudeLease, expectedFilename: String) throws -> AppendReadback {
        latestConfirmedAttachmentFrame = nil
        latestAttachmentGeometryStatus = "pending-confirmation"
        latestPasteConsumptionConfirmed = false
        latestPasteConsumptionFilename = nil
        // Same window, composer and chat as the paste, in front or not (a click on another app right
        // after Cmd+V must not turn a real attachment into "check your draft").
        try validateWindow(lease, requireFocused: false)
        let inspection = try inspect(lease.window, appAX: AXUIElementCreateApplication(lease.pid),
                                     focusedInFront: NSWorkspace.shared.frontmostApplication?.processIdentifier == lease.pid,
                                     requireEmptySelection: false,
                                     expectedComposer: lease.composer, geometryFilename: expectedFilename)
        try validateWindow(lease, requireFocused: false)
        guard CFEqual(inspection.composer, lease.composer), CFEqual(inspection.webArea, lease.webArea) else {
            throw TargetFailure.targetChanged
        }
        guard inspection.route == lease.route else {
            diagnosticSummary += "; lease=changed"
            throw TargetFailure.conversationChanged
        }
        let before = lease.initialSnapshot.attachmentMarkers
        let after = inspection.snapshot.attachmentMarkers
        latestPasteConsumptionConfirmed = try ClaudePolicy.hasUniqueExpectedAddition(
            before: before, after: after, expectedFilename: expectedFilename)
        if latestPasteConsumptionConfirmed { latestPasteConsumptionFilename = expectedFilename }
        guard inspection.snapshot.text == (acceptedDraftText ?? lease.initialSnapshot.text) else { throw TargetFailure.draftChanged }
        let result = try ClaudePolicy.compareAttachmentMarkers(before: before, after: after,
                                                               expectedFilename: expectedFilename)
        if result == .confirmed {
            lastPasted = (lease.pid, lease.application.launchDate, lease.window, lease.composer)
            if let frame = inspection.attachmentFrame {
                latestConfirmedAttachmentFrame = frame
                latestAttachmentGeometryStatus = "reason=frame-ready"
            } else { latestAttachmentGeometryStatus = "reason=frame-missing" }
        }
        return result
    }

    // MARK: - Inspection

    private struct Inspection {
        let composer: AXUIElement
        let webArea: AXUIElement
        let route: ClaudeRoute
        let snapshot: DraftSnapshot
        let attachmentFrame: CGRect?
    }

    private func inspect(_ window: AXUIElement, appAX: AXUIElement, focusedInFront: Bool,
                         requireEmptySelection: Bool = true, expectedComposer: AXUIElement? = nil,
                         rememberedComposer: AXUIElement? = nil, geometryFilename: String? = nil) throws -> Inspection {
        lastComposerCount = nil
        let previous = inspectionDeadline
        inspectionDeadline = ProcessInfo.processInfo.systemUptime + 1.5
        defer { inspectionDeadline = previous }
        diagnosticSummary = "target=claude; stage=read-tree"
        let nodes = try tree(window)
        diagnosticSummary = "target=claude; stage=find-composer; nodes=\(nodes.count)"
        var composers: [Int] = []
        var markerButtons: [(index: Int, label: String)] = []
        for index in nodes.indices {
            try checkBudget()
            let node = nodes[index]
            if node.role == "AXSheet" || node.role == "AXDialog" { throw TargetFailure.modalPresent }
            let values = read(node.element, ["AXSubrole", "AXModal", "AXDescription", "AXTitle", "AXDOMClassList", "AXEnabled"])
            let subrole = values["AXSubrole"] as? String
            if subrole == "AXDialog" || subrole == "AXApplicationDialog" || values["AXModal"] as? Bool == true {
                throw TargetFailure.modalPresent
            }
            let label = values["AXDescription"] as? String
            if node.role == "AXTextArea" {
                let classes = values["AXDOMClassList"] as? [String] ?? []
                if ClaudePolicy.isEditor(role: node.role, classes: classes), values["AXEnabled"] as? Bool != false,
                   ClaudePolicy.isComposer(role: node.role, label: label, classes: classes,
                                           insideComposerCard: hasComposerCard(index, nodes: nodes)) {
                    composers.append(index)
                }
            } else if node.role == "AXButton" {
                for text in [label, values["AXTitle"] as? String].compactMap({ $0 })
                where ClaudePolicy.isAttachmentMarker(text) {
                    markerButtons.append((index, text))
                    break
                }
            }
        }
        diagnosticSummary += "; composers=\(composers.count)"
        lastComposerCount = composers.count
        let composerIndex: Int
        if let expectedComposer {
            // Revalidation keeps the leased object; a second composer elsewhere
            // (another Code tile) is allowed only if this one still exists.
            guard let match = composers.first(where: { CFEqual(nodes[$0].element, expectedComposer) }) else {
                throw TargetFailure.targetChanged
            }
            composerIndex = match
        } else if composers.count == 1 {
            composerIndex = composers[0]
        } else if composers.count > 1, focusedInFront, let focused = element(appAX, "AXFocusedUIElement"),
                  let match = composers.first(where: { CFEqual(nodes[$0].element, focused) }) {
            composerIndex = match
        } else if composers.count > 1 {
            composerIndex = try chooseComposer(composers, nodes: nodes, window: window, appAX: appAX,
                                               focusedInFront: focusedInFront, remembered: rememberedComposer)
        } else { throw TargetFailure.composerUnavailable }
        let composer = nodes[composerIndex].element
        guard let text = string(composer, "AXValue") else { throw TargetFailure.treeUnavailable }
        if requireEmptySelection {
            guard let selection = range(composer, "AXSelectedTextRange") else { throw TargetFailure.selectionUnavailable }
            guard selection.length == 0 else { throw TargetFailure.selectedText }
        }
        // The composer must belong to exactly the claude.ai document, not the shell.
        var ancestor = nodes[composerIndex].parent
        var webAreaIndex: Int?
        while let current = ancestor {
            if nodes[current].role == "AXWebArea" { webAreaIndex = current; break }
            ancestor = nodes[current].parent
        }
        guard let webAreaIndex else { throw TargetFailure.webAreaUnavailable }
        let webArea = nodes[webAreaIndex].element
        guard let rawURL = urlString(webArea) else {
            diagnosticSummary += "; route=missing"
            throw TargetFailure.conversationUnavailable
        }
        guard let route = ClaudePolicy.route(rawURL) else {
            diagnosticSummary += "; route=unsupported; shape=\(ClaudePolicy.routeShape(rawURL))"
            throw TargetFailure.conversationUnavailable
        }
        diagnosticSummary += "; route=\(route.kind)"
        // Attachments live in the composer card. Counting only there keeps file
        // names elsewhere (sidebar, Code output list) from looking like drafts.
        // Any removal aborts; any unknown addition is a mismatch. Labels stay in memory.
        guard let scope = ClaudePolicy.attachmentScope(composer: composerIndex,
                card: composerCard(composerIndex, nodes: nodes), webArea: webAreaIndex,
                composers: composers, parent: nodes.map(\.parent)) else {
            diagnosticSummary += "; attachments=unscoped"
            throw TargetFailure.composerUnavailable
        }
        var markers: [String: Int] = [:]
        var expectedButton: Int?
        for button in markerButtons where isDescendant(button.index, of: scope, nodes: nodes) {
            markers[button.label, default: 0] += 1
            if let geometryFilename, expectedButton == nil,
               ClaudePolicy.refersToFile(button.label, filename: geometryFilename) {
                expectedButton = button.index
            }
        }
        diagnosticSummary += "; attachments=\(markers.values.reduce(0, +))"
        var attachmentFrame: CGRect?
        if let expectedButton {
            // The card button fills its tile; the remove button sits on the tile.
            attachmentFrame = frame(nodes[expectedButton].element).flatMap { $0.width >= 40 ? $0 : nil }
                ?? nodes[expectedButton].parent.flatMap { frame(nodes[$0].element) }
        }
        return Inspection(composer: composer, webArea: webArea, route: route,
                          snapshot: DraftSnapshot(text: text, attachmentMarkers: markers),
                          attachmentFrame: attachmentFrame)
    }

    // Several composers, none focused. Only the choice is new: the lease, route,
    // draft snapshot, attachment and pre-paste focus checks all still apply.
    private func chooseComposer(_ composers: [Int], nodes: [Node], window: AXUIElement, appAX: AXUIElement,
                                focusedInFront: Bool, remembered: AXUIElement?) throws -> Int {
        let parent = nodes.map(\.parent)
        let columns = ClaudePolicy.chatColumns(of: composers, parent: parent)
        var focusedIndex: Int?
        if focusedInFront, let focused = element(appAX, "AXFocusedUIElement") {
            for index in nodes.indices {
                try checkBudget()
                if CFEqual(nodes[index].element, focused) { focusedIndex = index; break }
            }
        }
        let windowFrame = frame(window)
        let candidates = composers.indices.map { position -> ClaudePolicy.ComposerCandidate in
            let element = nodes[composers[position]].element
            let rect = frame(element)
            return ClaudePolicy.ComposerCandidate(
                holdsFocus: focusedIndex.map { ClaudePolicy.isInside($0, columns[position], parent: parent) } ?? false,
                lastPasted: remembered.map { CFEqual($0, element) } ?? false,
                onScreen: rect.map { $0.width > 0 && $0.height > 0 && windowFrame?.intersects($0) == true } ?? false)
        }
        guard let pick = ClaudePolicy.chooseComposer(candidates) else {
            diagnosticSummary += "; pick=ambiguous"
            throw TargetFailure.composersAmbiguous
        }
        diagnosticSummary += candidates[pick].holdsFocus ? "; pick=focus-column" : "; pick=last-pasted"
        return composers[pick]
    }

    // Observed: the composer card is 4-5 levels above the editor.
    private func composerCard(_ index: Int, nodes: [Node]) -> Int? {
        var current = nodes[index].parent
        var depth = 0
        while let value = current, depth < 7 {
            if let classes = self.value(nodes[value].element, "AXDOMClassList") as? [String],
               classes.contains(ClaudePolicy.composerCardClass) { return value }
            current = nodes[value].parent
            depth += 1
        }
        return nil
    }

    private func hasComposerCard(_ index: Int, nodes: [Node]) -> Bool { composerCard(index, nodes: nodes) != nil }

    private func isDescendant(_ index: Int, of ancestorIndex: Int, nodes: [Node]) -> Bool {
        var current = nodes[index].parent
        while let value = current {
            if value == ancestorIndex { return true }
            current = nodes[value].parent
        }
        return false
    }

    private func validateWindow(_ lease: ClaudeLease, requireFocused: Bool, requireForeground: Bool = false) throws {
        guard AXIsProcessTrusted() else { throw TargetFailure.denied }
        guard !lease.application.isTerminated, lease.application.bundleIdentifier == Self.bundleID else {
            throw TargetFailure.targetChanged
        }
        let appAX = AXUIElementCreateApplication(lease.pid)
        let windows = try windowCandidates(app: lease.application, appAX: appAX)
        guard windows.contains(where: { CFEqual($0, lease.window) }) else { throw TargetFailure.targetChanged }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if requireForeground && frontPID != lease.pid { throw TargetFailure.targetChanged }
        guard frontPID == lease.originatingFrontmostPID || frontPID == lease.pid else { throw TargetFailure.targetChanged }
        if frontPID == lease.pid {
            guard let focusedWindow = element(appAX, "AXFocusedWindow"), CFEqual(focusedWindow, lease.window) else {
                throw TargetFailure.targetChanged
            }
        } else if windows.count != 1 { throw TargetFailure.windowsAmbiguous }
        if requireFocused {
            guard frontPID == lease.pid, let focused = element(appAX, "AXFocusedUIElement"),
                  CFEqual(focused, lease.composer), bool(lease.composer, "AXFocused") == true else {
                throw TargetFailure.focusFailed
            }
        }
    }

    private func runningApplication() -> NSRunningApplication? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).filter { !$0.isTerminated }
        return apps.count == 1 ? apps[0] : nil
    }

    private func windowCandidates(app: NSRunningApplication, appAX: AXUIElement) throws -> [AXUIElement] {
        guard !app.isHidden, let windows = elements(appAX, "AXWindows") else { throw TargetFailure.windowUnavailable }
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            throw TargetFailure.windowUnavailable
        }
        let bounds = records.compactMap { record -> CGRect? in
            guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let raw = record[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.width > 0, rect.height > 0 else { return nil }
            return rect
        }
        return windows.filter { window in
            guard string(window, "AXRole") == "AXWindow", string(window, "AXSubrole") == "AXStandardWindow",
                  bool(window, "AXMinimized") == false, bool(window, "AXModal") != true,
                  let rect = frame(window) else { return false }
            return bounds.contains { abs($0.minX - rect.minX) < 2 && abs($0.minY - rect.minY) < 2 &&
                abs($0.width - rect.width) < 2 && abs($0.height - rect.height) < 2 }
        }
    }

    // MARK: - AX helpers (bounded)

    private func tree(_ root: AXUIElement) throws -> [Node] {
        var nodes: [Node] = []
        var stack: [(AXUIElement, Int?)] = [(root, nil)]
        while let (element, parent) = stack.popLast() {
            try checkBudget()
            guard nodes.count < 25_000 else { throw TargetFailure.treeUnavailable }
            AXUIElementSetMessagingTimeout(element, 0.08)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, ["AXRole", "AXChildren"] as CFArray,
                    [], &raw) == .success, let values = raw as? [CFTypeRef], values.count == 2,
                  let role = values[0] as? String, !role.isEmpty else { throw TargetFailure.treeUnavailable }
            var childrenError: AXError?
            if isAXError(values[1]) {
                var error = AXError.failure
                if AXValueGetValue(unsafeBitCast(values[1], to: AXValue.self), .axError, &error) { childrenError = error }
            }
            let children = try ClaudePolicy.treeChildren(values[1] as? [AXUIElement], error: childrenError)
            let index = nodes.count
            nodes.append(Node(element: element, parent: parent, role: role))
            for child in children.reversed() { stack.append((child, index)) }
        }
        return nodes
    }

    private func checkBudget() throws {
        if let deadline = inspectionDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
            throw TargetFailure.treeUnavailable
        }
    }

    private func read(_ element: AXUIElement, _ names: [String]) -> [String: CFTypeRef] {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw) == .success,
              let values = raw as? [CFTypeRef], values.count == names.count else { return [:] }
        var result: [String: CFTypeRef] = [:]
        for (name, value) in zip(names, values) where !isAXError(value) {
            result[name] = value
        }
        return result
    }

    private func isAXError(_ value: CFTypeRef) -> Bool {
        CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(unsafeBitCast(value, to: AXValue.self)) == .axError
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String? { value(element, attribute) as? String }
    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? { value(element, attribute) as? Bool }
    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }
    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        value(element, attribute) as? [AXUIElement]
    }
    private func urlString(_ element: AXUIElement) -> String? {
        guard let raw = value(element, "AXURL") else { return nil }
        if let url = raw as? URL { return url.absoluteString }
        return raw as? String
    }
    private func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CFRange()
        return AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &result) ? result : nil
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, "AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

extension ClaudeLease {
    var composerElement: AXUIElement { composer }
}
