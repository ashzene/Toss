import AppKit

// One transaction drives exactly one target app, chosen by the chord that
// started it: both Options → ChatGPT/Codex, both Shifts → Claude. A lease is
// only ever handed back to the target that issued it.

protocol ChatLease {
    var pid: pid_t { get }
    var isNewDraft: Bool { get }
    // Read-only, for the early attachment sighting (AttachmentSighting); never written to.
    var composerElement: AXUIElement { get }
    // Same app process, same window and same chat (Codex: sidebar/route/new-draft identity;
    // Claude: exact document URL). The composer object is not compared: the app may rebuild
    // it after a paste. Used for a queued press, bound to the chat it was pressed in.
    func sameDestination(as other: any ChatLease) -> Bool
}

extension TargetLease: ChatLease {}

enum TargetKind: String {
    case chatGPT = "chatgpt"
    case claude = "claude"

    var bundleID: String {
        switch self {
        // Same literals as StrictTarget.bundleID / ClaudeTarget.bundleID.
        case .chatGPT: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        }
    }

    var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT／Codex"
        case .claude: return "Claude"
        }
    }

    static func forBundleID(_ bundleID: String?) -> TargetKind? {
        [.chatGPT, .claude].first { $0.bundleID == bundleID }
    }
}

@MainActor
protocol ChatTarget: AnyObject {
    var diagnosticSummary: String { get }
    var accessibilityPreparationSummary: String { get }
    var latestAttachmentGeometryStatus: String { get }
    var latestConfirmedAttachmentFrame: CGRect? { get }
    var latestPasteConsumptionConfirmed: Bool { get }
    var latestPasteConsumptionFilename: String? { get }
    func prepareAccessibility() async throws
    func locateLease() throws -> any ChatLease
    func revalidateLease(_ lease: any ChatLease, requireFocused: Bool) throws
    func focusLease(_ lease: any ChatLease) async throws
    func verifyAppendLease(_ lease: any ChatLease, expectedFilename: String) throws -> AppendReadback
    // Queued press, its chat switched away (back to where it was). Raise the lease's own window
    // (the app is already in front), or press that exact chat's sidebar item / link once. Neither
    // pastes nor decides anything: the caller locates again and compares with the lease.
    func raiseLeaseWindow(_ lease: any ChatLease) async throws
    func openLeaseConversation(_ lease: any ChatLease) throws
}

extension StrictTarget: ChatTarget {
    func locateLease() throws -> any ChatLease { try locate() }
    func revalidateLease(_ lease: any ChatLease, requireFocused: Bool) throws {
        guard let lease = lease as? TargetLease else { throw TargetFailure.targetChanged }
        try revalidate(lease, requireFocused: requireFocused)
    }
    func focusLease(_ lease: any ChatLease) async throws {
        guard let lease = lease as? TargetLease else { throw TargetFailure.targetChanged }
        try await focus(lease)
    }
    func verifyAppendLease(_ lease: any ChatLease, expectedFilename: String) throws -> AppendReadback {
        guard let lease = lease as? TargetLease else { throw TargetFailure.targetChanged }
        return try verifyAppend(lease, expectedFilename: expectedFilename)
    }
    func raiseLeaseWindow(_ lease: any ChatLease) async throws {
        guard let lease = lease as? TargetLease else { throw TargetFailure.targetChanged }
        try await raiseWindow(lease)
    }
    func openLeaseConversation(_ lease: any ChatLease) throws {
        guard let lease = lease as? TargetLease else { throw TargetFailure.targetChanged }
        try openConversation(lease)
    }
}

extension ClaudeTarget: ChatTarget {
    func locateLease() throws -> any ChatLease { try locate() }
    func revalidateLease(_ lease: any ChatLease, requireFocused: Bool) throws {
        guard let lease = lease as? ClaudeLease else { throw TargetFailure.targetChanged }
        try revalidate(lease, requireFocused: requireFocused)
    }
    func focusLease(_ lease: any ChatLease) async throws {
        guard let lease = lease as? ClaudeLease else { throw TargetFailure.targetChanged }
        try await focus(lease)
    }
    func verifyAppendLease(_ lease: any ChatLease, expectedFilename: String) throws -> AppendReadback {
        guard let lease = lease as? ClaudeLease else { throw TargetFailure.targetChanged }
        return try verifyAppend(lease, expectedFilename: expectedFilename)
    }
    func raiseLeaseWindow(_ lease: any ChatLease) async throws {
        guard let lease = lease as? ClaudeLease else { throw TargetFailure.targetChanged }
        try await raiseWindow(lease)
    }
    func openLeaseConversation(_ lease: any ChatLease) throws {
        guard let lease = lease as? ClaudeLease else { throw TargetFailure.targetChanged }
        try openConversation(lease)
    }
}


// After Cmd+V on a new draft (2026-10-25): the user's own input while Toss waits for the
// readback (a key, click or scroll right after the toss) used to void a paste that had
// verifiably landed, so there was no sound, ✓ or jelly although the picture was there. When the
// readback confirms our exact file in the leased composer, that input no longer matters. It
// still voids an unconfirmed result, and a draft whose watch could not be set up is never trusted.
enum AppendConfirmationPolicy {
    static func acceptsConfirmed(isNewDraft: Bool, observing: Bool, intervened: Bool) -> Bool {
        !isNewDraft || observing
    }
    static func interruptsUnconfirmed(intervened: Bool) -> Bool { intervened }
}
