import Foundation
@main @MainActor
struct DeviceCaptureAdapterTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); checks += 1
    }
    // Actual queued-chat restoration now runs here too (two bounded 120 ms reads).
    static func settle() async throws { try await Task.sleep(nanoseconds: 320_000_000) }
    static func fixture() -> DeviceCaptureAdapterFixture {
        TargetActivator.alwaysReady = true; TargetActivator.front = .chatGPT
        TargetActivator.activations = 0; TargetActivator.delay = 0
        let f = DeviceCaptureAdapterFixture()
        _ = f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false)
        f.padTarget.lease = Lease(name: "pad-chat"); f.phoneTarget.lease = Lease(name: "phone-chat")
        return f
    }
    static func main() async throws {
        for source in [DeviceCapturePipeline.Source.macKeyboard, .iPhoneShortcut] {
            let f = fixture()
            let now = ProcessInfo.processInfo.systemUptime
            let device: DeviceClass = source == .macKeyboard ? .iPad : .iPhone
            f.captureAnimation.holdingResult = true
            var checkedBeforeCapture = false
            f.captureWorkers[device]!.onCaptureStart = { [weak f] _ in
                guard let f, let press = f.capturePipeline.press(at: now) else { preconditionFailure("press missing") }
                check(f.captureAnimation.noticeID == String(press.id), "accepted \(source.rawValue) press has a notice before the worker starts")
                check(f.captureAnimation.noticeText == TransferNotice.text(received: 0, expected: 0, queued: 0),
                      "immediate notice does not promise a percentage before bytes arrive")
                checkedBeforeCapture = true
            }
            if source == .macKeyboard {
                f.selectCapture(.options, at: now)
            } else {
                check(f.admitCapture(.options, at: now, deviceClass: device, source: source), "phone press admitted")
            }
            check(checkedBeforeCapture, "checked synchronous notice at worker entry")
            let press = f.capturePipeline.press(at: now)!
            let uuid = f.captureWorkers[device]!.pending!.id
            f.pipelineProgress[uuid] = (received: 2, expected: 5)
            f.updateTransferNotice()
            check(f.captureAnimation.noticeID == String(press.id) &&
                      f.captureAnimation.noticeText == TransferNotice.text(received: 2, expected: 5, queued: 0),
                  "the first progress event updates the original notice without a slow-transfer event")
        }
        do {
            let f = fixture()
            check(!f.admitCapture(.options, at: .nan, deviceClass: .iPhone, source: .iPhoneShortcut),
                  "an invalid phone capture is rejected before starting a worker")
            check(f.captureWorkers[.iPhone]!.starts.isEmpty && f.captureAnimation.noticeID == nil &&
                      f.captureAnimation.cancelNotice == nil, "a rejected press cannot leave an active transfer notice")
        }
        do {
            let f = fixture()
            let now = ProcessInfo.processInfo.systemUptime
            f.admitCapture(.options, at: now, deviceClass: .iPhone, source: .iPhoneShortcut)
            let first = f.capturePipeline.press(at: now)!
            let cancelFirst = f.captureAnimation.cancelNotice!
            f.admitCapture(.options, at: now + 0.1, deviceClass: .iPhone, source: .iPhoneShortcut)
            let second = f.capturePipeline.press(at: now + 0.1)!
            check(f.captureAnimation.noticeID == String(first.id) &&
                      f.captureAnimation.noticeText == TransferNotice.text(received: 0, expected: 0, queued: 1),
                  "a queued press immediately updates the count and keeps the first press visible")
            f.captureWorkers[.iPhone]!.finish()
            f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
            try await settle()
            check(f.captureAnimation.noticeID == String(second.id), "queue hands the notice to the next press")
            cancelFirst()
            check(f.cancellationCount == 0, "a retired notice cannot cancel the next press")
            let cancelSecond = f.captureAnimation.cancelNotice!
            cancelSecond()
            check(f.cancellationCount == 1, "the current notice can cancel the displayed press")
            f.captureWorkers[.iPhone]!.finish()
            f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
            try await settle()
            cancelSecond()
            check(f.captureAnimation.noticeID == nil && f.cancellationCount == 1,
                  "the last press retires its notice and the retained click is inert")
        }
        // Reproduces the reported cycle with actual startCapture/locateAfterActivation:
        // a visible composer has no current-chat marker until it is focused.
        do {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.padTarget.requiresFocus = true
            f.selectCapture(.options, at: now)
            try await settle()
            check(f.transaction != nil && f.setupErrors == 0,
                  "unfocused frontmost composer must recover before declaring target failure")
            check(f.padTarget.focusRecoveries == 1, "first press focuses the identified composer automatically")
        }
        do {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.padTarget.requiresFocus = true; f.padTarget.focusDelay = 80_000_000
            f.selectCapture(.options, at: now)
            try await Task.sleep(nanoseconds: 20_000_000)
            check(f.padTarget.focusRecoveries == 1 && f.transaction == nil, "focus is still settling")
            let requestID = f.activationTask!.id
            f.selectCapture(.options, at: now + 0.1)
            check(f.activationTask?.id == requestID, "retarget during focus retains the original recovery")
            try await settle()
            check(f.transaction?.deviceClass == .iPhone && f.setupErrors == 0,
                  "second tap can select iPhone while composer focus is pending")
            f.captureWorkers[.iPad]!.finish(); f.captureWorkers[.iPhone]!.finish()
            f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
            try await settle()
            check(f.deliveries.count == 1 && f.deliveries[0].0 == .iPhone, "only the selected phone result delivers")
        }
        do {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.padTarget.requiresFocus = true; f.padTarget.focusDelay = 80_000_000
            f.selectCapture(.options, at: now)
            try await Task.sleep(nanoseconds: 20_000_000)
            f.cancelActivation(); f.enabled = false
            try await settle()
            check(f.transaction == nil && f.deliveries.isEmpty && f.setupErrors == 0,
                  "cancelled focus recovery cannot create a late transaction or paste")
        }
        for chord in [HotkeyChord.options, .shifts] {
          for background in [false, true] {
            for doubleTap in [false, true] {
                let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
                TargetActivator.alwaysReady = false
                TargetActivator.front = background ? nil : (chord == .options ? .chatGPT : .claude)
                TargetActivator.delay = 80_000_000
                let target = chord == .options ? f.padTarget : f.phoneTarget
                target.requiresFocus = true
                f.selectCapture(chord, at: now)
                check(f.activationTask != nil && f.transaction == nil, "background activation starts before capture finishes")
                let requestID = f.activationTask!.id
                if doubleTap {
                    f.selectCapture(chord, at: now + 0.1)
                    check(f.activationTask?.id == requestID, "second tap retains the ongoing background activation")
                }
                try await settle()
                check(f.transaction?.id == requestID && f.transaction?.lease.name == target.lease.name,
                      "background activation and composer recovery reach the original target")
                check(target.focusRecoveries == 1 && TargetActivator.activations == (background ? 1 : 0) && f.setupErrors == 0,
                      "one activation and one focus recovery per logical press")
                let device: DeviceClass = doubleTap ? .iPhone : .iPad
                check(f.transaction?.deviceClass == device, "focus recovery retains the selected device")
                if doubleTap { f.captureWorkers[.iPad]!.finish() }
                f.captureWorkers[device]!.finish()
                f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
                try await settle()
                check(f.deliveries.count == 1 && f.deliveries[0].0 == device,
                      "recovered background press delivers exactly once from the selected device")
                check(f.captureWorkers[device]!.starts.count == 1, "target recovery never recaptures an accepted image")
            }
          }
        }
        for locked in DeviceClass.allCases {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.captureWorkers[locked]!.deviceLocked = true
            f.captureWorkers[locked]!.connectionStatus.state = .failed
            f.selectCapture(.options, at: now)
            check(f.capturePipeline.press(at: now)?.deviceClass == locked.other, "single press takes the connected device")
            f.selectCapture(.options, at: now + 0.1)
            check(f.capturePipeline.press(at: now)?.deviceClass == locked.other, "double press stays on the connected device")
            check(f.captureWorkers[locked]!.starts.isEmpty, "known locked device never starts when its sibling is available")
        }
        do {
            // The disconnected iPad cannot report lock state. One press should still use the iPhone.
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime - 1
            f.captureWorkers[.iPad]!.connectionStatus.state = .failed
            f.devicePressRouting.observe(.iPad, unavailable: true, at: now - 7)
            f.selectCapture(.options, at: now)
            check(f.captureWorkers[.iPad]!.starts.isEmpty && f.captureWorkers[.iPhone]!.starts.count == 1,
                  "a single press skips the long offline iPad and starts iPhone immediately")
            f.captureWorkers[.iPhone]!.finish()
            f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
            try await settle()
            check(f.deliveries.count == 1 && f.deliveries[0].0 == .iPhone && f.failures.isEmpty,
                  "one press delivers one iPhone screenshot")
        }
        for secondTap in [false, true] {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.captureWorkers[.iPad]!.connectionStatus.state = .failed
            f.devicePressRouting.observe(.iPad, unavailable: true, at: now - 7)
            f.captureWorkers[.iPhone]!.deviceLocked = true
            f.selectCapture(.options, at: now)
            check(f.captureWorkers[.iPad]!.starts.isEmpty && f.failureReasons.isEmpty,
                  "wait for device selection instead of starting a transfer to the offline iPad")
            if secondTap {
                f.selectCapture(.options, at: now + 0.1)
                check(f.captureWorkers[.iPhone]!.starts.count == 1, "a quick second tap still starts the iPhone capture")
                f.captureWorkers[.iPhone]!.finish()
                f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
            }
            try await Task.sleep(nanoseconds: 600_000_000)
            if secondTap {
                check(f.deliveries.count == 1 && f.deliveries[0].0 == .iPhone && f.failureReasons.isEmpty,
                      "the superseded single tap cannot show a late unlock notice")
            } else {
                check(f.failureReasons == ["alternate_device_locked"] && f.captureWorkers.values.allSatisfy { $0.starts.isEmpty },
                      "one tap reports the known lock without waiting for a screenshot attempt")
            }
        }
        for cancelled in [false, true] {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.captureWorkers[.iPad]!.connectionStatus.state = .failed
            f.devicePressRouting.observe(.iPad, unavailable: true, at: now - 7)
            f.captureWorkers[.iPhone]!.deviceLocked = true
            f.selectCapture(.options, at: now)
            if cancelled {
                f.transaction = nil
                _ = f.core.reset(keepQueue: true)
                f.startQueuedPress(waited: 1)
            }
            f.captureWorkers[.iPad]!.connectionStatus.state = .ready
            f.devicePressRouting.observe(.iPad, unavailable: false, at: now + 0.1)
            try await Task.sleep(nanoseconds: 600_000_000)
            if cancelled {
                check(f.captureWorkers[.iPad]!.starts.isEmpty && f.capturePipeline.running.isEmpty && f.failureReasons.isEmpty,
                      "a cancelled press cannot start a transfer after the device reconnects")
            } else {
                check(f.captureWorkers[.iPad]!.starts.count == 1 && f.failureReasons.isEmpty,
                      "a device that reconnects during selection still takes its original shortcut")
            }
        }
        do {
            // The phone still reports locked, but the iPad is offline with no lock reading.
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.captureWorkers[.iPad]!.connectionStatus.state = .failed
            f.captureWorkers[.iPhone]!.deviceLocked = true
            f.selectCapture(.options, at: now)
            f.selectCapture(.options, at: now + 0.1)
            check(f.capturePipeline.delivering?.deviceClass == .iPhone, "double press keeps iPhone when iPad cannot take the press")
            f.captureWorkers[.iPad]!.finish(reason: "timeout")
            f.captureWorkers[.iPhone]!.finish()
            f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
            try await settle()
            check(f.deliveries.count == 1 && f.deliveries[0].0 == .iPhone && f.failures.isEmpty,
                  "only the phone screenshot delivers, even if the superseded iPad request times out")
        }
        do {
            // A black iPad frame hands the press to the iPhone, once; two black frames fail normally.
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime - 1
            f.selectCapture(.options, at: now)
            f.captureWorkers[.iPad]!.finish(reason: "black_frame_rejected")
            check(f.capturePipeline.press(at: now)?.deviceClass == .iPhone && f.captureWorkers[.iPhone]!.starts.count == 1, "black iPad moves to iPhone")
            f.captureWorkers[.iPhone]!.finish(reason: "black_frame_rejected")
            check(f.captureWorkers[.iPad]!.starts.count == 1, "only one fallback per press")
        }
        do {
            // The other device is off too: no fallback, the black frame is reported as before.
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime - 1
            f.captureWorkers[.iPhone]!.connectionStatus.state = .failed
            f.selectCapture(.options, at: now)
            f.captureWorkers[.iPad]!.finish(reason: "black_frame_rejected")
            check(f.captureWorkers[.iPhone]!.starts.isEmpty, "no fallback to a disconnected device")
        }
        do {
            // The other device is closed: a black frame stays on the chosen device.
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime - 1
            f.captureWorkers[.iPhone]!.deviceLocked = true
            f.selectCapture(.options, at: now)
            f.captureWorkers[.iPad]!.finish(reason: "black_frame_rejected")
            check(f.captureWorkers[.iPhone]!.starts.isEmpty, "no fallback to a closed device")
        }
        do {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime - 1
            f.admitCapture(.options, at: now, deviceClass: .iPad)
            check(f.targetings.count == 1 && f.targetings[0].2, "single targeting starts while worker is still in flight")
            for i in 1...3 { f.admitCapture(.options, at: now + Double(i) / 10, deviceClass: .iPad) }
            f.admitCapture(.options, at: now + 0.4, deviceClass: .iPad)
            check(f.capturePipeline.waitingCount == 3 && f.captureWorkers[.iPad]!.starts.count == 1, "one transmission and three waiters")
            f.admitCapture(.shifts, at: now + 0.5, deviceClass: .iPhone)
            check(f.captureWorkers[.iPhone]!.starts.count == 1, "full pad cannot block phone worker")
            f.phoneTarget.lease = Lease(name: "changed-phone-chat")
            f.captureWorkers[.iPhone]!.finish()
            check(f.deliveries.isEmpty, "UI delivery remains serial")
            f.captureWorkers[.iPad]!.finish()
            try await settle()
            check(f.deliveries.count == 2, "both images deliver once")
            check(f.deliveries[0].0 == .iPad && f.deliveries[0].1 == "pad-chat", "pad stays in its chat")
            check(f.deliveries[1].0 == .iPhone && f.deliveries[1].1 == "phone-chat", "phone retains press-time chat")
            check(f.captureWorkers[.iPad]!.starts.count == 2, "same-device next starts only after prior completion")
            f.captureWorkers[.iPad]!.finish(reason: "timeout")
            try await settle()
            check(f.captureWorkers[.iPad]!.starts.count == 3 && f.capturePipeline.waitingCount == 1, "one timeout leaves later same-device presses")
            f.captureWorkers[.iPad]!.finish(); try await settle()
            f.captureWorkers[.iPad]!.finish(); try await settle()
            check(f.deliveries.count == 4 && f.failures == [.iPad], "each accepted result has one outcome")
        }
        do {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            for i in 0..<4 { f.admitCapture(.options, at: now - 2 + Double(i) / 10, deviceClass: .iPad) }
            f.selectCapture(.shifts, at: now)
            check(f.capturePipeline.waitingCount == 3, "speculative rejected iPad selection occupies no slot")
            f.phoneTarget.lease = Lease(name: "changed-after-first-tap")
            f.selectCapture(.shifts, at: now + 0.1)
            check(f.captureWorkers[.iPhone]!.starts.count == 1, "full iPad must not prevent actual double-tap iPhone selection")
            f.captureWorkers[.iPhone]!.finish()
            f.captureWorkers[.iPad]!.finish(); try await settle()
            check(f.deliveries.contains { $0.0 == .iPhone && $0.1 == "phone-chat" }, "phone retains first-tap chat even when speculative iPad admission was full")
        }
        do {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            for i in 0..<4 { f.admitCapture(.options, at: now - 2 + Double(i) / 10, deviceClass: .iPad) }
            f.phoneTarget.unavailable = true
            f.selectCapture(.shifts, at: now)
            f.phoneTarget.unavailable = false
            f.selectCapture(.shifts, at: now + 0.1)
            check(f.queuedBindings[now] == nil, "missing first-tap binding cannot be replaced with second-tap chat")
            f.captureWorkers[.iPhone]!.finish()
            f.captureWorkers[.iPad]!.finish()
            // The real beginCapture adapter uses this flag for the manual-paste path.
            f.startQueuedPress(waited: 1)
            check(f.deliveryBindingMissing, "unprovable first-tap chat requires manual delivery")
        }
        for chord in [HotkeyChord.options, .shifts] {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.selectCapture(chord, at: now)
            check(f.targetings.count == 1 && f.captureWorkers[.iPad]!.isBusy, "first gesture begins immediately")
            f.captureWorkers[.iPad]!.finish()
            check(f.deliveries.isEmpty, "fast speculative result waits for device choice")
            f.selectCapture(chord, at: now + 0.1)
            check(f.captureWorkers[.iPhone]!.starts.count == 1 && f.capturePipeline.delivering?.deviceClass == .iPhone, "second gesture moves only this press")
            f.captureWorkers[.iPhone]!.finish()
            check(f.deliveries.isEmpty, "second chord must be released before paste")
            f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
            try await Task.sleep(nanoseconds: 530_000_000)
            check(f.deliveries.count == 1 && f.deliveries[0].0 == .iPhone, "delayed old pad callback cannot paste")
            check(f.deliveries[0].1 == (chord == .options ? "pad-chat" : "phone-chat"), "retarget retains original app/chat")
        }
        do {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.selectCapture(.options, at: now)
            f.selectCapture(.options, at: now + 0.1)
            f.captureWorkers[.iPad]!.finish(reason: "disconnected")
            check(f.captureWorkers[.iPhone]!.isBusy && f.failures.isEmpty, "late abandoned pad failure cannot fail phone")
            f.captureWorkers[.iPhone]!.finish()
            f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
            try await settle()
            check(f.deliveries.count == 1 && f.deliveries[0].0 == .iPhone, "in-flight retarget delivers phone exactly once")
        }
        do {
            // Keep an original activation task even when the phone lane is occupied.
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.admitCapture(.shifts, at: now - 1, deviceClass: .iPhone)
            f.admitCapture(.options, at: now, deviceClass: .iPad)
            f.captureWorkers[.iPhone]!.finish(); try await settle()
            check(f.transaction?.deviceClass == .iPad, "pad targeting reserved")
            // Another phone RPC is already transferring while pad owns the UI.
            f.admitCapture(.shifts, at: now + 0.01, deviceClass: .iPhone)
            let originalID = f.transaction!.id
            let originalLease = f.transaction!.lease.name
            f.retargetPipelineCapture(at: now)
            check(f.transaction?.id == originalID && f.transaction?.lease.name == originalLease, "busy phone retarget retains original lease and UI request")
            check(f.captureWorkers[.iPhone]!.starts.count == 2, "retarget waits for busy phone rather than overlapping")
            f.captureWorkers[.iPad]!.finish()
            f.captureWorkers[.iPhone]!.finish()
            check(f.captureWorkers[.iPhone]!.starts.count == 3, "reserved retarget begins after earlier phone transfer")
            f.captureWorkers[.iPhone]!.finish()
            f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
            try await settle()
            check(f.deliveries.count == 3 && f.deliveries[1].0 == .iPhone && f.deliveries[1].1 == originalLease, "reserved phone result joins original target exactly once")
        }
        do {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.selectCapture(.options, at: now)
            let tx = f.transaction!
            f.transaction = nil
            f.earlyCapture = .init(id: tx.id, uuid: tx.uuid, image: tx.image, deviceClass: tx.deviceClass)
            f.activationTask = (tx.id, Task { try? await Task.sleep(nanoseconds: 10_000_000_000) })
            f.retargetPipelineCapture(at: now)
            check(f.activationTask?.id == tx.id && f.earlyCapture?.deviceClass == .iPhone, "original in-flight targeting survives retarget")
            f.activationTask?.task.cancel()
        }
        do {
            let f = fixture(); let now = ProcessInfo.processInfo.systemUptime
            f.selectCapture(.options, at: now)
            let tx = f.transaction!
            f.transaction = nil
            f.earlyCapture = .init(id: tx.id, uuid: tx.uuid, image: tx.image, deviceClass: tx.deviceClass)
            f.earlyTargetFailure = true
            f.retargetPipelineCapture(at: now)
            check(f.earlyTargetFailure == true && f.targetlessFinishes == 1, "failed early targeting still gets manual recovery after retarget")
        }
        do {
            let f = fixture()
            let now = ProcessInfo.processInfo.systemUptime
            check(f.admitCapture(.shifts, at: now, deviceClass: .iPhone, source: .iPhoneShortcut),
                  "the iPhone shortcut is admitted when both devices are paired")
            check(f.transaction?.deviceClass == .iPhone && f.transaction?.kind == .claude,
                  "the iPhone shortcut backs a Claude draft even when iPad is the keyboard default")
            f.retargetPipelineCapture(at: now, to: .iPad)
            f.captureWorkers[.iPhone]!.finish(reason: "black_frame_rejected")
            try await settle()
            check(f.captureWorkers[.iPad]!.starts.isEmpty && f.deliveries.isEmpty,
                  "a failed iPhone shortcut never takes a screenshot of the iPad")
        }
        do {
            let f = fixture()
            let now = ProcessInfo.processInfo.systemUptime
            f.admitCapture(.options, at: now, deviceClass: .iPhone, source: .iPhoneShortcut)
            f.selectCapture(.options, at: now + 0.1)
            f.selectCapture(.options, at: now + 0.2)
            check(f.capturePipeline.press(at: now)?.deviceClass == .iPhone &&
                  f.capturePipeline.press(at: now + 0.1)?.deviceClass == .iPhone &&
                  f.captureWorkers[.iPad]!.starts.count == 1,
                  "a keyboard double press selects its own device without changing the iPhone shortcut")
            f.captureWorkers[.iPhone]!.finish()
            f.captureWorkers[.iPad]!.finish()
            f.captureWorkers[.iPhone]!.finish()
            f.handle(f.core.observe(ModifierSnapshot(), at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
            try await settle()
            check(f.deliveries.count == 2 && f.deliveries.allSatisfy { $0.0 == .iPhone },
                  "the shortcut and the laptop double press each deliver one iPhone screenshot")
        }
        do {
            let f = fixture()
            f.selectCapture(.options, at: ProcessInfo.processInfo.systemUptime)
            f.uninstalling = true
            f.enabled = false
            f.captureWorkers[.iPad]!.finish()
            try await settle()
            check(f.deliveries.isEmpty, "Late worker result cannot deliver during uninstall")
        }
        print("Actual device scheduling adapter: \(checks) checks passed; workers and UI effects are synthetic.")
    }
}
