import AppKit
import ApplicationServices

// Platform code is built, but is not executed by the development agent.
// The user explicitly enables this independent app's event monitor.
//
// 0.7.1: an active (default) session tap instead of a listen-only one. Apple
// gates listen-only keyboard taps behind Input Monitoring but active taps behind
// Accessibility, which pasting already needs; first run is now ONE permission
// and no relaunch. The tap still never consumes or rewrites an event. It runs on
// its own thread so main-thread AX inspections can never stall the user's typing
// or let the system disable the tap. Key state is tracked from the tap's own
// events, so nothing depends on HID polling once it is running.
@MainActor
final class KeyMonitor {
    private var tapThread: KeyTapThread?
    private var generation: UInt64 = 0
    var onChange: ((ModifierSnapshot, Double) -> Void)?
    var onLoss: (() -> Void)?
    static let eventTag: Int64 = 0x4950414453484F54
    static let modifierCodes: Set<CGKeyCode> = [54,55,56,57,58,59,60,61,62,63]
    // Latest snapshot delivered by a running tap; nil while stopped.
    private static var tracked: ModifierSnapshot?

    // allReleased covers every modifier, both Shifts included.
    static func keys() -> HotkeyKeys { modifiers().optionChord }

    static func modifiers() -> ModifierSnapshot { tracked ?? hidSnapshot() }

    nonisolated static func hidSnapshot() -> ModifierSnapshot {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let ordinary = (0..<128).contains { value in
            let code = CGKeyCode(value)
            return !modifierCodes.contains(code) && CGEventSource.keyState(.hidSystemState, key: code)
        }
        return ModifierSnapshot(
            leftOption: CGEventSource.keyState(.hidSystemState, key: 58),
            rightOption: CGEventSource.keyState(.hidSystemState, key: 61),
            leftShift: CGEventSource.keyState(.hidSystemState, key: 56),
            rightShift: CGEventSource.keyState(.hidSystemState, key: 60),
            control: flags.contains(.maskControl),
            command: flags.contains(.maskCommand),
            function: flags.contains(.maskSecondaryFn),
            ordinaryKey: ordinary)
    }

    func start() throws {
        stop()
        guard AXIsProcessTrusted() || CGPreflightListenEventAccess() else { throw TossError.accessibilityPermission }
        let baseline = Self.hidSnapshot()
        let ordinary = Set((0..<128).compactMap { value -> CGKeyCode? in
            let code = CGKeyCode(value)
            return !Self.modifierCodes.contains(code) &&
                CGEventSource.keyState(.hidSystemState, key: code) ? code : nil
        })
        let token = generation
        let thread = KeyTapThread(ordinaryKeys: ordinary, deliver: { [weak self] snapshot, timestamp in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                Self.tracked = snapshot
                self.onChange?(snapshot, timestamp)
            }
        }, lost: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.onLoss?()
            }
        })
        guard thread.startAndWait() else { throw TossError.monitorUnavailable }
        tapThread = thread
        Self.tracked = baseline
    }

    func stop() {
        generation &+= 1 // Queued snapshots from an earlier listener are invalid.
        tapThread?.stop()
        tapThread = nil
        Self.tracked = nil
    }
}

// Owns the event tap and its run loop on a dedicated thread. Its mutable state
// is touched only from that thread (the callback and setup before the run loop).
final class KeyTapThread: Thread, @unchecked Sendable {
    private var ordinaryKeys: Set<CGKeyCode>
    private let deliver: (ModifierSnapshot, Double) -> Void
    private let lost: () -> Void
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private var started = false

    init(ordinaryKeys: Set<CGKeyCode>, deliver: @escaping (ModifierSnapshot, Double) -> Void,
         lost: @escaping () -> Void) {
        self.ordinaryKeys = ordinaryKeys
        self.deliver = deliver
        self.lost = lost
        super.init()
        name = "Toss.keytap"
        qualityOfService = .userInteractive
    }

    func startAndWait() -> Bool {
        start()
        _ = ready.wait(timeout: .now() + 2)
        return started
    }

    func stop() {
        if let runLoop { CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            if let port = self.port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
            self.port = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
        }; CFRunLoopWakeUp(runLoop) }
    }

    override func main() {
        let mask: CGEventMask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(0) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            Unmanaged<KeyTapThread>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            // Never consumes or rewrites any user's key.
            return Unmanaged.passUnretained(event)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Active tap (Accessibility). Listen-only only as a fallback for a
        // machine that has Input Monitoring but not this tap.
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: callback, userInfo: context)
            ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                 eventsOfInterest: mask, callback: callback, userInfo: context)
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            ready.signal(); return
        }
        port = tap
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        started = true
        ready.signal()
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout {
            // Keep listening: re-arm once rather than dropping the hotkey.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        if type == .tapDisabledByUserInput { lost(); return }
        guard event.getIntegerValueField(.eventSourceUserData) != KeyMonitor.eventTag else { return }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if !KeyMonitor.modifierCodes.contains(code) {
            if type == .keyDown { ordinaryKeys.insert(code) }
            if type == .keyUp { ordinaryKeys.remove(code) }
        }
        // IOLLEvent.h device-specific masks distinguish left/right
        // Option (0x20/0x40) and Shift (0x02/0x04); the aggregate
        // .maskAlternate/.maskShift flags cannot do so.
        let raw = event.flags.rawValue
        let snapshot = ModifierSnapshot(
            leftOption: raw & 0x20 != 0,
            rightOption: raw & 0x40 != 0,
            leftShift: raw & 0x02 != 0,
            rightShift: raw & 0x04 != 0,
            control: event.flags.contains(.maskControl),
            command: event.flags.contains(.maskCommand),
            function: event.flags.contains(.maskSecondaryFn),
            ordinaryKey: !ordinaryKeys.isEmpty)
        deliver(snapshot, Double(event.timestamp) / 1_000_000_000)
    }
}

// Injectable so clipboard ownership/recovery can be tested without touching
// the user's general pasteboard or posting events.
@MainActor
protocol ClipboardStore: AnyObject {
    var changeCount: Int { get }
    func snapshot() throws -> [[NSPasteboard.PasteboardType: Data]]
    func clear()
    func write(file: URL) -> Bool
    func write(items: [[NSPasteboard.PasteboardType: Data]]) -> Bool
}

@MainActor
private final class SystemClipboardStore: ClipboardStore {
    private let board = NSPasteboard.general
    var changeCount: Int { board.changeCount }
    func snapshot() throws -> [[NSPasteboard.PasteboardType: Data]] {
        var total = 0
        return try (board.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw TossError.clipboardUnavailable }
                total += data.count
                guard total <= 64 * 1024 * 1024 else { throw TossError.clipboardUnavailable }
                values[type] = data
            }
            return values
        }
    }
    func clear() { board.clearContents() }
    func write(file: URL) -> Bool { board.writeObjects([file as NSURL]) }
    func write(items: [[NSPasteboard.PasteboardType: Data]]) -> Bool {
        let objects = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        return objects.isEmpty || board.writeObjects(objects)
    }
}

@MainActor
final class ClipboardTransaction {
    private let board: any ClipboardStore
    private let previous: [[NSPasteboard.PasteboardType: Data]]
    private var ownedChangeCount: Int?

    init(store: (any ClipboardStore)? = nil) throws {
        let board = store ?? SystemClipboardStore()
        self.board = board
        let initialCount = board.changeCount
        previous = try board.snapshot()
        guard board.changeCount == initialCount else { throw TossError.clipboardChanged }
        ownedChangeCount = initialCount
    }

    private init(board: any ClipboardStore, previous: [[NSPasteboard.PasteboardType: Data]]) {
        self.board = board
        self.previous = previous
        ownedChangeCount = board.changeCount
    }

    // The next keypress never waits for an unconfirmed paste (2026-10-28). It carries
    // the user's original clipboard forward instead of snapshotting the old screenshot, so
    // whichever transaction restores last puts back what the user had copied. A user copy in
    // between ends ownership, and that new copy is snapshotted as usual.
    static func continuing(_ earlier: ClipboardTransaction?,
                           store: (any ClipboardStore)? = nil) throws -> ClipboardTransaction {
        if let earlier, earlier.isStillOwned {
            return ClipboardTransaction(board: earlier.board, previous: earlier.previous)
        }
        return try ClipboardTransaction(store: store)
    }

    var isStillOwned: Bool {
        guard let ownedChangeCount else { return false }
        return board.changeCount == ownedChangeCount
    }

    func publish(file: URL) throws {
        guard isStillOwned else { throw TossError.clipboardChanged }
        board.clear()
        ownedChangeCount = board.changeCount
        // Native file URL; never a pasted path string.
        guard board.write(file: file) else {
            ownedChangeCount = board.changeCount
            restoreIfStillOwned()
            throw TossError.clipboardUnavailable
        }
        ownedChangeCount = board.changeCount
    }

    func validate() throws {
        guard isStillOwned else { throw TossError.clipboardChanged }
    }

    @discardableResult
    func restoreIfStillOwned() -> Bool {
        guard isStillOwned else { return true }
        board.clear()
        let restored = board.write(items: previous)
        // A failed restore must not silently discard the only original snapshot.
        ownedChangeCount = restored ? nil : board.changeCount
        return restored
    }

    // false means keep this transaction: its paste is unconfirmed, so restoring now could let a
    // late Cmd+V paste the old clipboard. The next keypress continues it (see continuing).
    func finish(pastePosted: Bool, consumptionConfirmed: Bool, targetTerminated: Bool) -> Bool {
        guard isStillOwned else { return true } // Preserve a newer user copy.
        guard !pastePosted || consumptionConfirmed || targetTerminated else { return false }
        return restoreIfStillOwned()
    }
}

enum PasteInputPolicy {
    static func canPost(tracked: ModifierSnapshot, live: ModifierSnapshot) -> Bool {
        tracked.optionChord.allReleased && live.optionChord.allReleased
    }
}

@MainActor
final class AppendInteractionWatch {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var intervened = false
    // Which apps the input went to (the window's owner for clicks and scrolls, the front app for
    // keys). A click in Safari does not change the Codex chat; only input in the chat app does.
    private(set) var interventionPIDs: Set<pid_t> = []
    // The first input seen (kind and ms after the watch started), for diagnostics only.
    private(set) var note = "none"
    var isObserving: Bool { globalMonitor != nil && localMonitor != nil }
    private static func kind(_ event: NSEvent) -> String {
        switch event.type {
        case .keyDown: return "key"
        case .scrollWheel: return "scroll"
        default: return "click"
        }
    }
    private var generation: UInt64 = 0

    // Used during every capture and between paste and its readback. No coordinates,
    // characters, key codes or event contents are retained or logged. Modifiers
    // alone do not count: another busy Option chord is simply consumed.
    func start() {
        stop()
        intervened = false
        interventionPIDs = []
        note = "none"
        let token = generation
        let startedAt = ProcessInfo.processInfo.systemUptime
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown,
            .otherMouseDown, .scrollWheel, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.generation == token, event.timestamp >= startedAt else { return }
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != KeyMonitor.eventTag else { return }
            if !self.intervened {
                self.note = String(format: "%@ at %.0f ms", Self.kind(event), (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            }
            self.intervened = true
            if let pid = Self.ownerPID(event) { self.interventionPIDs.insert(pid) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.generation == token, event.timestamp >= startedAt else { return event }
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != KeyMonitor.eventTag else { return event }
            if !self.intervened {
                self.note = String(format: "%@ at %.0f ms", Self.kind(event), (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            }
            self.intervened = true
            self.interventionPIDs.insert(ProcessInfo.processInfo.processIdentifier)
            return event
        }
    }

    // Owner of the window a click or scroll hit; the front app for a key. Only the pid is kept.
    private static func ownerPID(_ event: NSEvent) -> pid_t? {
        if event.type != .keyDown, event.windowNumber > 0,
           let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(event.windowNumber)) as? [[String: Any]],
           let pid = info.first?[kCGWindowOwnerPID as String] as? pid_t {
            return pid
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func stop() {
        generation &+= 1
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

@MainActor
enum PasteKeystroke {
    static func postOnce(to pid: pid_t) throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw TossError.accessibilityPermission }
        // AX work can block main-queue delivery of the tap's tracked snapshot.
        guard PasteInputPolicy.canPost(tracked: KeyMonitor.modifiers(), live: KeyMonitor.hidSnapshot()) else {
            throw TossError.keysStillPressed
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw TossError.foregroundChanged }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw TossError.eventUnavailable
        }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: KeyMonitor.eventTag)
        }
        // Exactly Command-V down/up, scoped to this process. No Enter, Tab,
        // Command-A, typing, mouse click, submit or retry exists in this path.
        down.postToPid(pid)
        up.postToPid(pid)
    }
}
