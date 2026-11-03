// Run with scripts/test-activation-policy.sh. Policies and the pre-AX abort guard only; no app is contacted.
@main
enum ActivationPolicyTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }
    static func state(running: Bool = true, frontmost: Bool = false, hidden: Bool = false,
                      open: Int = 1, minimized: Int = 0, focusedOnScreen: Bool = false) -> ActivationObservation {
        .init(running: running, frontmost: frontmost, hidden: hidden, openWindows: open,
              minimizedWindows: minimized, focusedWindowOnScreen: focusedOnScreen)
    }

    @MainActor
    static func main() async {
        // Already in front with a usable window: the old path, nothing to do.
        let front = state(frontmost: true, focusedOnScreen: true)
        check(ActivationPolicy.isReady(front), "front target is ready")
        check(ActivationPolicy.plan(front).isEmpty, "front target needs no steps")

        // Frontmost but its window is on another Space / not visible: activate again.
        check(ActivationPolicy.plan(state(frontmost: true)) == [.activate], "front without on-screen window activates")

        // Behind other windows (same Space): just activate.
        check(ActivationPolicy.plan(state(focusedOnScreen: true)) == [.activate], "background target activates")

        // Hidden (Cmd-H): unhide, then activate.
        check(ActivationPolicy.plan(state(hidden: true)) == [.unhide, .activate], "hidden target unhides first")
        check(!ActivationPolicy.isReady(state(frontmost: true, hidden: true, focusedOnScreen: true)),
              "a hidden app is never ready")

        // Every window minimized: restore one, then activate.
        check(ActivationPolicy.plan(state(open: 0, minimized: 2)) == [.unminimize, .activate],
              "all-minimized target restores one window")
        // A visible window exists besides minimized ones: do not restore anything.
        check(ActivationPolicy.plan(state(open: 1, minimized: 1)) == [.activate],
              "minimized extras are left alone")

        // No AX windows (other Space or window closed): activation first, reopen
        // only as a fallback once activation could not settle.
        check(ActivationPolicy.plan(state(open: 0)) == [.activate], "no visible windows activates first")
        check(!ActivationPolicy.plan(state(open: 0)).contains(.reopen), "reopen is never a first step")
        check(ActivationPolicy.needsReopen(after: state(frontmost: true, open: 0)), "still no window → reopen")
        check(!ActivationPolicy.needsReopen(after: state(frontmost: true, open: 1)), "a window exists → no reopen")
        check(!ActivationPolicy.needsReopen(after: state(open: 0, minimized: 1)), "minimized window → no reopen")
        check(!ActivationPolicy.needsReopen(after: front), "ready → no reopen")

        // Not running: launch only.
        let stopped = state(running: false, open: 0)
        check(ActivationPolicy.plan(stopped) == [.launch], "stopped target launches")
        check(!ActivationPolicy.isReady(stopped), "stopped target is not ready")
        check(!ActivationPolicy.needsReopen(after: stopped), "stopped target is not reopened")
        // A duplicate bundle instance is neither safe to select nor stopped.
        var ambiguous = state(frontmost: true, open: 0, focusedOnScreen: true)
        ambiguous.ambiguousRunningApplications = true
        check(!ActivationPolicy.isReady(ambiguous), "duplicate processes never report ready")
        check(ActivationPolicy.plan(ambiguous).isEmpty, "duplicate processes never launch or activate")
        check(!ActivationPolicy.needsReopen(after: ambiguous), "duplicate processes never reopen")

        // AX enumeration order cannot choose one of multiple minimized chats.
        check(ActivationPolicy.restorationIndex(minimizedCount: 0, mainIndex: nil) == nil,
              "no minimized window has no restoration target")
        check(ActivationPolicy.restorationIndex(minimizedCount: 1, mainIndex: nil) == 0,
              "a sole minimized window is unambiguous")
        check(ActivationPolicy.restorationIndex(minimizedCount: 2, mainIndex: nil) == nil,
              "multiple minimized windows without main identity are refused")
        check(ActivationPolicy.restorationIndex(minimizedCount: 2, mainIndex: 1) == 1,
              "restore the identified main window instead of the first enumeration entry")
        check(ActivationPolicy.restorationIndex(minimizedCount: 2, mainIndex: 3) == nil,
              "stale main-window index does not permit a fallback")
        // An interrupted user intent must return before observing/launching an app.
        do {
            let aborted = try await TargetActivator.bringForward(.chatGPT, shouldContinue: { false })
            check(aborted == .failed, "user interruption aborts activation before touching target APIs")
        } catch { fatalError("unexpected activation error: \(error)") }
        let cancelled = Task { @MainActor in
            try await TargetActivator.bringForward(.claude, shouldContinue: {
                fatalError("a cancelled activation must not even consult target intent")
            })
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("cancelled activation unexpectedly completed")
        } catch is CancellationError { checks += 1 }
        catch { fatalError("unexpected cancellation error: \(error)") }
        print("ActivationPolicy: \(checks) pure checks passed")
    }
}
