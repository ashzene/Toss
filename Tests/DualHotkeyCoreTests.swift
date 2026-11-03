import Foundation

// Run with scripts/test-dual-hotkey.sh. Pure state only; no platform APIs.
enum TargetFailureStub: Error { case gone }

@main
enum DualHotkeyCoreTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }
    static let up = ModifierSnapshot()
    static let leftOpt = ModifierSnapshot(leftOption: true)
    static let bothOpt = ModifierSnapshot(leftOption: true, rightOption: true)
    static let leftShift = ModifierSnapshot(leftShift: true)
    static let bothShift = ModifierSnapshot(leftShift: true, rightShift: true)

    static func captures(_ actions: [HotkeyAction]) -> [HotkeyRequest] {
        actions.compactMap { if case .capture(let r) = $0 { return r }; return nil }
    }

    static func main() {
        // v2: fake clock/worker drives the same production reservation model. A
        // single press starts targeting with its capture still in flight, binds
        // after activation, and receives exactly one paste authorization.
        for chord in [HotkeyChord.options, .shifts] {
            var now = 0.0
            var serial = CapturePipeline()
            var core = DualHotkeyCore()
            _ = core.observe(up, at: now, allowNewCapture: false)
            let first = serial.admit(chord, at: now)!
            let transfers = serial.startAvailable()
            check(transfers.count == 1 && transfers[0].slot == 0, "single press requests the shared USB-first worker")
            let captureDue = now + 0.95 // fake USB worker, including PNG validation
            let target = serial.takeForTargeting()!
            let targetingStarted = now
            check(target == first && !target.queued, "an isolated press is not a queued/unbound delivery")
            check(!CapturePipeline.bindingMissing(queued: target.queued, hasBinding: false),
                  "first Claude press may activate its app and locate normally; no forced manual paste")
            let request = captures(core.beginDelivery(chord: chord, pressedAt: now, at: now))[0]
            now += 0.18 // fake activation and target lookup completes during the transfer
            check(targetingStarted < captureDue && now < captureDue && serial.ready.isEmpty,
                  "single key timing: targeting starts and finishes BEFORE capture completes")
            now = captureDue
            check(serial.completed(first.id, slot: 0), "in-flight delivery accepts its own result")
            check(serial.ready.isEmpty, "completion does not enqueue the reserved frame again")
            let pasted = core.captureSucceeded(requestID: request.id, imageToken: "first", at: now)
            check(pasted == [.pasteIntent(request, imageToken: "first")], "isolated key pastes normally once")
            check(core.captureSucceeded(requestID: request.id, imageToken: "first", at: now).isEmpty, "duplicate callback never pastes twice")
            now += 0.15 // fake focus/paste/confirmation, overlapped targeting costs no extra time
            check(now <= 1.1, "same 950 ms capture plus 150 ms paste budget equals the old single-key path")
            core.appendFinished(requestID: request.id); serial.deliveryFinished()
            check(serial.takeForTargeting() == nil && !serial.isBusy, "single key leaves no phantom queued image")
        }
        // Both USB and Wi-Fi use the SAME serial scheduler, including presses
        // accepted during targeting/paste and after an ordinary timeout.
        for link in ["usb", "wifi"] {
            var serial = CapturePipeline()
            let first = serial.admit(.options, at: 0)!
            check(serial.startAvailable().map(\.slot) == [0], "\(link): first transfer starts")
            check(serial.takeForTargeting() == first, "first target reservation")
            let second = serial.admit(.options, at: 0.1)!
            let third = serial.admit(.shifts, at: 0.2)!
            let fourth = serial.admit(.options, at: 0.3)!
            check(serial.startAvailable().isEmpty && serial.running.count == 1, "\(link): no second upload on the same link")
            check(serial.admit(.options, at: 0.4) == nil, "four accepted transfers bound the queue")
            check(second.queued && CapturePipeline.bindingMissing(queued: true, hasBinding: false), "a truly unbound busy press still preserves its image for manual paste")
            check(!CapturePipeline.bindingMissing(queued: true, hasBinding: true), "same-chat busy press retains automatic paste")
            _ = serial.completed(first.id, slot: 0) // failure or success releases just this transfer
            check(!CaptureQueueFailurePolicy.affectsQueuedPresses("timeout"), "ordinary timeout keeps later presses")
            check(serial.startAvailable().first?.press == second, "\(link): second uses primary after first releases link")
            check(serial.takeForTargeting() == nil, "next upload may overlap first paste but cannot steal its UI reservation")
            _ = serial.completed(second.id, slot: 0)
            check(serial.startAvailable().first?.press == third, "third starts in order as second arrives")
            serial.deliveryFinished()
            check(serial.takeForTargeting() == second, "already-arrived second remains first in delivery order")
            serial.deliveryFinished()
            check(serial.takeForTargeting() == third, "third starts targeting while third capture is still running")
            _ = serial.completed(third.id, slot: 0)
            check(serial.startAvailable().first?.press == fourth, "fourth survives first timeout")
            serial.deliveryFinished()
            _ = serial.completed(fourth.id, slot: 0)
            check(serial.takeForTargeting() == fourth, "fourth arrives once")
            serial.deliveryFinished()
            check(!serial.isBusy, "serial queue drains with no loss or duplicates")
        }

        // Legacy independent-link model: standby failure still defers to primary.
        var pipeline = CapturePipeline(transferLimit: 2)
        let a = pipeline.admit(.options, at: 1)!
        check(pipeline.startAvailable().map(\.slot) == [0], "first press dispatches immediately")
        let b = pipeline.admit(.options, at: 2)!
        check(pipeline.startAvailable().map(\.slot) == [1], "same-chat second press dispatches concurrently")
        let c = pipeline.admit(.shifts, at: 3)!, d = pipeline.admit(.options, at: 4)!
        check(pipeline.startAvailable().isEmpty && pipeline.waitingCount == 2, "third and fourth wait")
        check(pipeline.admit(.options, at: 5) == nil, "fifth press reports busy")
        check(pipeline.completed(b.id, slot: 1), "second completes first")
        check(!pipeline.completed(b.id, slot: 1), "duplicate completion ignored")
        check(pipeline.takeReady() == b, "second is delivered first with original target and press time")
        check(pipeline.takeReady() == nil, "clipboard delivery is serialized")
        check(pipeline.startAvailable().first?.press == c, "slot freed by data completion starts third immediately")
        _ = pipeline.completed(a.id, slot: 0) // ordinary failure has the same per-press completion path
        check(pipeline.startAvailable().first?.press == d, "one timeout does not drop fourth")
        pipeline.deliveryFinished()
        check(pipeline.takeReady() == a, "first result delivered only once")
        pipeline.deliveryFinished()
        _ = pipeline.completed(c.id, slot: 1); _ = pipeline.completed(d.id, slot: 0)
        check(pipeline.takeReady() == c, "third retains Shift destination")
        pipeline.deliveryFinished()
        check(pipeline.takeReady() == d, "fourth retains Option destination")
        pipeline.deliveryFinished()
        check(!pipeline.isBusy, "all four drain without duplicates")
        // Drive the actual once-only paste authorization with reversed capture completion.
        // Bind both presses to the same chat, then change the visible chat before delivery.
        var delivery = DualHotkeyCore()
        _ = delivery.observe(up, at: 0, allowNewCapture: false)
        let destinations = [a.id: "chat-A", b.id: "chat-A"]
        let visibleChat = "chat-B"
        var deliveredImages: [(UInt64, String)] = []
        for press in [b, a] {
            let request = captures(delivery.beginDelivery(chord: press.chord, pressedAt: press.at, at: 6))[0]
            let token = "image-\(press.id)"
            let actions = delivery.captureSucceeded(requestID: request.id, imageToken: token, at: 6.1)
            check(actions == [.pasteIntent(request, imageToken: token)], "one ready result authorizes exactly one paste")
            check(delivery.captureSucceeded(requestID: request.id, imageToken: token, at: 6.2).isEmpty,
                  "late duplicate receipt cannot authorize a second paste")
            deliveredImages.append((press.id, destinations[press.id]!))
            delivery.appendFinished(requestID: request.id)
        }
        check(deliveredImages.map(\.0) == [b.id, a.id], "two same-chat images paste in completion order")
        check(deliveredImages.allSatisfy { $0.1 == "chat-A" && $0.1 != visibleChat }, "original bindings survive navigation")

        // log2: second frame arrived after 1.4 s, then waited behind a delivery.
        var delayed = CapturePipeline()
        let delayedPress = delayed.admit(.options, at: 0)!
        _ = delayed.startAvailable()
        _ = delayed.completed(delayedPress.id, slot: 0) // received at 1.4 s
        check(delayed.takeReady() == delayedPress, "received frame survives queue wait beyond ten seconds")
        check(CapturedImageRecoveryPolicy.preserve(validated: true, pastePosted: false, explicitlyCancelled: false),
              "at 11.4 seconds, expired key wait or changed draft preserves received image for manual paste")
        delayed.deliveryFinished()
        check(delayed.takeReady() == nil, "manual recovery consumes the completed frame only once")
        check(!CapturedImageRecoveryPolicy.preserve(validated: false, pastePosted: false, explicitlyCancelled: false),
              "unvalidated image cannot be placed on clipboard")
        check(!CapturedImageRecoveryPolicy.preserve(validated: true, pastePosted: true, explicitlyCancelled: false),
              "posted paste is never replayed by recovery")
        check(!CapturedImageRecoveryPolicy.preserve(validated: true, pastePosted: false, explicitlyCancelled: true),
              "explicit user cancellation remains cancellation")

        // Second route busy or service error: the press is retried on the first route, not failed,
        // and from then on captures run one at a time on the first route.
        var fallback = CapturePipeline(transferLimit: 2)
        let firstPress = fallback.admit(.options, at: 0)!
        let secondPress = fallback.admit(.options, at: 0.2)!
        let started = fallback.startAvailable()
        check(started.count == 2 && started[1].slot == 1 && started[1].press == secondPress, "two captures start at once")
        check(ParallelCaptureFallbackPolicy.retryOnFirstRoute(slot: 1, reason: "service_unavailable"), "standby service error retries on the first route")
        check(ParallelCaptureFallbackPolicy.retryOnFirstRoute(slot: 1, reason: "worker_failed"), "standby worker failure retries")
        check(!ParallelCaptureFallbackPolicy.retryOnFirstRoute(slot: 1, reason: "timeout"), "a slow standby timeout stays a failure")
        check(!ParallelCaptureFallbackPolicy.retryOnFirstRoute(slot: 1, reason: "black_frame_rejected"), "a real frame result stays a result")
        check(!ParallelCaptureFallbackPolicy.retryOnFirstRoute(slot: 0, reason: "service_unavailable"), "first-route failures are not retried here")
        check(!ParallelCaptureFallbackPolicy.retryOnFirstRoute(slot: 1, reason: nil), "a success is not retried")
        check(fallback.deferredToFirstRoute(secondPress.id, slot: 1), "second press goes back to the queue")
        check(fallback.waiting.first == secondPress && fallback.parallelPaused && fallback.running[1] == nil, "deferred press waits at the head, parallel paused")
        check(fallback.startAvailable().isEmpty, "the deferred press waits while the first route is busy")
        check(!fallback.deferredToFirstRoute(firstPress.id, slot: 0), "the first route is never deferred")
        _ = fallback.completed(firstPress.id, slot: 0)
        let restarted = fallback.startAvailable()
        check(restarted.count == 1 && restarted[0].slot == 0 && restarted[0].press == secondPress, "deferred press then captures on the first route")
        check(fallback.takeReady() == firstPress, "the first press is still delivered")
        fallback.reset()
        check(!fallback.parallelPaused, "reset restores two routes")

        var detector = CaptureChordDetector()
        check(detector.observe(bothOpt, allow: true) == nil, "held keys at enable do not capture")
        _ = detector.observe(up, allow: true)
        check(detector.observe(bothOpt, allow: true) == .options, "fresh chord captures")
        check(detector.observe(bothOpt, allow: true) == nil, "held chord does not repeat")
        _ = detector.observe(up, allow: true)
        check(detector.observe(bothOpt, allow: true) == .options, "next complete chord captures independently")

        // Shift chord starts a Claude request (even ID); Option chord an odd one.
        var core = DualHotkeyCore(captureTimeout: 45)
        _ = core.observe(up, at: 0)
        _ = core.observe(leftShift, at: 0.01)
        let shift = captures(core.observe(bothShift, at: 0.02))
        check(shift.count == 1 && DualHotkeyCore.chord(of: shift[0].id) == .shifts, "both Shifts start one Claude request")
        check(core.isBusy && core.activeRequestID == shift[0].id, "shift request owns the slot")

        // While Shift request is busy, an Option chord starts nothing now (it is queued, see below).
        _ = core.observe(up, at: 0.03)
        _ = core.observe(leftOpt, at: 0.04)
        let repeated = core.observe(bothOpt, at: 0.05)
        check(captures(repeated).isEmpty, "options cannot start while shift request busy")
        check(repeated == [.busyRepeat(requestID: shift[0].id, phase: "capturing")],
              "the Option chord is acknowledged against the running Claude request")
        _ = core.observe(up, at: 0.06)

        // Success then full release issues paste for the shift request only.
        let ready = core.captureSucceeded(requestID: shift[0].id, imageToken: "token", at: 1)
        let pasteNow = ready.contains { if case .pasteIntent(let r, _) = $0 { return r.id == shift[0].id }; return false }
        check(pasteNow, "released keys issue paste intent for the shift request")
        check(core.pasteIsCurrent(requestID: shift[0].id, at: 1.5), "shift paste is current")
        core.appendFinished(requestID: shift[0].id)
        check(!core.isBusy, "append finished frees slot")

        // Now Options work and get an odd ID.
        _ = core.observe(up, at: 2)
        _ = core.observe(leftOpt, at: 2.01)
        let opt = captures(core.observe(bothOpt, at: 2.02))
        check(opt.count == 1 && DualHotkeyCore.chord(of: opt[0].id) == .options, "both Options start one ChatGPT request")
        check(opt[0].id != shift[0].id, "request IDs never collide across chords")
        _ = core.observe(up, at: 2.03)
        _ = core.captureFailed(requestID: opt[0].id, at: 2.5)
        check(!core.isBusy, "failure frees slot")

        // Presses made while a request runs are queued in order and start, one at a time,
        // only when the adapter asks (2026-10-28: allow the next toss before the last
        // one has pasted). A queued request needs no new physical press to paste.
        var q = DualHotkeyCore(captureTimeout: 45)
        _ = q.observe(up, at: 0); _ = q.observe(leftShift, at: 0.01)
        let running = captures(q.observe(bothShift, at: 0.02))
        _ = q.observe(up, at: 0.03); _ = q.observe(leftOpt, at: 0.04)
        check(q.observe(bothOpt, at: 0.05) == [.busyRepeat(requestID: running[0].id, phase: "capturing")],
              "a press while busy is still acknowledged")
        _ = q.observe(up, at: 0.06); _ = q.observe(leftShift, at: 0.07); _ = q.observe(bothShift, at: 0.08)
        _ = q.observe(up, at: 0.09)
        check(q.queuedCount == 2, "both presses are queued")
        check(q.startQueued(at: 0.1).isEmpty, "nothing starts while the slot is busy")
        _ = q.captureSucceeded(requestID: running[0].id, imageToken: "a", at: 0.5)
        q.appendFinished(requestID: running[0].id)
        _ = q.reset(keepQueue: true)
        check(q.queuedCount == 2, "the end of a request keeps the queue")
        let firstQueued = captures(q.startQueued(at: 1))
        check(firstQueued.count == 1 && DualHotkeyCore.chord(of: firstQueued[0].id) == .options,
              "the oldest press (Options) starts first")
        check(firstQueued[0].startedAt == 0.05 && firstQueued[0].deadlineAt == 1 + 45,
              "a queued request dates from its press (its screenshot may be fetched early), its deadline from now")
        check(q.queuedCount == 1 && q.startQueued(at: 1.1).isEmpty, "one at a time")
        let pasted = q.captureSucceeded(requestID: firstQueued[0].id, imageToken: "b", at: 1.4)
        check(pasted.contains { if case .pasteIntent(let r, _) = $0 { return r.id == firstQueued[0].id }; return false },
              "a queued request pastes without another physical press")
        q.appendFinished(requestID: firstQueued[0].id)
        let secondQueued = captures(q.startQueued(at: 2))
        check(secondQueued.count == 1 && DualHotkeyCore.chord(of: secondQueued[0].id) == .shifts, "then the Shift press")
        check(q.queuedCount == 0, "queue drained")
        // Limit, lifetime and a full reset.
        var lim = DualHotkeyCore(captureTimeout: 45)
        _ = lim.observe(up, at: 0); _ = lim.observe(bothOpt, at: 0.01); _ = lim.observe(up, at: 0.02)
        for i in 0..<5 { _ = lim.observe(bothOpt, at: 0.1 + Double(i) * 0.1); _ = lim.observe(up, at: 0.15 + Double(i) * 0.1) }
        check(lim.queuedCount == DualHotkeyCore.queueLimit, "at most three presses wait")
        _ = lim.captureFailed(requestID: lim.activeRequestID ?? 0, at: 1)
        check(lim.startQueued(at: 1 + DualHotkeyCore.queueLifetime + 1).isEmpty && lim.queuedCount == 0,
              "presses older than the lifetime are dropped, not pasted late")
        _ = lim.observe(bothOpt, at: 30); _ = lim.observe(up, at: 30.1); _ = lim.observe(bothOpt, at: 30.2)
        check(lim.queuedCount == 1, "queued again behind a new request")
        _ = lim.reset()
        check(lim.queuedCount == 0 && lim.startQueued(at: 31).isEmpty, "disable / lost monitoring clears the queue")

        // A link failure ends waiting presses together. Dropping them emits no actions:
        // the adapter reports only the one failing capture, not one toast per queued chord.
        func queuedBatch() -> (DualHotkeyCore, HotkeyRequest) {
            var batch = DualHotkeyCore(captureTimeout: 45)
            _ = batch.observe(up, at: 0)
            let request = captures(batch.observe(bothOpt, at: 0.01))[0]
            _ = batch.observe(up, at: 0.02)
            for index in 1...3 {
                _ = batch.observe(index == 2 ? bothShift : bothOpt, at: Double(index))
                _ = batch.observe(up, at: Double(index) + 0.01)
            }
            return (batch, request)
        }
        for reason in ["disconnected", "no_authenticated_remote_wifi_connection",
                       "developer_image_unavailable", "pairing_state_missing"] {
            var (batch, request) = queuedBatch()
            check(batch.discardUncapturedQueuedPresses(after: reason) == 3,
                  "\(reason) silently ends all three uncaptured presses, including an in-flight prefetch")
            let failed = batch.captureFailed(requestID: request.id, at: 4)
            check(failed == [.rejected(requestID: request.id, .captureFailed)],
                  "\(reason) has exactly one failure notification, from the running request")
            _ = batch.reset(keepQueue: true)
            check(batch.startQueued(at: 4.1).isEmpty && batch.queuedCount == 0,
                  "cleanup cannot restart any request dropped for \(reason)")
        }
        var (saved, failedRequest) = queuedBatch()
        check(saved.discardUncapturedQueuedPresses(after: "disconnected", capturedAt: 1) == 2,
              "a completed prefetch is preserved while uncaptured presses end")
        _ = saved.captureFailed(requestID: failedRequest.id, at: 4)
        _ = saved.reset(keepQueue: true)
        let savedRequest = captures(saved.startQueued(at: 4.1))[0]
        check(savedRequest.startedAt == 1 && saved.queuedCount == 0, "only the already captured press starts")
        check(saved.captureSucceeded(requestID: savedRequest.id, imageToken: "saved-image", at: 4.2)
                == [.pasteIntent(savedRequest, imageToken: "saved-image")],
              "the saved screenshot pastes normally after the preceding link failure")
        saved.appendFinished(requestID: savedRequest.id)
        check(saved.startQueued(at: 4.3).isEmpty, "no discarded request returns after the saved picture pastes")
        var (prefetchFailed, pastingRequest) = queuedBatch()
        _ = prefetchFailed.captureSucceeded(requestID: pastingRequest.id, imageToken: "already-pasting", at: 3.2)
        check(prefetchFailed.discardUncapturedQueuedPresses(after: "disconnected", reportingFailureAt: 1) == 2,
              "failed prefetch keeps only its completed failure receipt for one later notification")
        check(prefetchFailed.pasteIsCurrent(requestID: pastingRequest.id, at: 3.3),
              "the earlier captured image keeps its paste authorization")
        prefetchFailed.appendFinished(requestID: pastingRequest.id)
        let reporting = captures(prefetchFailed.startQueued(at: 4))[0]
        check(reporting.startedAt == 1 && prefetchFailed.queuedCount == 0,
              "only the failed prefetch is adopted to report its saved result")
        check(prefetchFailed.captureFailed(requestID: reporting.id, at: 4.01)
                == [.rejected(requestID: reporting.id, .captureFailed)], "failed prefetch reports once")
        check(prefetchFailed.startQueued(at: 4.02).isEmpty, "failed prefetch has no repeated waiting requests")
        for reason in ["timeout", "first_byte_timeout", "stall_timeout", "too_slow", "slow_threshold", "worker_failed",
                       "black_frame_rejected", "invalid_png", "empty_frame", "unexpected_dimensions",
                       "capture_integrity_failed"] {
            var (batch, request) = queuedBatch()
            check(batch.discardUncapturedQueuedPresses(after: reason) == 0 && batch.queuedCount == 3,
                  "\(reason) belongs only to this image and does not clear the queue")
            _ = batch.captureFailed(requestID: request.id, at: 4)
            check(captures(batch.startQueued(at: 4.1)).first?.startedAt == 1 && batch.queuedCount == 2,
                  "the next press still captures after \(reason)")
        }
        // A later manual chord is a fresh attempt, even after an entire batch ended.
        var (again, failedAgain) = queuedBatch()
        again.discardUncapturedQueuedPresses(after: "slow_threshold")
        _ = again.captureFailed(requestID: failedAgain.id, at: 4)
        _ = again.reset(keepQueue: true)
        _ = again.observe(up, at: 4.1)
        check(captures(again.observe(bothOpt, at: 4.2)).count == 1, "a new press can try again immediately")

        // Drive the same receipt/adoption policy used by TossApp callbacks, with only the
        // UI failure effect replaced by an array. No target lease is needed to end a slow RPC.
        let receiptID = "00000000-0000-4000-8000-000000000001"
        func payload(ok: Bool, reason: String, id: String = receiptID, schema: Int = 1) -> Data {
            try! JSONSerialization.data(withJSONObject: ["schema_version": schema, "request_id": id,
                                                        "ok": ok, "reason": reason])
        }
        let thresholdFailure = payload(ok: false, reason: "slow_threshold")
        let connectionFailure = payload(ok: false, reason: "disconnected")
        let successfulReply = payload(ok: true, reason: "captured")
        let failureReceipt = CaptureCompletionPolicy.classify(thresholdFailure, exitCode: 1, requestID: receiptID)
        check(failureReceipt == .failure("slow_threshold"), "callback recognizes the new backend failure")
        check(CaptureCompletionPolicy.classify(successfulReply, exitCode: 0, requestID: receiptID) == .declaredSuccess,
              "complete success is classified separately from a completed failed prefetch")
        for data in [payload(ok: false, reason: "slow_threshold", id: "other-request"),
                     payload(ok: false, reason: "slow_threshold", schema: 2),
                     payload(ok: false, reason: "not a reason"), Data("broken".utf8)] {
            check(CaptureCompletionPolicy.classify(data, exitCode: 1, requestID: receiptID) == .invalid,
                  "malformed or stale receipt cannot end a different active request")
        }
        check(CaptureCompletionPolicy.classify(thresholdFailure, exitCode: 0, requestID: receiptID) == .invalid,
              "success exit with failed payload is not a trusted failure")
        var (beforeTarget, earlyRequest) = queuedBatch()
        var presentedFailures: [String] = []
        func receiveBeforeTarget(_ data: Data) {
            let receipt = CaptureCompletionPolicy.classify(data, exitCode: 1, requestID: receiptID)
            if let reason = CaptureCompletionPolicy.failureBeforeTarget(receipt,
                    activeRequestMatches: beforeTarget.activeRequestID == earlyRequest.id, transactionExists: false) {
                beforeTarget.discardUncapturedQueuedPresses(after: reason)
                _ = beforeTarget.captureFailed(requestID: earlyRequest.id, at: 4)
                presentedFailures.append(reason)
            }
        }
        receiveBeforeTarget(thresholdFailure)
        check(presentedFailures == ["slow_threshold"] && !beforeTarget.isBusy && beforeTarget.queuedCount == 3,
              "early ordinary failure reports once and preserves all waiting requests")
        receiveBeforeTarget(thresholdFailure)
        check(presentedFailures.count == 1, "a duplicate or late failure callback cannot show a second result")
        check(beforeTarget.activeRequestID != earlyRequest.id,
              "a late target activation cannot begin capture again for the failed request")
        check(CaptureCompletionPolicy.failureBeforeTarget(failureReceipt,
                  activeRequestMatches: true, transactionExists: true) == nil,
              "an adopted transaction routes its failure through the normal single completion path")
        check(CaptureCompletionPolicy.failureBeforeTarget(.declaredSuccess,
                  activeRequestMatches: true, transactionExists: false) == nil,
              "success still waits for target validation")

        var (prefetchedCallback, currentPaste) = queuedBatch()
        _ = prefetchedCallback.captureSucceeded(requestID: currentPaste.id, imageToken: "previous-frame", at: 3.2)
        let queuedFailure = CaptureCompletionPolicy.classify(connectionFailure, exitCode: 1, requestID: receiptID)
        if case .failure(let reason) = queuedFailure {
            prefetchedCallback.discardUncapturedQueuedPresses(after: reason, reportingFailureAt: 1)
        }
        check(prefetchedCallback.queuedCount == 1 && prefetchedCallback.pasteIsCurrent(requestID: currentPaste.id, at: 3.3),
              "prefetch callback ends the trailing batch while the preceding captured frame continues pasting")
        check(CaptureCompletionPolicy.canAdoptPrefetch(queuedFailure, arrivedAge: 12, workerOwnsRequest: false),
              "a completed failed prefetch remains reportable after 12 seconds without another RPC")
        check(!CaptureCompletionPolicy.canAdoptPrefetch(.declaredSuccess, arrivedAge: 12, workerOwnsRequest: false),
              "the failure exception does not allow stale successful images")
        check(CaptureCompletionPolicy.canAdoptPrefetch(.declaredSuccess, arrivedAge: 1, workerOwnsRequest: false),
              "a fresh completed prefetch remains available for the ordinary paste path")
        check(!CaptureCompletionPolicy.canAdoptPrefetch(nil, arrivedAge: nil, workerOwnsRequest: false)
              && CaptureCompletionPolicy.canAdoptPrefetch(nil, arrivedAge: nil, workerOwnsRequest: true),
              "an unfinished prefetch is adopted only while its worker still owns the request")
        prefetchedCallback.appendFinished(requestID: currentPaste.id)
        let queuedReport = captures(prefetchedCallback.startQueued(at: 4))[0]
        check(CaptureCompletionPolicy.failureBeforeTarget(queuedFailure,
                  activeRequestMatches: prefetchedCallback.activeRequestID == queuedReport.id,
                  transactionExists: false) == "disconnected",
              "adopting the failed prefetch reports the original connection reason without target activation")
        _ = prefetchedCallback.captureFailed(requestID: queuedReport.id, at: 4.01)
        check(prefetchedCallback.startQueued(at: 4.02).isEmpty, "saved failure cannot re-enter the queue")

        // Four keys together start nothing: each chord sees the other as contamination.
        var four = DualHotkeyCore()
        _ = four.observe(up, at: 0)
        let all = ModifierSnapshot(leftOption: true, rightOption: true, leftShift: true, rightShift: true)
        check(captures(four.observe(all, at: 0.01)).isEmpty, "Options+Shifts start nothing")
        _ = four.observe(up, at: 0.02)

        // Shift chord contaminated by an ordinary key (typing capitals) or Command.
        var typing = DualHotkeyCore()
        _ = typing.observe(up, at: 0)
        _ = typing.observe(ModifierSnapshot(leftShift: true, ordinaryKey: true), at: 0.01)
        check(captures(typing.observe(ModifierSnapshot(leftShift: true, rightShift: true, ordinaryKey: true), at: 0.02)).isEmpty,
              "shift with a letter key never triggers")
        _ = typing.observe(up, at: 0.03)
        check(captures(typing.observe(ModifierSnapshot(leftShift: true, rightShift: true, command: true), at: 0.04)).isEmpty,
              "shift+command never triggers")
        _ = typing.observe(up, at: 0.05)
        check(captures(typing.observe(bothShift, at: 0.06)).count == 1, "clean shift chord after release triggers")

        // Holding the chord does not repeat; reset clears both machines.
        check(captures(typing.observe(bothShift, at: 0.07)).isEmpty, "held chord does not repeat")
        let reset = typing.reset()
        check(reset.count == 1 && !typing.isBusy, "reset cancels the active request")

        // Projections: allReleased covers Shifts too.
        check(!ModifierSnapshot(rightShift: true).allReleased, "a held Shift is not released")
        check(ModifierSnapshot().allReleased, "empty snapshot is released")
        check(ModifierSnapshot(leftShift: true).optionChord.otherModifier, "Shift contaminates the Option chord")
        check(ModifierSnapshot(rightOption: true).shiftChord.otherModifier, "Option contaminates the Shift chord")

        // Plain HotkeyCore keeps its default ID sequence.
        var plain = HotkeyCore()
        _ = plain.observe(HotkeyKeys(), at: 0)
        let first = plain.observe(HotkeyKeys(leftOption: true, rightOption: true), at: 0.01)
        check(captures(first).first?.id == 1, "default first ID unchanged")
        // Stress both routing directions: repeats in the other chord remain
        // acknowledgements even when the image becomes ready during that chord.
        for initialChord in [HotkeyChord.options, .shifts] {
            var rapid = DualHotkeyCore(captureTimeout: 45)
            let original = initialChord == .options ? bothOpt : bothShift
            let repeated = initialChord == .options ? bothShift : bothOpt
            _ = rapid.observe(up, at: 100)
            let request = captures(rapid.observe(original, at: 100.01))[0]
            _ = rapid.observe(up, at: 100.02)
            for index in 0..<50 {
                let time = 100.03 + Double(index) * 0.01
                check(rapid.observe(repeated, at: time) ==
                    [.busyRepeat(requestID: request.id, phase: "capturing")],
                    "cross-chord repeat acknowledges only the original capture")
                check(rapid.observe(up, at: time + 0.005).isEmpty,
                      "cross-chord release queues nothing")
            }
            _ = rapid.observe(repeated, at: 101)
            check(rapid.captureSucceeded(requestID: request.id, imageToken: "one-image", at: 101.01).isEmpty,
                  "image completion waits while the other chord is held")
            check(rapid.observe(up, at: 101.02) == [.pasteIntent(request, imageToken: "one-image")],
                  "releasing the other chord yields exactly one paste for the original request")
            _ = rapid.observe(repeated, at: 101.03)
            rapid.appendFinished(requestID: request.id)
            check(rapid.observe(repeated, at: 101.04).isEmpty,
                  "a repeat held across completion cannot turn into a new capture")
            _ = rapid.observe(up, at: 101.05)
            check(captures(rapid.observe(repeated, at: 101.06)).count == 1,
                  "a new physical chord works after full release")
        }
        // Queued press destination (2026-10-28).
        // Burst binding (13:29: press, press, click another app, press, press). The burst's chat for
        // this app is inherited unless input went into that chat app itself.
        let codexPID: pid_t = 101, claudePID: pid_t = 102, safariPID: pid_t = 103
        func binds(_ interventions: Set<pid_t>, target: pid_t, source: Bool = true, observing: Bool = true) -> Bool {
            QueuedDestinationPolicy.binds(sourceAvailable: source, watchObserving: observing,
                                          inputInTargetApp: interventions.contains(target))
        }
        check(binds([], target: codexPID), "press, press: same chat")
        check(binds([safariPID], target: codexPID), "clicked Safari between presses: still the original Codex chat")
        check(binds([claudePID], target: codexPID), "clicked the other chat app (Claude) between Codex presses: still the original Codex chat")
        check(binds([safariPID, claudePID], target: claudePID) == false,
              "input went into Claude itself: its chat may have changed, use its current chat as v21.1")
        check(binds([safariPID], target: claudePID), "Claude presses with a Safari click between: original Claude chat")
        check(!binds([], target: codexPID, source: false), "no earlier chat in this burst for that app: as a first press")
        check(!binds([], target: codexPID, observing: false), "no watch running: nothing proven")
        check(QueuedDestinationPolicy.refocusAttempts == 3 && QueuedDestinationPolicy.foregroundRetriesBeforePaste == 2,
              "bringing the chat back after the user clicks away is bounded")
        check(QueuedDestinationPolicy.outcome(bound: true, sameDestination: true) == .paste, "bound chat still current: paste there")
        check(QueuedDestinationPolicy.outcome(bound: true, sameDestination: false) == .manualPaste,
              "bound chat switched away or gone: never another chat, manual paste")
        check(QueuedDestinationPolicy.outcome(bound: false, sameDestination: false) == .paste,
              "unbound press: its app's current chat, as in v21.1")
        check(QueuedDestinationPolicy.locateAttempts(queued: true) > QueuedDestinationPolicy.locateAttempts(queued: false),
              "queued press retries finding its chat longer")
        check(QueuedDestinationPolicy.locateAttempts(queued: false) == 4, "single press unchanged")
        // Back to the bound chat (option a). Fakes only; counts every raise and sidebar press.
        final class Fake: @unchecked Sendable {
            var boundAfter: Int?; var checks = 0; var raises = 0; var opens = 0
            var raiseFails = false; var openFails = false; var boundAfterRaise = false; var opened = false
            init(boundAfter: Int? = nil) { self.boundAfter = boundAfter }
        }
        func run(_ fake: Fake) -> Bool {
            let done = DispatchSemaphore(value: 0); nonisolated(unsafe) var result = false
            Task.detached {
                result = (try? await QueuedDestinationPolicy.restore(
                    isBound: {
                        fake.checks += 1
                        if fake.boundAfterRaise && fake.raises > 0 { return true }
                        if let n = fake.boundAfter, fake.opened, fake.checks >= n { return true }
                        return fake.boundAfter == 0
                    },
                    raiseWindow: { fake.raises += 1; if fake.raiseFails { throw TargetFailureStub.gone } },
                    openConversation: { fake.opens += 1; if fake.openFails { throw TargetFailureStub.gone }; fake.opened = true },
                    pause: {})) ?? false
                done.signal()
            }
            done.wait(); return result
        }
        do {
            let same = Fake(boundAfter: 0)
            check(run(same) && same.raises == 0 && same.opens == 0, "chat unchanged: no raise, nothing clicked")
            let otherWindow = Fake(); otherWindow.boundAfterRaise = true
            check(run(otherWindow) && otherWindow.raises == 1 && otherWindow.opens == 0,
                  "chat in another window: that window is raised, no sidebar click")
            let sameWindowOtherChat = Fake(boundAfter: 4)
            check(run(sameWindowOtherChat) && sameWindowOtherChat.opens == 1,
                  "same window, other chat (Codex app / Claude): its sidebar item is pressed once, then verified")
            let deleted = Fake(); deleted.openFails = true
            check(!run(deleted) && deleted.opens == 1, "chat deleted or its item ambiguous (identical titles): manual paste")
            let wrongChat = Fake()
            check(!run(wrongChat) && wrongChat.opens == 1, "pressed but the bound chat never appears: manual paste, no second click")
            let closed = Fake(); closed.raiseFails = true
            check(!run(closed) && closed.opens == 0, "its window was closed: manual paste, nothing clicked")
        }
        print("DualHotkeyCore: \(checks) pure checks passed")
    }
}
