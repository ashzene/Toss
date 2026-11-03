import AppKit
import ApplicationServices

// 0.7.1: the chord works while another app is in front. Before the strict
// locate() runs, the chord's target app is brought forward the way a Dock click
// would: unhide, un-minimize one window, activate (the system switches to the
// Space that holds the window), and only when no window is reachable at all,
// a reopen event. Nothing here clicks, types, switches chats or touches a draft;
// after activation the unchanged lease checks still decide which chat (the app's
// own focused window) receives the image, or refuse.

struct ActivationObservation: Equatable {
    var running: Bool
    var frontmost: Bool
    var hidden: Bool
    // Standard windows the app reports through AX (current Space only).
    var openWindows: Int
    var minimizedWindows: Int
    // The app's AX focused window is a standard, unminimized, on-screen window.
    var focusedWindowOnScreen: Bool
    // More than one matching process cannot be treated as a stopped app.
    var ambiguousRunningApplications = false
}

enum ActivationStep: Equatable {
    case launch, unhide, unminimize, activate, reopen
}

// Pure, separately testable policy. It does not contact an application.
enum ActivationPolicy {
    static func isReady(_ state: ActivationObservation) -> Bool {
        state.running && !state.ambiguousRunningApplications && state.frontmost && !state.hidden && state.focusedWindowOnScreen
    }

    // First pass. `.reopen` is never planned here: a window on another Space is
    // invisible to AX until activation switches there, so the reopen event (which
    // may create a window) is only a fallback after activation could not settle.
    static func plan(_ state: ActivationObservation) -> [ActivationStep] {
        guard !state.ambiguousRunningApplications else { return [] }
        guard state.running else { return [.launch] }
        guard !isReady(state) else { return [] }
        var steps: [ActivationStep] = []
        if state.hidden { steps.append(.unhide) }
        if state.openWindows == 0 && state.minimizedWindows > 0 { steps.append(.unminimize) }
        steps.append(.activate)
        return steps
    }

    static func needsReopen(after state: ActivationObservation) -> Bool {
        state.running && !state.ambiguousRunningApplications && !isReady(state) &&
            state.openWindows == 0 && state.minimizedWindows == 0
    }

    // AXWindows ordering is not a user preference. With multiple minimized
    // windows, only the app's identified main window is safe to restore.
    static func restorationIndex(minimizedCount: Int, mainIndex: Int?) -> Int? {
        guard minimizedCount > 0 else { return nil }
        if let mainIndex, (0..<minimizedCount).contains(mainIndex) { return mainIndex }
        return minimizedCount == 1 ? 0 : nil
    }
}

enum ActivationOutcome: Equatable {
    // Target was already the frontmost app with a usable window.
    case alreadyFront
    // Target is now frontmost with a usable window.
    case activated
    // Target was not running and has been asked to launch; the user presses again.
    case launched
    case failed
}

@MainActor
enum TargetActivator {
    static func observe(_ kind: TargetKind) -> ActivationObservation {
        let apps = runningApplications(kind)
        guard apps.count == 1, let app = apps.first else {
            if apps.count > 1 {
                return .init(running: true, frontmost: false, hidden: false, openWindows: 0,
                             minimizedWindows: 0, focusedWindowOnScreen: false,
                             ambiguousRunningApplications: true)
            }
            return .init(running: false, frontmost: false, hidden: false, openWindows: 0,
                         minimizedWindows: 0, focusedWindowOnScreen: false)
        }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 0.1)
        let windows = standardWindows(appAX)
        let minimized = windows.filter { bool($0, kAXMinimizedAttribute) == true }.count
        var focusedOnScreen = false
        if let focused = element(appAX, kAXFocusedWindowAttribute),
           string(focused, kAXRoleAttribute) == kAXWindowRole,
           bool(focused, kAXMinimizedAttribute) != true, let rect = frame(focused) {
            focusedOnScreen = onScreenBounds(pid: app.processIdentifier).contains {
                abs($0.minX - rect.minX) < 2 && abs($0.minY - rect.minY) < 2 &&
                abs($0.width - rect.width) < 2 && abs($0.height - rect.height) < 2
            }
        }
        return .init(running: true,
                     frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                     hidden: app.isHidden, openWindows: windows.count - minimized,
                     minimizedWindows: minimized, focusedWindowOnScreen: focusedOnScreen)
    }

    static func bringForward(_ kind: TargetKind,
                             shouldContinue: () -> Bool = { true }) async throws -> ActivationOutcome {
        try Task.checkCancellation()
        guard shouldContinue() else { return .failed }
        let initial = observe(kind)
        guard !initial.ambiguousRunningApplications else { return .failed }
        let steps = ActivationPolicy.plan(initial)
        if steps.isEmpty { return .alreadyFront }
        if steps == [.launch] {
            guard shouldContinue() else { return .failed }
            let launched = await launch(kind)
            try Task.checkCancellation()
            return launched && shouldContinue() ? .launched : .failed
        }
        guard let app = runningApplication(kind) else { return .failed }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 0.25)
        for step in steps {
            try Task.checkCancellation()
            guard shouldContinue() else { return .failed }
            switch step {
            case .unhide: app.unhide()
            case .unminimize: guard unminimizeOneWindow(appAX) else { return .failed }
            case .activate: activate(app, appAX)
            case .launch, .reopen: break
            }
        }
        if try await waitUntilReady(kind, app: app, appAX: appAX, seconds: 1.5, shouldContinue: shouldContinue) { return .activated }
        guard shouldContinue(), ActivationPolicy.needsReopen(after: observe(kind)) else { return .failed }
        // Same event as clicking the Dock icon: Electron shows (or recreates) its window.
        reopen(app)
        return try await waitUntilReady(kind, app: app, appAX: appAX, seconds: 2.0, shouldContinue: shouldContinue) ? .activated : .failed
    }

    private static func waitUntilReady(_ kind: TargetKind, app: NSRunningApplication, appAX: AXUIElement,
                                       seconds: Double, shouldContinue: () -> Bool) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var nudged = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard shouldContinue(), !app.isTerminated else { return false }
            if ActivationPolicy.isReady(observe(kind)) {
                // No fixed settle delay (was 80 ms): locate() is the authority and
                // locateAfterActivation() re-reads a not-yet-published tree briefly.
                return true
            }
            // Cooperative activation (macOS 14+) may decline a request from a
            // background agent; AXFrontmost is the accessibility equivalent.
            if !nudged, ProcessInfo.processInfo.systemUptime > deadline - seconds + 0.25 {
                nudged = true
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    AXUIElementSetAttributeValue(appAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                }
                if let main = element(appAX, kAXMainWindowAttribute) {
                    AXUIElementPerformAction(main, kAXRaiseAction as CFString)
                }
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    private static func activate(_ app: NSRunningApplication, _ appAX: AXUIElement) {
        _ = requestFront(app, appAX)
    }

    // macOS 14+ cooperative activation lets the system decline activate() from a
    // background agent (0.5.1 diagnostics: focusFailed ~50 ms after every chord).
    // Setting AXFrontmost through accessibility is honoured for trusted clients.
    static func requestFront(_ app: NSRunningApplication, _ appAX: AXUIElement? = nil) -> Bool {
        if app.activate(options: []) { return true }
        let element = appAX ?? AXUIElementCreateApplication(app.processIdentifier)
        if appAX == nil { AXUIElementSetMessagingTimeout(element, 0.25) }
        return AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
    }

    private static func unminimizeOneWindow(_ appAX: AXUIElement) -> Bool {
        let minimized = standardWindows(appAX).filter { bool($0, kAXMinimizedAttribute) == true }
        let mainIndex = element(appAX, kAXMainWindowAttribute).flatMap { main in
            minimized.firstIndex { CFEqual($0, main) }
        }
        guard let index = ActivationPolicy.restorationIndex(minimizedCount: minimized.count,
                                                            mainIndex: mainIndex) else { return false }
        let window = minimized[index]
        guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            == .success else { return false }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return true
    }

    private static func launch(_ kind: TargetKind) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }

    private static func reopen(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    private static func runningApplications(_ kind: TargetKind) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: kind.bundleID)
            .filter { !$0.isTerminated }
    }

    private static func runningApplication(_ kind: TargetKind) -> NSRunningApplication? {
        let apps = runningApplications(kind)
        return apps.count == 1 ? apps[0] : nil
    }

    // MARK: - AX helpers (bounded by the app element's messaging timeout)

    private static func standardWindows(_ appAX: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.filter {
            string($0, kAXRoleAttribute) == kAXWindowRole &&
            string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
        }
    }

    private static func onScreenBounds(pid: pid_t) -> [CGRect] {
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return [] }
        return records.compactMap { record in
            guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let raw = record[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  rect.width > 0, rect.height > 0 else { return nil }
            return rect
        }
    }

    private static func element(_ base: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(base, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ base: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(base, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ base: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(base, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
