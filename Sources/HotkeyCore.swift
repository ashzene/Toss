import Foundation

// Pure state only. The platform adapter must pass every keyboard event through,
// provide complete key snapshots and monotonic seconds, and validate the target
// again before acting on pasteIntent. No UI, clipboard or event injection here.
struct HotkeyKeys: Equatable {
    var leftOption = false
    var rightOption = false
    var otherModifier = false
    var ordinaryKey = false

    var optionsReleased: Bool { !leftOption && !rightOption }
    var allReleased: Bool { optionsReleased && !otherModifier && !ordinaryKey }
    var contaminated: Bool { otherModifier || ordinaryKey }
}

struct HotkeyRequest: Equatable {
    let id: UInt64
    let startedAt: Double
    let deadlineAt: Double
}

enum HotkeyEventAdmission: Equatable {
    case ignore
    case invalid
    case observe(allowNewCapture: Bool)

    static func evaluate(timestamp: Double, now: Double, ignoreThrough: Double) -> Self {
        guard timestamp.isFinite, now.isFinite, timestamp > 0, timestamp <= now else {
            return .invalid
        }
        guard timestamp > ignoreThrough else { return .ignore }
        // AX work can delay release events on the main actor. Preserve those
        // snapshots, but never start a request from a delayed press.
        return .observe(allowNewCapture: now - timestamp < 0.75)
    }
}

enum HotkeyRejection: Equatable {
    case captureFailed
    case captureTimedOut
    case imageExpired
    case chordInterrupted
    case cancelled
}

enum HotkeyAction: Equatable {
    case capture(HotkeyRequest)
    // This is an abstract, once-only authorization, not proof of an attachment.
    case pasteIntent(HotkeyRequest, imageToken: String)
    case rejected(requestID: UInt64, HotkeyRejection)
    // A full chord while a request is still running (2026-10-25): never queued, never a second
    // paste; the adapter only acknowledges it (menu-bar nudge) and logs it. phase: capturing,
    // ready or appending of the running request.
    case busyRepeat(requestID: UInt64, phase: String)
}

struct HotkeyCore {
    private struct Ready {
        let request: HotkeyRequest
        let imageToken: String
        let expiresAt: Double
    }
    private enum Phase {
        case idle
        case capturing(HotkeyRequest)
        case ready(Ready)
        case appending(HotkeyRequest, expiresAt: Double)
    }

    let captureTimeout: Double
    let imageLifetime: Double
    private var phase: Phase = .idle
    private var keys = HotkeyKeys()
    private var nextID: UInt64
    private let idStride: UInt64
    // Starting while keys are held cannot create a request.
    private var armed = false
    private var cycleDirty = false
    private var cycleFired = false
    private var cycleOwnsRequest = false
    private var originalChordReleased = false

    init(captureTimeout: Double = 15, imageLifetime: Double = 10, firstID: UInt64 = 1, idStride: UInt64 = 1) {
        precondition(captureTimeout > 0 && captureTimeout.isFinite)
        precondition(imageLifetime > 0 && imageLifetime.isFinite)
        precondition(firstID > 0 && idStride > 0)
        self.captureTimeout = captureTimeout
        self.imageLifetime = imageLifetime
        self.nextID = firstID
        self.idStride = idStride
    }

    var isBusy: Bool {
        if case .idle = phase { return false }
        return true
    }

    var activeRequestID: UInt64? {
        switch phase {
        case .idle: return nil
        case .capturing(let r), .appending(let r, _): return r.id
        case .ready(let r): return r.request.id
        }
    }

    // Call for relevant key-down, key-up and modifier changes. Return values
    // never instruct the adapter to suppress the original event.
    // The running request and its phase, for busyRepeat.
    var runningRequest: (id: UInt64, phase: String)? {
        switch phase {
        case .idle: return nil
        case .capturing(let r): return (r.id, "capturing")
        case .ready(let r): return (r.request.id, "ready")
        case .appending(let r, _): return (r.id, "appending")
        }
    }

    // busyElsewhere: the other chord's running request (Dual core); blocks a new capture here.
    mutating func observe(_ snapshot: HotkeyKeys, at now: Double,
                          allowNewCapture: Bool = true,
                          busyElsewhere: (id: UInt64, phase: String)? = nil) -> [HotkeyAction] {
        keys = snapshot
        var actions = expire(at: now)
        if keys.optionsReleased {
            if cycleOwnsRequest { originalChordReleased = true }
            cycleOwnsRequest = false
            cycleFired = false
            cycleDirty = false
            armed = true
            actions += issuePasteIfReady(at: now)
            return actions
        }
        guard armed else { return actions }
        cycleDirty = cycleDirty || keys.contaminated
        if cycleDirty {
            if cycleOwnsRequest {
                actions += cancel(reason: .chordInterrupted)
                cycleOwnsRequest = false
            }
            return actions
        }
        if keys.leftOption && keys.rightOption && !cycleFired {
            cycleFired = true // Busy chords are consumed, never queued.
            guard allowNewCapture, !isBusy, busyElsewhere == nil else {
                if allowNewCapture, let running = runningRequest ?? busyElsewhere {
                    actions.append(.busyRepeat(requestID: running.id, phase: running.phase))
                }
                return actions
            }
            let request = HotkeyRequest(id: nextID, startedAt: now,
                                        deadlineAt: now + captureTimeout)
            nextID += idStride
            originalChordReleased = false
            cycleOwnsRequest = true
            phase = .capturing(request)
            actions.append(.capture(request))
        }
        return actions
    }

    mutating func captureSucceeded(requestID: UInt64, imageToken: String,
                                   at now: Double) -> [HotkeyAction] {
        let expiry = expire(at: now)
        guard case .capturing(let request) = phase,
              request.id == requestID else { return expiry }
        guard !imageToken.isEmpty else {
            return expiry + cancel(reason: .captureFailed)
        }
        phase = .ready(Ready(request: request, imageToken: imageToken,
                             expiresAt: now + imageLifetime))
        return expiry + issuePasteIfReady(at: now)
    }

    mutating func captureFailed(requestID: UInt64, at now: Double) -> [HotkeyAction] {
        let expiry = expire(at: now)
        guard case .capturing(let request) = phase,
              request.id == requestID else { return expiry }
        return expiry + cancel(reason: .captureFailed)
    }

    // Completion only releases the busy state. Never retries an uncertain paste.
    mutating func appendFinished(requestID: UInt64) {
        guard case .appending(let request, _) = phase,
              request.id == requestID else { return }
        phase = .idle
    }

    // The adapter may await focus/target checks after receiving pasteIntent.
    // Recheck immediately before the external effect; never let that delay turn
    // a formerly fresh image into an indefinitely valid authorization.
    func pasteIsCurrent(requestID: UInt64, at now: Double) -> Bool {
        guard case .appending(let request, let expiresAt) = phase else { return false }
        return request.id == requestID && now.isFinite && now < expiresAt
    }

    mutating func tick(at now: Double) -> [HotkeyAction] {
        expire(at: now) + issuePasteIfReady(at: now)
    }

    // A chord pressed while another request ran (DualHotkeyCore's queue). Its keys were
    // released long ago, so it may paste as soon as its image is ready; a later physical
    // cycle can neither interrupt nor re-fire it.
    // pressedAt: when the chord was pressed. The screenshot may be taken from then on (a queued
    // press's picture is fetched while the previous toss is still pasting), so receipts are
    // checked against the press, not against the moment its turn came.
    mutating func startQueued(at now: Double, pressedAt: Double? = nil) -> [HotkeyAction] {
        guard !isBusy else { return [] }
        let request = HotkeyRequest(id: nextID, startedAt: min(now, pressedAt ?? now), deadlineAt: now + captureTimeout)
        nextID += idStride
        originalChordReleased = true
        cycleOwnsRequest = false
        phase = .capturing(request)
        return [.capture(request)]
    }

    // Use when device disconnects, key monitoring is lost, or target is invalid.
    // A fresh all-Option-released snapshot is required before another capture.
    mutating func reset() -> [HotkeyAction] {
        let actions = cancel(reason: .cancelled)
        armed = false
        cycleDirty = false
        cycleFired = false
        cycleOwnsRequest = false
        originalChordReleased = false
        return actions
    }

    private mutating func cancel(reason: HotkeyRejection) -> [HotkeyAction] {
        guard let id = activeRequestID else { return [] }
        phase = .idle
        return [.rejected(requestID: id, reason)]
    }

    private mutating func expire(at now: Double) -> [HotkeyAction] {
        switch phase {
        case .capturing(let r) where now >= r.deadlineAt:
            return cancel(reason: .captureTimedOut)
        case .ready(let r) where now >= r.expiresAt:
            return cancel(reason: .imageExpired)
        default:
            return []
        }
    }

    private mutating func issuePasteIfReady(at now: Double) -> [HotkeyAction] {
        guard keys.allReleased, originalChordReleased,
              case .ready(let ready) = phase, now < ready.expiresAt else { return [] }
        phase = .appending(ready.request, expiresAt: ready.expiresAt) // Advance before exposing the effect.
        return [.pasteIntent(ready.request, imageToken: ready.imageToken)]
    }
}

// Complete modifier snapshot. Device-specific masks distinguish left/right.
struct ModifierSnapshot: Equatable {
    var leftOption = false
    var rightOption = false
    var leftShift = false
    var rightShift = false
    var control = false
    var command = false
    var function = false
    var ordinaryKey = false

    // Both Options: Shift/Control/Command/Fn are contamination.
    var optionChord: HotkeyKeys {
        HotkeyKeys(leftOption: leftOption, rightOption: rightOption,
                   otherModifier: leftShift || rightShift || control || command || function,
                   ordinaryKey: ordinaryKey)
    }

    // Both Shifts, mapped onto the same two-key state machine. Option, Control,
    // Command and Fn are contamination, so a four-key press starts nothing.
    var shiftChord: HotkeyKeys {
        HotkeyKeys(leftOption: leftShift, rightOption: rightShift,
                   otherModifier: leftOption || rightOption || control || command || function,
                   ordinaryKey: ordinaryKey)
    }

    var allReleased: Bool { optionChord.allReleased }
}

// Receipt routing shared by the AppKit adapter and the synthetic callback tests.
// declaredSuccess is only protocol classification; CaptureReceipt still validates the image.
enum CaptureCompletionPolicy {
    enum Receipt: Equatable {
        case declaredSuccess
        case failure(String)
        case invalid
    }

    static func classify(_ data: Data, exitCode: Int32, requestID: String) -> Receipt {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema_version"] as? Int == 1,
              object["request_id"] as? String == requestID,
              let ok = object["ok"] as? Bool,
              let reason = object["reason"] as? String,
              reason.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil else { return .invalid }
        if ok && exitCode == 0 && reason == "captured" { return .declaredSuccess }
        if !ok && exitCode != 0 { return .failure(reason) }
        return .invalid
    }

    static func failureBeforeTarget(_ receipt: Receipt, activeRequestMatches: Bool,
                                    transactionExists: Bool) -> String? {
        guard activeRequestMatches, !transactionExists, case .failure(let reason) = receipt else { return nil }
        return reason
    }

    static func canAdoptPrefetch(_ receipt: Receipt?, arrivedAge: Double?, workerOwnsRequest: Bool) -> Bool {
        guard receipt != nil || workerOwnsRequest else { return false }
        // A failed RPC is already over. Waiting for the preceding paste must never turn
        // its result into another request, even after the usual screenshot freshness limit.
        if case .failure = receipt { return true }
        return arrivedAge == nil || arrivedAge! <= 3
    }
}

// A failed link affects the requests waiting behind it. A rejected image does not:
// black/invalid frames still belong only to the individual screenshot.
enum CaptureQueueFailurePolicy {
    static let sharedReasons: Set<String> = [
        "no_authenticated_remote_wifi_connection", "network_unavailable", "disconnected",
        "lan_interface_not_identified", "service_unavailable",
        "developer_image_unavailable", "exact_pinned_usb_device_required",
        "unexpected_device_pin", "rsd_device_identity_mismatch", "pairing_state_missing", "pairing_state_not_private",
        "strict_remote_pairing_record_mismatch", "strict_remote_pairing_record_incomplete",
        "remote_pairing_record_not_private", "remote_pair_verify_rejected", "remote_pair_verify_m4_rejected",
        "remote_peer_signature_not_verified", "remote_peer_identifier_mismatch",
        "initial_usb_remote_pairing_required", "private_existing_state_directory_required"
    ]
    static func affectsQueuedPresses(_ reason: String) -> Bool { sharedReasons.contains(reason) }
}

// When the second capture route fails, retry the press on the first route instead of failing it,
// unless the failure is a timeout (the route was working, just slow) or a real result about the frame.
enum ParallelCaptureFallbackPolicy {
    static let keepsFailure: Set<String> = [
        "timeout", "first_byte_timeout", "stall_timeout", "too_slow", "slow_threshold",
        "black_frame_rejected", "invalid_png", "unexpected_dimensions", "frame_too_large", "empty_frame",
        "cancelled"
    ]
    static func retryOnFirstRoute(slot: Int, reason: String?) -> Bool {
        guard slot != 0, let reason else { return false }
        return !keepsFailure.contains(reason)
    }
}

enum HotkeyChord: Equatable { case options, shifts }

// Where a queued press pastes (2026-10-28: in the chat where it was pressed, never a wrong one). Pure rules;
// the adapter supplies the facts. A bound press pastes only into the chat it was bound to; otherwise
// (option b) its picture stays on the clipboard with the manual-paste notice. Unbound presses use
// their app's current chat when their turn comes, as in v21.1.
enum QueuedDestinationPolicy {
    // Bound to the chat this app's presses already go to in the current burst (the running toss's
    // chat for the same app, else the burst's earlier chat for it). Input in OTHER apps (2026-10-28
    // 13:29: clicking another app while pressing) never voids it; only input that went
    // into that chat app itself may have changed the chat.
    static func binds(sourceAvailable: Bool, watchObserving: Bool, inputInTargetApp: Bool) -> Bool {
        sourceAvailable && watchObserving && !inputInTargetApp
    }
    // Bringing the chat back after the user clicked away: a few tries, then manual paste (never a fight).
    static let refocusAttempts = 3
    static let foregroundRetriesBeforePaste = 2
    enum Outcome: Equatable { case paste, manualPaste }
    static func outcome(bound: Bool, sameDestination: Bool) -> Outcome {
        !bound || sameDestination ? .paste : .manualPaste
    }
    // Back to the bound chat (back where it was, not a new page). isBound() locates the current
    // chat and compares it with the binding. Nothing is clicked while it already matches; the window
    // is raised before any sidebar item is pressed; the item is pressed at most once and the result
    // verified. false: not provably back (gone, deleted, ambiguous) → manual paste, never elsewhere.
    static func restore(isBound: () async throws -> Bool, raiseWindow: () async throws -> Void,
                        openConversation: () throws -> Void, pause: () async throws -> Void,
                        settleChecks: Int = 12) async throws -> Bool {
        func check() async throws -> Bool {
            do { return try await isBound() } catch is CancellationError { throw CancellationError() } catch { return false }
        }
        if try await check() { return true }
        do { try await raiseWindow() } catch is CancellationError { throw CancellationError() } catch { return false }
        if try await check() { return true }
        do { try openConversation() } catch { return false }
        for _ in 0..<settleChecks {
            try await pause()
            if try await check() { return true }
        }
        return false
    }

    // A queued press may meet the previous paste's short-lived dialog layer: more locate attempts.
    static func locateAttempts(queued: Bool) -> Int { queued ? 10 : 4 }
}

// Two independent chord machines sharing one transaction slot. Option requests
// get odd IDs, Shift requests even IDs, so every later callback routes by ID.
// While either machine is busy, the other cannot start a capture.
struct DualHotkeyCore {
    private var options: HotkeyCore
    private var shifts: HotkeyCore

    init(captureTimeout: Double = 15, imageLifetime: Double = 10) {
        options = HotkeyCore(captureTimeout: captureTimeout, imageLifetime: imageLifetime, firstID: 1, idStride: 2)
        shifts = HotkeyCore(captureTimeout: captureTimeout, imageLifetime: imageLifetime, firstID: 2, idStride: 2)
    }

    static func chord(of requestID: UInt64) -> HotkeyChord { requestID % 2 == 1 ? .options : .shifts }

    var isBusy: Bool { options.isBusy || shifts.isBusy }
    var activeRequestID: UInt64? { options.activeRequestID ?? shifts.activeRequestID }

    // Chords pressed while a request is running (2026-10-28: the next one may start
    // before the last has pasted). Each still reports busyRepeat for the menu-bar nudge, and is also kept here in
    // order; the adapter starts the oldest with startQueued once the slot is free. A press older
    // than queueLifetime is dropped rather than pasted long after the user moved on.
    static let queueLimit = 3
    static let queueLifetime: Double = 20
    private(set) var queue: [(chord: HotkeyChord, at: Double)] = []
    var queuedCount: Int { queue.count }
    var nextQueuedPress: (chord: HotkeyChord, at: Double)? { queue.first }

    mutating func observe(_ snapshot: ModifierSnapshot, at now: Double,
                          allowNewCapture: Bool = true) -> [HotkeyAction] {
        let fromOptions = options.observe(snapshot.optionChord, at: now,
                                          allowNewCapture: allowNewCapture, busyElsewhere: shifts.runningRequest)
        let fromShifts = shifts.observe(snapshot.shiftChord, at: now,
                                        allowNewCapture: allowNewCapture, busyElsewhere: options.runningRequest)
        for (chord, actions) in [(HotkeyChord.options, fromOptions), (.shifts, fromShifts)] {
            let pressedWhileBusy = actions.contains { if case .busyRepeat = $0 { return true }; return false }
            if pressedWhileBusy, queue.count < Self.queueLimit { queue.append((chord, now)) }
        }
        return fromOptions + fromShifts
    }

    mutating func startQueued(at now: Double) -> [HotkeyAction] {
        queue.removeAll { now - $0.at > Self.queueLifetime || now < $0.at }
        guard !isBusy, !queue.isEmpty else { return [] }
        let next = queue.removeFirst()
        switch next.chord {
        case .options: return options.startQueued(at: now, pressedAt: next.at)
        case .shifts: return shifts.startQueued(at: now, pressedAt: next.at)
        }
    }

    mutating func beginDelivery(chord: HotkeyChord, pressedAt: Double, at now: Double) -> [HotkeyAction] {
        guard !isBusy else { return [] }
        switch chord {
        case .options: return options.startQueued(at: now, pressedAt: pressedAt)
        case .shifts: return shifts.startQueued(at: now, pressedAt: pressedAt)
        }
    }

    // Silent removal: only the failing request produces an error/result. The adapter may
    // preserve a validated screenshot, or a completed failed prefetch whose single result
    // still has to be presented after the preceding paste finishes. Neither starts a new RPC.
    @discardableResult
    mutating func discardUncapturedQueuedPresses(after reason: String,
                                               capturedAt: Double? = nil,
                                               reportingFailureAt: Double? = nil) -> Int {
        guard CaptureQueueFailurePolicy.affectsQueuedPresses(reason) else { return 0 }
        let previous = queue.count
        queue.removeAll { $0.at != capturedAt && $0.at != reportingFailureAt }
        return previous - queue.count
    }

    mutating func captureSucceeded(requestID: UInt64, imageToken: String, at now: Double) -> [HotkeyAction] {
        switch Self.chord(of: requestID) {
        case .options: return options.captureSucceeded(requestID: requestID, imageToken: imageToken, at: now)
        case .shifts: return shifts.captureSucceeded(requestID: requestID, imageToken: imageToken, at: now)
        }
    }

    mutating func captureFailed(requestID: UInt64, at now: Double) -> [HotkeyAction] {
        switch Self.chord(of: requestID) {
        case .options: return options.captureFailed(requestID: requestID, at: now)
        case .shifts: return shifts.captureFailed(requestID: requestID, at: now)
        }
    }

    mutating func appendFinished(requestID: UInt64) {
        switch Self.chord(of: requestID) {
        case .options: options.appendFinished(requestID: requestID)
        case .shifts: shifts.appendFinished(requestID: requestID)
        }
    }

    func pasteIsCurrent(requestID: UInt64, at now: Double) -> Bool {
        switch Self.chord(of: requestID) {
        case .options: return options.pasteIsCurrent(requestID: requestID, at: now)
        case .shifts: return shifts.pasteIsCurrent(requestID: requestID, at: now)
        }
    }

    mutating func tick(at now: Double) -> [HotkeyAction] {
        options.tick(at: now) + shifts.tick(at: now)
    }

    // keepQueue: the end of one request (its own cleanup reset) keeps the presses waiting
    // behind it; disabling, lost key monitoring or invalid timing clears them.
    mutating func reset(keepQueue: Bool = false) -> [HotkeyAction] {
        if !keepQueue { queue.removeAll() }
        return options.reset() + shifts.reset()
    }
}

// One device link has one transfer owner. Targeting/paste may overlap that transfer;
// further presses retain their identity and destination while waiting for the link.
struct CapturePipeline {
    struct Press: Equatable {
        let id: UInt64
        let chord: HotkeyChord
        let at: Double
        let queued: Bool
    }
    // The app uses one shared route. The two-slot mode only retains the legacy
    // standby-failure recovery model for callers with independent links.
    let transferLimit: Int
    init(transferLimit: Int = 1) { self.transferLimit = min(2, max(1, transferLimit)) }
    private var nextID: UInt64 = 1
    private(set) var waiting: [Press] = []
    private(set) var running: [Int: Press] = [:]
    private(set) var ready: [Press] = []
    private(set) var delivering: Press?
    // Set after the second route failed for a non-timeout reason: real two-way capture is unproven on
    // devices (2026-11-03), so from then on only the first route captures, one at a time.
    private(set) var parallelPaused = false
    var isBusy: Bool { !waiting.isEmpty || !running.isEmpty || !ready.isEmpty || delivering != nil }
    var waitingCount: Int { waiting.count }

    mutating func admit(_ chord: HotkeyChord, at: Double) -> Press? {
        guard at.isFinite, waiting.count < 4 - transferLimit,
              waiting.count + running.count + ready.count < 4 else { return nil }
        let press = Press(id: nextID, chord: chord, at: at, queued: isBusy)
        nextID += 1
        waiting.append(press)
        return press
    }
    mutating func startAvailable() -> [(slot: Int, press: Press)] {
        var starts: [(Int, Press)] = []
        for slot in 0..<(parallelPaused ? 1 : transferLimit) where running[slot] == nil && !waiting.isEmpty {
            let press = waiting.removeFirst()
            running[slot] = press
            starts.append((slot, press))
        }
        return starts
    }
    @discardableResult mutating func completed(_ id: UInt64, slot: Int) -> Bool {
        guard let press = running[slot], press.id == id else { return false }
        running.removeValue(forKey: slot)
        if delivering?.id != id { ready.append(press) }
        return true
    }
    // The second route could not take this press (device busy or service error): it is not a failure.
    // Put it back at the head of the queue and wait for the first route.
    @discardableResult mutating func deferredToFirstRoute(_ id: UInt64, slot: Int) -> Bool {
        guard slot != 0, let press = running[slot], press.id == id else { return false }
        running.removeValue(forKey: slot)
        waiting.insert(press, at: 0)
        parallelPaused = true
        return true
    }
    mutating func takeReady() -> Press? {
        guard delivering == nil, !ready.isEmpty else { return nil }
        delivering = ready.removeFirst()
        return delivering
    }
    // Reserve the next UI transaction before its screenshot returns. Completion
    // stays with that reservation, so the same frame is never delivered twice.
    mutating func takeForTargeting() -> Press? {
        if let ready = takeReady() { return ready }
        guard delivering == nil, let press = running.values.min(by: { $0.at < $1.at }) else { return nil }
        delivering = press
        return press
    }
    static func bindingMissing(queued: Bool, hasBinding: Bool) -> Bool { queued && !hasBinding }
    mutating func deliveryFinished() { delivering = nil }
    mutating func disconnected() -> [Press] {
        let discarded = waiting
        waiting.removeAll()
        return discarded
    }
    mutating func reset() { waiting.removeAll(); running.removeAll(); ready.removeAll(); delivering = nil; parallelPaused = false }
}

struct CaptureChordDetector {
    private struct Cycle {
        var armed = false, dirty = false, fired = false
        mutating func observe(_ keys: HotkeyKeys, allow: Bool) -> Bool {
            if keys.optionsReleased { armed = true; dirty = false; fired = false; return false }
            guard armed else { return false }
            dirty = dirty || keys.contaminated
            guard !dirty, !fired, keys.leftOption, keys.rightOption else { return false }
            fired = true
            return allow
        }
    }
    private var options = Cycle(), shifts = Cycle()
    mutating func observe(_ keys: ModifierSnapshot, allow: Bool) -> HotkeyChord? {
        let option = options.observe(keys.optionChord, allow: allow)
        let shift = shifts.observe(keys.shiftChord, allow: allow)
        return option ? .options : shift ? .shifts : nil
    }
}

// A verified completed frame survives delivery-time key/draft/age failures.
// Explicit cancellation and a posted paste must never cause another delivery.
enum CapturedImageRecoveryPolicy {
    static func preserve(validated: Bool, pastePosted: Bool, explicitlyCancelled: Bool) -> Bool {
        validated && !pastePosted && !explicitlyCancelled
    }
}
