// Run with scripts/test-hotkey-core.sh. No platform APIs are imported or called.
// busyRepeat only acknowledges a pressed chord; it never captures or pastes.
extension Array where Element == HotkeyAction {
    var noEffect: Bool { allSatisfy { if case .busyRepeat = $0 { return true } else { return false } } }
}

@main
enum HotkeyCoreTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }
    static let up = HotkeyKeys()
    static let left = HotkeyKeys(leftOption: true)
    static let both = HotkeyKeys(leftOption: true, rightOption: true)
    static func start(_ core: inout HotkeyCore, at time: Double = 0) -> HotkeyRequest {
        _ = core.observe(up, at: time)
        _ = core.observe(left, at: time + 0.01)
        let actions = core.observe(both, at: time + 0.02)
        guard case .capture(let request) = actions.first else { fatalError("missing capture") }
        return request
    }
    static func deliver(_ core: inout HotkeyCore, _ keys: HotkeyKeys,
                        timestamp: Double, now: Double, cutoff: Double = 0) -> [HotkeyAction] {
        switch HotkeyEventAdmission.evaluate(timestamp: timestamp, now: now, ignoreThrough: cutoff) {
        case .ignore: return []
        case .invalid: return core.reset()
        case .observe(let mayStart): return core.observe(keys, at: now, allowNewCapture: mayStart)
        }
    }

    static func rapidBusyCycles() {
        var core = HotkeyCore(captureTimeout: 45)
        let request = start(&core, at: 40)
        _ = core.observe(up, at: 40.03)
        var actions: [HotkeyAction] = []
        for index in 0..<24 {
            let time = 40.04 + Double(index) * 0.01
            actions += core.observe(left, at: time)
            actions += core.observe(both, at: time + 0.002)
            actions += core.observe(both, at: time + 0.004)
            actions += core.observe(up, at: time + 0.006)
        }
        check(actions == Array(repeating: .busyRepeat(requestID: request.id, phase: "capturing"), count: 24)
              && core.activeRequestID == request.id,
              "rapid busy capture cycles must neither queue nor replace the active request; each full chord is acknowledged once")
        check(core.captureSucceeded(requestID: request.id, imageToken: "rapid", at: 41)
              == [.pasteIntent(request, imageToken: "rapid")],
              "rapid released cycles must still yield exactly the original paste intent")
        for index in 0..<24 {
            let time = 41.01 + Double(index) * 0.01
            actions += core.observe(left, at: time)
            actions += core.observe(both, at: time + 0.002)
            actions += core.observe(up, at: time + 0.004)
            actions += core.tick(at: time + 0.006)
        }
        check(actions.noEffect && core.activeRequestID == request.id,
              "rapid appending cycles must not emit capture or duplicate paste")
        _ = core.observe(both, at: 41.4)
        core.appendFinished(requestID: request.id + 1)
        check(core.isBusy, "foreign completion must not release the active append")
        core.appendFinished(requestID: request.id)
        check(core.observe(both, at: 41.5).noEffect && !core.isBusy,
              "finishing while a busy chord is held must not replay that chord")
        check(core.observe(left, at: 41.6).noEffect && core.observe(both, at: 41.7).noEffect,
              "partial release after busy completion must not rearm")
        check(core.observe(up, at: 41.8).noEffect && core.tick(at: 41.9).noEffect,
              "full release must not drain any busy-capture queue")
        let next = start(&core, at: 42)
        check(next.id == request.id + 1,
              "only the next new physical chord may create the next request ID")
    }

    static func capturedWhileAnotherChordIsHeld() {
        var core = HotkeyCore()
        let request = start(&core, at: 50)
        _ = core.observe(up, at: 50.1)
        check(core.observe(both, at: 50.2).noEffect,
              "a second held chord during capture is consumed")
        check(core.captureSucceeded(requestID: request.id, imageToken: "held", at: 50.3).noEffect,
              "a returned image must wait for the newer physical chord to release")
        check(core.observe(left, at: 50.4).noEffect && core.observe(both, at: 50.5).noEffect,
              "partial release of the newer chord must not authorize paste")
        check(core.observe(HotkeyKeys(ordinaryKey: true), at: 50.6).noEffect && core.isBusy,
              "releasing both Options while another key is down must keep the image pending")
        check(core.observe(up, at: 50.7) == [.pasteIntent(request, imageToken: "held")],
              "all-key release must authorize exactly the original fresh image")
        check(core.tick(at: 50.8).noEffect &&
              core.captureSucceeded(requestID: request.id, imageToken: "duplicate", at: 50.9).noEffect,
              "a held-chord wait must not leave a second pending paste")
    }

    static func cancellationWithBusyChordHeld() {
        var core = HotkeyCore()
        let request = start(&core, at: 60)
        _ = core.observe(up, at: 60.1)
        _ = core.captureSucceeded(requestID: request.id, imageToken: "cancelled", at: 60.2)
        _ = core.observe(both, at: 60.3)
        check(core.reset() == [.rejected(requestID: request.id, .cancelled)],
              "cancelling an append must retire only its active request")
        check(core.observe(both, at: 60.4, allowNewCapture: false).noEffect && !core.isBusy,
              "cleanup HID baseline must not reuse a held busy chord")
        check(core.observe(left, at: 60.5).noEffect && core.observe(both, at: 60.6).noEffect,
              "cancelled busy chord requires complete release")
        check(core.observe(up, at: 60.7, allowNewCapture: false).noEffect && core.tick(at: 60.8).noEffect,
              "cleanup release must only rearm, never schedule an old request")
        check(core.captureSucceeded(requestID: request.id, imageToken: "late", at: 60.9).noEffect,
              "late completion after cancellation cannot resurrect the old image")
        let next = start(&core, at: 61)
        check(next.id == request.id + 1, "a fresh chord after cancellation starts exactly one request")
    }

    // 2026-10-25: a chord pressed again while a request runs is acknowledged once per full chord
    // (busyRepeat with the running request's phase), never queued, never a second paste.
    static func busyRepeats() {
        var core = HotkeyCore(captureTimeout: 45)
        let request = start(&core, at: 70)
        check(core.observe(both, at: 70.05) == [], "the chord still held is not a repeat")
        _ = core.observe(up, at: 70.1)
        _ = core.observe(left, at: 70.2)
        check(core.observe(both, at: 70.3) == [.busyRepeat(requestID: request.id, phase: "capturing")], "repeat while capturing")
        check(core.observe(both, at: 70.35) == [], "one acknowledgement per chord, not per key event")
        check(core.captureSucceeded(requestID: request.id, imageToken: "img", at: 70.4) == [],
              "image ready while the repeat is still held: no paste yet")
        check(core.runningRequest?.phase == "ready", "held keys keep the request ready")
        check(core.observe(up, at: 70.5) == [.pasteIntent(request, imageToken: "img")], "release: the one original paste")
        _ = core.observe(left, at: 70.6)
        check(core.observe(both, at: 70.7) == [.busyRepeat(requestID: request.id, phase: "appending")], "repeat while appending")
        check(core.observe(up, at: 70.8) == [], "no second paste intent after a repeat")
        core.appendFinished(requestID: request.id)
        _ = core.observe(left, at: 70.9)
        guard case .capture(let next)? = core.observe(both, at: 71).first else { fatalError("missing capture") }
        check(next.id != request.id, "after the request finished, a chord starts a new one")
        var blocked = HotkeyCore(captureTimeout: 45)
        _ = blocked.observe(up, at: 0); _ = blocked.observe(left, at: 0.01)
        check(blocked.observe(both, at: 0.02, busyElsewhere: (id: 8, phase: "capturing"))
              == [.busyRepeat(requestID: 8, phase: "capturing")], "the other chord's running request is acknowledged")
        check(!blocked.isBusy, "and no request is started here")
        _ = blocked.observe(up, at: 0.03); _ = blocked.observe(left, at: 0.04)
        check(blocked.observe(both, at: 0.05, allowNewCapture: false) == [], "ignored input is not acknowledged")
    }

    static func main() {
        busyRepeats()
        var core = HotkeyCore()
        check(core.observe(both, at: 0).noEffect, "startup held chord must not fire")
        let first = start(&core, at: 1)
        check(core.observe(both, at: 1.1).noEffect, "held chord repeated")
        check(core.captureSucceeded(requestID: first.id, imageToken: "fresh", at: 1.2).noEffect,
              "must wait for release")
        check(core.observe(left, at: 1.3).noEffect, "one Option still down")
        check(core.observe(both, at: 1.4).noEffect, "one-sided release rearmed")
        check(core.observe(up, at: 1.5) == [.pasteIntent(first, imageToken: "fresh")],
              "release must issue exactly one paste")
        check(core.pasteIsCurrent(requestID: first.id, at: 1.5), "issued paste should be current")
        check(!core.pasteIsCurrent(requestID: first.id + 1, at: 1.5), "wrong paste request")
        check(!core.pasteIsCurrent(requestID: first.id, at: 11.2), "focus delay cannot extend image lifetime")
        check(core.tick(at: 1.6).noEffect, "duplicate paste on timer")
        check(core.captureSucceeded(requestID: first.id, imageToken: "duplicate", at: 1.7).noEffect,
              "duplicate callback must not append")
        _ = core.observe(left, at: 1.8)
        check(core.observe(both, at: 1.9) == [.busyRepeat(requestID: first.id, phase: "appending")],
              "busy chord does not capture; it is only acknowledged (never a second paste)")
        core.appendFinished(requestID: first.id)
        check(!core.pasteIsCurrent(requestID: first.id, at: 2), "finished paste token cannot be reused")
        check(core.observe(both, at: 2).noEffect, "busy chord queued after completion")
        _ = core.observe(up, at: 2.1)
        let second = start(&core, at: 3)
        check(second.id != first.id, "request IDs must be unique")
        _ = core.captureFailed(requestID: second.id, at: 3.1)
        check(core.observe(both, at: 3.2).noEffect, "failure must still require release")

        var dirty = HotkeyCore()
        _ = dirty.observe(up, at: 0)
        _ = dirty.observe(HotkeyKeys(leftOption: true, ordinaryKey: true), at: 0.1)
        _ = dirty.observe(left, at: 0.2)
        check(dirty.observe(both, at: 0.3).noEffect, "Option-letter cycle is contaminated")
        _ = dirty.observe(up, at: 0.4)
        _ = dirty.observe(HotkeyKeys(leftOption: true, rightOption: true, otherModifier: true), at: 0.5)
        check(dirty.observe(both, at: 0.6).noEffect, "Shift release cannot create a chord")
        _ = dirty.observe(up, at: 0.7)
        let d = start(&dirty, at: 1)
        check(dirty.observe(HotkeyKeys(leftOption: true, rightOption: true, ordinaryKey: true), at: 1.1)
              == [.rejected(requestID: d.id, .chordInterrupted)], "typing during first chord must cancel")
        check(dirty.captureSucceeded(requestID: d.id, imageToken: "stale", at: 1.2).noEffect,
              "cancelled capture must not return")

        var busy = HotkeyCore()
        let b = start(&busy)
        _ = busy.observe(up, at: 0.1)
        _ = busy.observe(HotkeyKeys(ordinaryKey: true), at: 0.2)
        check(busy.captureSucceeded(requestID: b.id, imageToken: "fresh", at: 0.3).noEffect,
              "ordinary key held must block paste")
        check(busy.observe(up, at: 0.4) == [.pasteIntent(b, imageToken: "fresh")],
              "all keys released permits pending paste")

        var timed = HotkeyCore(captureTimeout: 2, imageLifetime: 1)
        let t = start(&timed)
        check(timed.captureSucceeded(requestID: t.id + 1, imageToken: "wrong", at: 0.1).noEffect,
              "wrong request callback")
        check(timed.tick(at: 2.02) == [.rejected(requestID: t.id, .captureTimedOut)],
              "capture deadline must fail closed")
        check(timed.captureSucceeded(requestID: t.id, imageToken: "late", at: 2.1).noEffect,
              "late callback accepted")
        _ = timed.observe(up, at: 3)
        let t2 = start(&timed, at: 4)
        _ = timed.captureSucceeded(requestID: t2.id, imageToken: "unreleased", at: 4.1)
        check(timed.observe(up, at: 5.1) == [.rejected(requestID: t2.id, .imageExpired)],
              "expired ready image must not paste on release")
        let t3 = start(&timed, at: 6)
        check(timed.reset() == [.rejected(requestID: t3.id, .cancelled)], "reset must cancel")
        check(timed.observe(both, at: 6.2).noEffect, "reset must require release")
        check(timed.captureSucceeded(requestID: t3.id, imageToken: "old", at: 6.3).noEffect,
              "reset must reject stale callbacks")

        // A synchronous three-second target lookup must not discard the user's
        // queued release or cancel a valid capture. Stale presses never start one.
        var delayed = HotkeyCore(captureTimeout: 45)
        let dr = start(&delayed, at: 10)
        check(deliver(&delayed, left, timestamp: 10.1, now: 13).noEffect,
              "delayed partial release must retain request")
        check(deliver(&delayed, up, timestamp: 10.2, now: 13.01).noEffect && delayed.isBusy,
              "delayed full release must retain request and rearm")
        check(delayed.captureSucceeded(requestID: dr.id, imageToken: "new", at: 14)
              == [.pasteIntent(dr, imageToken: "new")], "delayed release permits one fresh paste")
        check(delayed.tick(at: 14.1).noEffect, "delayed release must not duplicate paste")
        delayed.appendFinished(requestID: dr.id)
        check(deliver(&delayed, both, timestamp: 11, now: 14.2, cutoff: 14.1).noEffect
              && !delayed.isBusy, "completed busy-period chord cannot queue")
        let dr2 = start(&delayed, at: 15)
        check(dr2.id != dr.id, "next physical chord after delayed release works")

        var old = HotkeyCore()
        _ = old.observe(up, at: 1)
        check(deliver(&old, both, timestamp: 1.1, now: 3).noEffect && !old.isBusy,
              "stale idle chord cannot start capture")
        check(deliver(&old, both, timestamp: 3.1, now: 3.1).noEffect,
              "a stale held chord cannot fire when repeated")
        _ = deliver(&old, up, timestamp: 1.2, now: 3.2)
        check(!deliver(&old, both, timestamp: 3.3, now: 3.3).noEffect,
              "stale release rearms without requiring an extra chord")

        var delayedDirty = HotkeyCore()
        let dirtyRequest = start(&delayedDirty, at: 20)
        check(deliver(&delayedDirty, HotkeyKeys(leftOption: true, rightOption: true, ordinaryKey: true),
                      timestamp: 20.1, now: 23) == [.rejected(requestID: dirtyRequest.id, .chordInterrupted)],
              "delayed contamination still cancels original chord")
        check(delayedDirty.captureSucceeded(requestID: dirtyRequest.id, imageToken: "old", at: 23.1).noEffect,
              "contaminated delayed capture cannot complete")

        var expiredBusy = HotkeyCore(captureTimeout: 2)
        let expiredRequest = start(&expiredBusy, at: 30)
        _ = expiredBusy.observe(up, at: 30.1)
        check(deliver(&expiredBusy, both, timestamp: 30.2, now: 33)
              == [.rejected(requestID: expiredRequest.id, .captureTimedOut)] && !expiredBusy.isBusy,
              "stale busy chord cannot create request after expiration in observe")
        check(expiredBusy.observe(both, at: 33.1).noEffect, "expired busy chord stays consumed")

        check(HotkeyEventAdmission.evaluate(timestamp: .nan, now: 10, ignoreThrough: 0) == .invalid,
              "NaN event rejected")
        check(HotkeyEventAdmission.evaluate(timestamp: 11, now: 10, ignoreThrough: 0) == .invalid,
              "future event rejected")
        check(HotkeyEventAdmission.evaluate(timestamp: 0, now: 10, ignoreThrough: 0) == .invalid,
              "zero timestamp rejected")
        check(HotkeyEventAdmission.evaluate(timestamp: 9, now: 10, ignoreThrough: 9) == .ignore,
              "cutoff boundary ignored")
        check(HotkeyEventAdmission.evaluate(timestamp: 9.25, now: 10, ignoreThrough: 0)
              == .observe(allowNewCapture: false), "staleness boundary cannot start")
        rapidBusyCycles()
        capturedWhileAnotherChordIsHeld()
        cancellationWithBusyChordHeld()
        print("HotkeyCore: \(checks) pure checks passed")
    }
}
