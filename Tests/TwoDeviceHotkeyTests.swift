import Foundation

@main
enum TwoDeviceHotkeyTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); count += 1
    }
    static let up = ModifierSnapshot()
    static func chord(_ kind: HotkeyChord) -> ModifierSnapshot {
        kind == .options ? ModifierSnapshot(leftOption: true, rightOption: true) :
            ModifierSnapshot(leftShift: true, rightShift: true)
    }
    static func request(_ actions: [HotkeyAction]) -> HotkeyRequest {
        for case .capture(let r) in actions { return r }
        preconditionFailure("Expected immediate capture")
    }
    static func pastes(_ actions: [HotkeyAction]) -> Int {
        actions.filter { if case .pasteIntent = $0 { return true }; return false }.count
    }
    static func core(dual: Bool) -> DualHotkeyCore {
        var value = DualHotkeyCore(tapSelectionEnabled: true)
        value.hasSecondaryDevice = dual
        _ = value.observe(up, at: 1)
        return value
    }
    static func main() {
        check(DualHotkeyCore.doublePressWindow == 0.500, "500 ms is the shared constant")
        for kind in [HotkeyChord.options, .shifts] {
            // A fast second press may lift only one hand: it still selects the iPhone.
            let oneHand = kind == .options ? ModifierSnapshot(leftOption: true) : ModifierSnapshot(leftShift: true)
            var fast = core(dual: true)
            let first = request(fast.observe(chord(kind), at: 20))
            _ = fast.observe(oneHand, at: 20.05)
            guard case .retarget(let same) = fast.observe(chord(kind), at: 20.1).last else { preconditionFailure("Fast one-hand second press must switch") }
            check(same.id == first.id && fast.selectsSecondary(requestID: first.id), "One-hand second press selects iPhone")
            check(fast.captureSucceeded(requestID: first.id, imageToken: "phone", at: 20.2).isEmpty, "Paste waits for both hands up")
            check(pastes(fast.observe(up, at: 20.3)) == 1, "Publishes once after release")
            var slow = core(dual: true)
            let slowFirst = request(slow.observe(chord(kind), at: 30))
            _ = slow.observe(oneHand, at: 30.6)
            check(slow.observe(chord(kind), at: 30.7).isEmpty && !slow.selectsSecondary(requestID: slowFirst.id), "Outside the window one hand does not count")
            var solo = core(dual: false)
            _ = request(solo.observe(chord(kind), at: 40))
            _ = solo.observe(oneHand, at: 40.05)
            check(solo.observe(chord(kind), at: 40.1).isEmpty, "One paired device keeps full-release rule")
            var detector = CaptureChordDetector()
            _ = detector.observe(up, allow: false)
            let window = DualHotkeyCore.doublePressWindow
            check(detector.observe(chord(kind), allow: true, at: 50, partialReleaseWindow: window) == kind, "Detector fires first press")
            check(detector.observe(chord(kind), allow: true, at: 50.01, partialReleaseWindow: window) == nil, "Holding does not repeat")
            _ = detector.observe(oneHand, allow: true, at: 50.05, partialReleaseWindow: window)
            check(detector.observe(chord(kind), allow: true, at: 50.1, partialReleaseWindow: window) == kind, "Detector fires one-hand second press")
            // A first chord starts immediately; a sub-window result waits only at commit.
            var single = core(dual: true)
            let r = request(single.observe(chord(kind), at: 2))
            check(r.startedAt == 2, "No capture startup timer")
            check(!single.selectsSecondary(requestID: r.id), "First selects iPad")
            _ = single.observe(up, at: 2.01)
            check(single.captureSucceeded(requestID: r.id, imageToken: "pad", at: 2.02).isEmpty, "Fast image cannot publish speculatively")
            check(single.tick(at: 2 + 0.500 - 0.000001).isEmpty, "Before window boundary")
            check(pastes(single.tick(at: 2 + 0.500)) == 1, "At boundary single publishes once")
            check(single.tick(at: 2.7).isEmpty, "Never a second publication")

            for resultReady in [false, true] {
                for gap in [0.001, 0.1, 0.499999] {
                    var double = core(dual: true)
                    let r = request(double.observe(chord(kind), at: 3))
                    _ = double.observe(up, at: 3.0001)
                    if resultReady { _ = double.captureSucceeded(requestID: r.id, imageToken: "discard-pad", at: 3.0002) }
                    let changed = double.observe(chord(kind), at: 3 + gap)
                    guard case .retarget(let same) = changed.last else { preconditionFailure("Must switch within window") }
                    check(same.id == r.id && same.startedAt == r.startedAt, "Same logical request and original chat binding key")
                    check(double.selectsSecondary(requestID: r.id), "Second selects iPhone")
                    check(double.queuedCount == 0, "Second is not a queued picture")
                    check(pastes(changed) == 0, "Old ready result cannot paste on second press")
                    check(double.captureSucceeded(requestID: r.id, imageToken: "phone", at: 3 + gap + 0.001).isEmpty, "Second chord still requires release")
                    let released = double.observe(up, at: 3 + gap + 0.002)
                    check(pastes(released) == 1, "Only iPhone can publish")
                    if case .pasteIntent(_, let image) = released.last { check(image == "phone", "Discarded iPad token replaced") }
                }
            }
            for gap in [0.500, 0.500001, 1.0] {
                var edge = core(dual: true)
                let r = request(edge.observe(chord(kind), at: 4))
                _ = edge.observe(up, at: 4.001)
                let action = edge.observe(chord(kind), at: 4 + gap)
                check(action == [.busyRepeat(requestID: r.id, phase: "capturing")], "At/outside window is next logical press")
                check(edge.queuedCount == 1 && !edge.selectsSecondary(requestID: r.id), "Boundary cannot retarget")
            }
            for completeFirst in [false, true] {
                var one = core(dual: false)
                let r = request(one.observe(chord(kind), at: 5))
                _ = one.observe(up, at: 5.001)
                if completeFirst {
                    check(pastes(one.captureSucceeded(requestID: r.id, imageToken: "only", at: 5.002)) == 1, "One device has zero selection wait")
                    one.appendFinished(requestID: r.id)
                    _ = one.reset(keepQueue: true)
                    _ = one.observe(up, at: 5.003, allowNewCapture: false)
                }
                check(one.observe(chord(kind), at: 5.1).isEmpty, "Single device double is absorbed, even after completed paste")
                check(one.queuedCount == 0, "Single device cannot duplicate in queue")
                check(!one.selectsSecondary(requestID: r.id), "Never pick an unpaired device")
            }
            var held = core(dual: true)
            let heldRequest = request(held.observe(chord(kind), at: 6))
            for time in [6.01, 6.1, 6.2] {
                check(held.observe(chord(kind), at: time).isEmpty, "Held keys are not repeated full chords")
            }
            let partial = kind == .options ? ModifierSnapshot(leftOption: true) : ModifierSnapshot(leftShift: true)
            _ = held.observe(partial, at: 6.61)
            check(held.observe(chord(kind), at: 6.62).isEmpty, "After the window both sides must have been released")
            check(!held.selectsSecondary(requestID: heldRequest.id), "A late partial release cannot choose phone")

            var queued = core(dual: true)
            let other: HotkeyChord = kind == .options ? .shifts : .options
            let active = request(queued.observe(chord(other), at: 7))
            _ = queued.observe(up, at: 7.01)
            _ = queued.observe(chord(kind), at: 7.02)
            _ = queued.observe(up, at: 7.03)
            check(queued.observe(chord(kind), at: 7.1) == [.retargetQueued(pressedAt: 7.02)], "Double queued press changes its own device")
            check(queued.queuedCount == 1, "Queued double stays one operation")
            check(!queued.selectsSecondary(requestID: active.id), "Other chord's running operation unchanged")
            check(queued.discardUncapturedQueuedPresses(after: "timeout", secondaryDevice: false) == 0,
                  "Offline iPad must not erase a queued iPhone capture")
            _ = queued.observe(up, at: 7.11)
            _ = queued.captureSucceeded(requestID: active.id, imageToken: "first", at: 7.4)
            queued.appendFinished(requestID: active.id)
            _ = queued.reset(keepQueue: true)
            let next = request(queued.startQueued(at: 7.5))
            check(next.startedAt == 7.02 && queued.selectsSecondary(requestID: next.id), "Queued first press destination and phone selection survive cleanup")

            var cancelled = core(dual: true)
            _ = request(cancelled.observe(chord(kind), at: 8))
            _ = cancelled.reset()
            _ = cancelled.observe(up, at: 8.01)
            let fresh = request(cancelled.observe(chord(kind), at: 8.1))
            check(!cancelled.selectsSecondary(requestID: fresh.id), "Cancel clears gesture")
        }
        print("Two-device hotkeys: \(count) checks passed.")
    }
}
