import Foundation

@main
struct DeviceCapturePipelineTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); checks += 1
    }
    static func main() {
        var drop = USBDropNotice()
        check(!drop.shouldShow(.iPhone, externalConnected: false, usbBack: false, at: 1), "really unplugged: no notice")
        check(!drop.shouldShow(.iPhone, externalConnected: nil, usbBack: false, at: 1), "unknown power: no notice")
        check(!drop.shouldShow(.iPhone, externalConnected: true, usbBack: true, at: 1), "USB came back: no notice")
        check(drop.shouldShow(.iPhone, externalConnected: true, usbBack: false, at: 1), "still powered: notice")
        check(!drop.shouldShow(.iPhone, externalConnected: true, usbBack: false, at: 500), "quiet for ten minutes")
        check(drop.shouldShow(.iPad, externalConnected: true, usbBack: false, at: 500), "each device has its own quiet time")
        check(drop.shouldShow(.iPhone, externalConnected: true, usbBack: false, at: 601), "notice again after ten minutes")
        let both: Set<DeviceClass> = [.iPad, .iPhone]
        for wanted in DeviceClass.allCases {
            var routing = DevicePressRouting()
            let other = wanted.other
            func selected(closed: Set<DeviceClass> = [], ready: Set<DeviceClass>, at now: Double) -> DeviceClass {
                routing.device(wanted: wanted, paired: both, closed: closed, ready: ready, at: now)
            }
            check(selected(ready: both, at: 10) == wanted, "both open or unknown: the keys decide")
            check(selected(closed: both, ready: both, at: 10) == wanted, "both closed: the keys decide")
            check(selected(closed: [other], ready: both, at: 10) == wanted, "chosen device is open")
            check(selected(closed: [wanted], ready: [other], at: 10) == other, "known lock switches immediately")
            check(selected(closed: [wanted], ready: [wanted], at: 10) == wanted, "an offline sibling cannot take a press")
            check(selected(ready: [other], at: 10) == wanted, "an unchecked device keeps its shortcut")
            routing.observe(wanted, unavailable: true, at: 10)
            check(selected(ready: [other], at: 15.999) == wanted, "allow a short reconnect")
            routing.observe(wanted, unavailable: true, at: 15.5)
            check(selected(ready: [other], at: 16) == other, "new reconnect attempts do not extend the grace period")
            check(selected(closed: [other], ready: [other], at: 16) == wanted, "a locked sibling cannot take a press")
            check(routing.lockedAlternate(for: wanted, paired: both, closed: [other], ready: [other], at: 16) == other,
                  "report the lock on the only connected device")
            check(routing.lockedAlternate(for: wanted, paired: both, closed: [other], ready: [other], at: 15.9) == nil,
                  "give a reconnect its grace period")
            check(routing.lockedAlternate(for: wanted, paired: both, closed: [other], ready: both, at: 16) == nil,
                  "a connected device's failure is its own")
            check(routing.lockedAlternate(for: wanted, paired: both, closed: [other], ready: [], at: 16) == nil,
                  "an offline alternate's old lock reading does not explain this failure")
            check(routing.lockedAlternate(for: wanted, paired: both, closed: [], ready: [other], at: 16) == nil,
                  "an unknown or unlocked alternate gets no unlock hint")
            check(selected(ready: [], at: 16) == wanted, "both offline: the keys decide")
            check(routing.device(wanted: wanted, paired: [wanted], closed: [], ready: [other], at: 16) == wanted,
                  "an unpaired device never takes a press")
            routing.observe(wanted, unavailable: false, at: 17)
            check(selected(ready: both, at: 17) == wanted, "reconnected device takes its own shortcut")
            routing.observe(wanted, unavailable: true, at: 18)
            check(selected(ready: [other], at: 18) == wanted, "a second outage gets a fresh grace period")
        }
        for chord in [HotkeyChord.options, .shifts] {
            for primary in DeviceClass.allCases {
                var gesture = DeviceCaptureGesture()
                check(gesture.observe(chord, at: 1, primary: primary, dual: false) == .capture(chord, at: 1, deviceClass: primary), "single device starts immediately")
                check(gesture.selectionDeadline(pressedAt: 1) == 0, "single device has no delay")
                check(gesture.observe(chord, at: 1.1, primary: primary, dual: false) == .consumed, "single device fast double stays one image")
            }
            for gap in [0.001, 0.1, 0.499999, 0.500, 0.7] {
                var gesture = DeviceCaptureGesture()
                _ = gesture.observe(chord, at: 2, primary: .iPad, dual: true)
                check(gesture.selectionDeadline(pressedAt: 2) == 2.5, "500 ms commit window")
                let action = gesture.observe(chord, at: 2 + gap, primary: .iPad, dual: true)
                check(action == (gap < 0.5 ? .retarget(at: 2) : .capture(chord, at: 2 + gap, deviceClass: .iPad)), "double selection boundary")
                if gap < 0.5 { check(gesture.selectionDeadline(pressedAt: 2) == 0, "phone commit has no remaining delay") }
            }
        }
        for firstKind in DeviceClass.allCases {
            let other: DeviceClass = firstKind == .iPad ? .iPhone : .iPad
            var queue = DeviceCapturePipeline()
            let first = queue.admit(.options, at: 10, deviceClass: firstKind)!
            check(!first.queued, "single press keeps old targeting path")
            check(queue.startAvailable().map { $0.press } == [first], "one worker begins")
            check(queue.takeForTargeting() == first, "targeting starts before capture completed")
            for i in 1...3 { check(queue.admit(.options, at: 10 + Double(i), deviceClass: firstKind) != nil, "same device has three waiters") }
            check(queue.admit(.options, at: 14, deviceClass: firstKind) == nil, "fifth same-device press is busy")
            let second = queue.admit(.shifts, at: 14, deviceClass: other)!
            check(second.queued, "other device remembers chat while shared UI is occupied")
            check(queue.startAvailable().map { $0.press } == [second], "full sibling cannot occupy other transfer slot")
            check(queue.running.count == 2 && queue.startAvailable().isEmpty, "at most one request per device")
            check(!queue.completed(first.id, slot: other), "cross-device callback rejected")
            check(queue.completed(second.id, slot: other), "other device completes independently")
            check(queue.completed(first.id, slot: firstKind), "first completes")
            check(!queue.ready.contains(first), "reserved frame not delivered twice")
            check(queue.startAvailable().first?.press.deviceClass == firstKind, "next transfer overlaps first paste")
            queue.deliveryFinished()
            check(queue.takeForTargeting() == second, "other completed image retains identity")
            let dropped = queue.disconnected(deviceClass: firstKind)
            check(dropped.count == 2 && dropped.allSatisfy { $0.deviceClass == firstKind }, "disconnect clears only that device waiters")
            check(queue.delivering == second, "sibling delivery survives disconnect")
        }
        // A retarget discards only the speculative generation and preserves press time/chat key.
        var queue = DeviceCapturePipeline()
        let pad = queue.admit(.options, at: 20, deviceClass: .iPad)!
        _ = queue.startAvailable(); _ = queue.takeForTargeting()
        check(queue.remove(at: 20) == pad, "retire speculative pad")
        let phone = queue.admit(.options, at: 20, deviceClass: .iPhone)!
        check(phone.id != pad.id && phone.at == pad.at, "new generation same chat binding key")
        check(queue.startAvailable(excluding: [.iPad]).map { $0.press } == [phone], "phone doesn't wait for retired pad RPC")
        check(!queue.completed(pad.id, slot: .iPad), "late pad callback cannot publish")
        _ = queue.takeForTargeting(); queue.reset()
        let next = queue.admit(.options, at: 21, deviceClass: .iPhone)!
        _ = queue.startAvailable()
        check(next.id != phone.id && !queue.completed(phone.id, slot: .iPhone), "reset cannot reuse identity")
        check(queue.completed(next.id, slot: .iPhone), "new generation still owns device")
        print("Device capture pipeline: \(checks) checks passed (fake clocks and completions).")
    }
}
