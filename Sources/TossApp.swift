import AppKit
import ApplicationServices
import CryptoKit
import Network

struct TossConfiguration: Decodable {
    let python: String
    let state_dir: String
}

@MainActor
final class TossDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var statusItem: NSMenuItem!
    private var menuStatus: TossStatusController?
    private var lastConnectionFailure: String?
    private var toggleItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private var windowToggle: NSButton?
    private var loginToggle: SettingsSwitch?
    private var toastToggle: SettingsSwitch?
    private var loginMenuItem: NSMenuItem?
    private var startupStatus: NSTextField?
    private var startupChangeTask: Task<Void, Never>?
    private let startup: StartupController
    private var uninstallSheet: UninstallSheet?
    private var uninstaller: UninstallController?
    private var uninstalling = false

    override convenience init() { self.init(startup: StartupController()) }
    init(startup: StartupController) { self.startup = startup; super.init() }
    private var permissionStatus: NSTextField?
    private var permissionHint: NSTextField?
    private var diagnosticStatus: NSTextField?
    private var diagnosticWindow: NSWindow?
    private var diagnosticText: NSTextView?
    private let logExportQueue = DispatchQueue(label: "Toss.log-export", qos: .utility)
    private let logExportNotice = LogExportNotice()
    private var exportingLogs = false
    private var diagnosticEvents: [[String: Any]] = []
    // Connection-status changes keep their own ring, so idle reconnect attempts
    // never push the last keypress's stages out of last-run.json.
    private var connectionEvents: [[String: Any]] = []
    private var diagnosticRequestStartedAt: Double?
    // The keypress in progress, written to capture-history.jsonl when it ends.
    private var captureRecord: CaptureRecord?
    private var lastCaptureResult: TossCaptureResult?
    private lazy var captureHistory = CaptureHistory(url: base.appendingPathComponent("capture-history.jsonl"))
    private let setupWizard = SetupWizard()
    private var pairedDevice = PairedDevicesState()
    // App-wide copy can read pairedDeviceClass?.displayName / .osName in one line.
    var pairedDeviceClass: DeviceClass? { pairedDevice.primary }
    var pairedDeviceClasses: Set<DeviceClass> { pairedDevice.classes }
    // Visible text names the device being set up, else the paired one (DeviceCopy.swift).
    private var setupDeviceClass: DeviceClass?
    // The guide opened to set up a device: it may be the other one, so it names no device until one is plugged in.
    private var guideAwaitsDevice = false
    private var captureDeviceClass: DeviceClass? {
        core.activeRequestID.flatMap { selectedDeviceClass(requestID: $0) }
    }
    private func updateDeviceCopy() {
        DeviceCopy.bothPaired = pairedDeviceClasses.count == 2
        DeviceCopy.deviceClass = (setupDeviceClass ?? captureDeviceClass ?? (guideAwaitsDevice ? nil : pairedDeviceClass))?.rawValue
    }
    private var setupStatus: NSTextField?
    private var setupButtons: [NSButton] = []
    private var settingsStack: NSStackView?
    private var settingsState: SettingsStatus?
    private var pairState: SettingsStatus?
    private var accessState: SettingsStatus?
    private var accessButton: NSButton?
    private var networkState: SettingsStatus?
    private var networkDetail: NSTextField?
    // The notes under the two shortcuts: with an iPad and an iPhone paired they add "twice for iPhone".
    private var shortcutNotes: [NSTextField] = []
    private var networkButton: NSButton?
    private var settingsMore: NSMenu?
    private var checkMenuItem: NSMenuItem?
    private var forgetMenuItem: NSMenuItem?
    private var lastSetupCode = "not_run"
    private var setupDeviceHash: String?
    private var setupPrompt: NSAlert?
    private var setupAutoStarted = false
    private var onboarding: OnboardingController?
    private var permissionTimer: Timer?
    private var workerWatchdog: Timer?
    private var pathMonitor: NWPathMonitor?
    private var pathUpdates = 0
    private var networkAvailable: Bool?
    private var networkRewarm: DispatchWorkItem?
    private var interfacePrepared = false
    private var initialInterfaceShown = false
    private let monitor = KeyMonitor()
    private let chatGPTTarget = StrictTarget()
    private let claudeTarget = ClaudeTarget()
    // Target of the current or most recent transaction; diagnostics follow it.
    private var targetKind: TargetKind = .chatGPT
    private var target: ChatTarget { targetFor(targetKind) }
    // Both Options → ChatGPT/Codex, both Shifts → Claude; one transaction at a time.
    private var core = DualHotkeyCore(captureTimeout: 45, imageLifetime: 10, tapSelectionEnabled: true)
    // Wakes the iPad's Wi-Fi from the first chord key; never part of detection.
    private let deviceWakers: [DeviceClass: IPadWaker] = [.iPad: IPadWaker(), .iPhone: IPadWaker()]
    private var iPadWaker: IPadWaker { deviceWakers[activeDeviceClass]! }
    private let sighter = AttachmentSighter()
    private var predictedSlot: CGRect?
    private var predictionNote = "-"
    private var appendInteractionNote = "-"   // user input between Cmd+V and the readback, if any
    private var slotMemory: AttachmentSighting.SlotMemory?   // loaded before Cmd+V
    private var firstTileRaw: CGRect?                        // the new tile as first sighted
    private let grower = AttachmentSighter()
    private var growthNote = "-"

    // The frame the landing copy covers: the tile as it will be once grown (remembered growth),
    // plus Claude's outset; never toward the row above.
    private func landingFrame(_ tile: CGRect, claude: Bool, tiles: [CGRect]) -> CGRect {
        let grown = AttachmentSighting.grown(tile, memory: slotMemory)
        return CaptureTileLook.coverFrame(grown, claude: claude, pointer: CaptureTileLook.pointerAX(),
                                          gapAbove: AttachmentSighting.gapAbove(grown, tiles: tiles))
    }
    private var prePaste: (composer: CGRect, tiles: [CGRect])?   // read before Cmd+V, for SlotMemory
    private var earlyLandingNote = "off"
    private var keepAliveCheck: Timer?
    private var screensAsleep = false
    private(set) var keepAliveState = "off-disabled"
    private var lastKeys = ModifierSnapshot()
    private var timer: Timer?
    private var enabled = false
    private let captureWorkers: [DeviceClass: CaptureWorker] = [.iPad: CaptureWorker(wifiHedgingEnabled: false), .iPhone: CaptureWorker(wifiHedgingEnabled: false)]
    private var devicePressRouting = DevicePressRouting()
    private var activeDeviceClass: DeviceClass {
        transaction?.deviceClass ?? earlyCapture?.deviceClass ??
            (core.activeRequestID.map { selectedDeviceClass(requestID: $0) } ?? pairedDeviceClass) ?? .iPad
    }
    private var captureWorker: CaptureWorker { captureWorkers[activeDeviceClass]! }
    private var anyWorkerBusy: Bool { captureWorkers.values.contains { $0.isBusy } }
    // The keys choose the device: one press iPad, two presses iPhone. USB only decides the route.
    // A connected, unlocked device can take either press while the other is locked or offline.
    private func deviceThatIsOn(_ wanted: DeviceClass) -> DeviceClass {
        devicePressRouting.device(wanted: wanted, paired: pairedDeviceClasses,
            closed: Set(captureWorkers.filter { $0.value.deviceLocked == true }.keys),
            ready: Set(captureWorkers.filter { $0.value.connectionStatus.state == .ready }.keys),
            at: ProcessInfo.processInfo.systemUptime)
    }
    private func lockedAlternate(for wanted: DeviceClass) -> DeviceClass? {
        devicePressRouting.lockedAlternate(for: wanted, paired: pairedDeviceClasses,
            closed: Set(captureWorkers.filter { $0.value.deviceLocked == true }.keys),
            ready: Set(captureWorkers.filter { $0.value.connectionStatus.state == .ready }.keys),
            at: ProcessInfo.processInfo.systemUptime)
    }
    private var singlePressDevice: DeviceClass? { pairedDeviceClass.map(deviceThatIsOn) }
    private var doublePressDevice: DeviceClass { deviceThatIsOn(.iPhone) }
    private func selectedDeviceClass(requestID: UInt64) -> DeviceClass? {
        capturePipeline.delivering?.deviceClass ?? (core.selectsSecondary(requestID: requestID) ? doublePressDevice : singlePressDevice)
    }
    private func selectedDeviceClass(pressedAt: Double) -> DeviceClass? {
        capturePipeline.press(at: pressedAt)?.deviceClass ?? (core.selectsSecondary(pressedAt: pressedAt) ? doublePressDevice : singlePressDevice)
    }
    private func stopWorkers() { captureWorkers.values.forEach { $0.stop() } }
    private func prepareWorkers(_ config: TossConfiguration) throws {
        for kind in DeviceClass.allCases where pairedDeviceClasses.contains(kind) {
            if let directory = pairedDevice.directories[kind] { deviceWakers[kind]?.useStateDirectory(directory) }
            if captureWorkers[kind]?.isBusy == false {
                try captureWorkers[kind]?.prepare(configuration: workerConfiguration(config, deviceClass: kind))
            }
        }
    }
    private var capturePipeline = DeviceCapturePipeline()
    private var chordDetector = CaptureChordDetector()
    private var deviceGesture = DeviceCaptureGesture()
    private var deferredDeviceSelection: (chord: HotkeyChord, at: Double, lease: (any ChatLease)?)?
    private var blackFramePresses: Set<Double> = []
    private var usbDropNotice = USBDropNotice()
    private var usbDropChecks: Set<DeviceClass> = []
    private var pipelineCaptures: [UInt64: EarlyCapture] = [:]
    private var pipelineProgress: [String: (received: Double, expected: Double)] = [:]
    private var slowPipelineIDs: Set<String> = []
    private var deliveryBindingMissing = false
    private var manualDeliveryPaused = false
    private var deliveryCaptureID: String?
    private var hasActiveWork: Bool { core.isBusy || capturePipeline.isBusy }
    private let captureAnimation = CaptureAnimation()
    private let appendInteraction = AppendInteractionWatch()
    private let newDraftInteraction = AppendInteractionWatch()
    private var backendTimings: [String: Double] = [:]
    private var connectionReused: Bool?
    private var successSounds: [SuccessSound: NSSound] = [:]
    private var lastSuccessSound: SuccessSound?
    private var lastSuccessSoundBytes: Int?
    // Cues start here, not on the main thread: starting one costs 11-30 ms, which must
    // not delay the jelly that covers the new attachment.
    private let cueQueue = DispatchQueue(label: "Toss.cues", qos: .userInteractive)
    private var failureSound: NSSound?
    private let toastPreferences = ToastPreferences()
    private var appendTask: Task<Void, Never>?
    private var enableTask: Task<Void, Never>?
    private var enableGeneration: UInt64 = 0
    // Turn On was clicked with no target running; the restore it waits for
    // then counts as that click (first-enable login registration, visible errors).
    private var pendingUserEnable = false
    // Why the user's last Turn On failed, for the one-line summary; nil otherwise.
    private var enableFailureReason: String?
    private var transaction: Transaction?
    // Do not lose the original clipboard, or publish another screenshot over an
    // event which the target may not yet have consumed.
    private var pendingClipboard: (clipboard: ClipboardTransaction, lease: any ChatLease,
                                   kind: TargetKind, filename: String, safeToRestore: Bool)?
    // An unconfirmed paste's saved clipboard, handed to the next keypress's paste.
    private var inheritedClipboard: ClipboardTransaction?
    // Bringing the target forward before its lease exists (0.7.1).
    private var activationTask: (id: UInt64, task: Task<Void, Never>)?
    // The iPad screenshot (~0.7 s) runs while the window switch and locate run;
    // its result waits here until the lease exists. Discarded on any failure.
    private struct EarlyCapture {
        let id: UInt64
        let uuid: String
        let image: URL
        let deviceClass: DeviceClass
        var result: (data: Data, exitCode: Int32)?
        var receivedAt: Double?
        // A prefetched failure ended its waiting batch when it arrived. Presses made
        // afterwards are new attempts and must not be dropped when its toast is shown.
        var queueFailureHandled = false
    }
    private var earlyCapture: EarlyCapture?
    private var earlyTargetFailure: (request: HotkeyRequest, error: Error)?
    private var slowCaptureID: String?
    // The next queued press's screenshot, requested as soon as the worker is free (usually while
    // the previous toss is still pasting), so that press only has to find its chat and paste.
    // id 0 until its request starts; pressedAt matches HotkeyRequest.startedAt then.
    private var queuedPrefetch: (capture: EarlyCapture, pressedAt: Double, arrivedAt: Double?)?
    private var prefetchRequest: HotkeyRequest?
    // When an adopted prefetched screenshot arrived (its receipt must still be ≤ 5 s old when used).
    private var adoptedPrefetchArrivedAt: Double?
    // The last Cmd+V whose attachment was never confirmed; see the wait before publish.
    private var unconfirmedPasteAt: Double?
    private var lastPastePostedAt: Double?
    // Whether the last confirmed toss's tile has stopped growing (see startQueuedPress).
    private var landingSettle = AttachmentSighting.LandingSettleGate()
    // Queued presses (Ashley 2026-10-28: 「就在原来的地方贴」), keyed by press time: the chat the
    // press was made in, when it is provably the running toss's chat (same app, and no click,
    // scroll or typing since that chat was checked). Taken from memory; no AX read on the key event.
    private var queuedBindings: [Double: any ChatLease] = [:]
    // Per hotkey, the chat its presses go to while presses keep queuing (a burst); cleared when the
    // queue has run empty, so the first press of a new burst targets as usual.
    private var burstLeases: [HotkeyChord: any ChatLease] = [:]
    // Set by startQueuedPress for the startCapture it triggers.
    private var startingQueuedPress = false
    // The early request of a keypress that already ended (see discardEarlyCapture). On a slow
    // link it can still occupy the worker when the next key arrives; that key must not then
    // fail as "busy" (2026-10-24 16:46: it silently hung for 45 s).
    private var abandonedCaptureIDs: [DeviceClass: String] = [:]
    // Focuses the leased composer while the iPad screenshot is in flight, so the
    // paste step finds it focused already. Focus only; every paste check stays.
    private var earlyFocusTask: (id: UInt64, task: Task<Void, Never>)?
    private var lastStatus = L("Disabled", "已关闭")
    private var lastCode = "not_started"
    private var failureCategory = "none"
    private var backendReason = "none"
    private var busyRepeatsTotal = 0
    private var ignoreKeyboardEventsThrough: Double = 0
    private var sleeping = false
    private let fm = FileManager.default
    private let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Toss", isDirectory: true)
    private let cache = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Toss/Captures", isDirectory: true)
    private struct Transaction {
        let id: UInt64
        let uuid: String
        let lease: any ChatLease
        let kind: TargetKind
        let image: URL
        let deviceClass: DeviceClass
        var clipboard: ClipboardTransaction?
        var pastePosted = false
        var appendConfirmed = false
        var pasteConsumptionConfirmed = false
        var waitedForKeys = false
        var receipt: CaptureReceipt?
        var receivedAt: Double?
        // The original chat could not take the paste: the screenshot is left on the clipboard.
        var leftForManualPaste = false
        // A queued press whose chat is no longer the one it was pressed in (see queuedBindings):
        // never pasted elsewhere; it takes the manual-paste path instead.
        var destinationChanged = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareInterface()
        DispatchQueue.main.async { [weak self] in self?.showInitialInterface() }
    }

    // MARK: - Install, permissions and auto-enable (no manual steps)

    private var runningFromDiskImage: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    // Replaces 安装.command: copy to Applications and remove the download
    // quarantine (else macOS blocks the bundled runtime). Asks once; macOS shows
    // its own password window only when Applications needs an administrator.
    // Returns true when this instance is about to quit (relaunch or declined).
    private func installIfNeeded() -> Bool {
        let fromImage = runningFromDiskImage
        guard fromImage || runtimeQuarantined else { return false }
        let alert = NSAlert()
        alert.messageText = fromImage ? L("Install Toss", "安装 Toss") : L("Finish Installing Toss", "完成安装 Toss")
        alert.informativeText = (fromImage ? L("Toss and its menu bar status icon will be installed together in Applications. ", "Toss 和它的菜单栏图标会一起装进「应用程序」。") : "") +
            L("This test build is not notarized by Apple. It needs to remove its download quarantine flag so the bundled runtime can run. This applies only to Toss.\nIf administrator access is needed, macOS will ask for your Mac password.", "这个测试版没有经过 Apple 公证，需要去掉下载时加上的隔离标记，里面的运行环境才能启动。只影响 Toss。\n如果需要管理员权限，macOS 会让你输入 Mac 密码。")
        alert.addButton(withTitle: fromImage ? L("Install and Open", "安装并打开") : L("Continue", "继续"))
        alert.addButton(withTitle: L("Quit", "退出"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return true }
        if !fromImage {
            let bundle = Bundle.main.bundlePath
            if !runShell("/usr/bin/xattr -dr com.apple.quarantine \"$0\"", [bundle], admin: false) {
                _ = runShell("/usr/bin/xattr -dr com.apple.quarantine \"$0\"", [bundle], admin: true)
            }
            if runtimeQuarantined {
                showAlert(L("Installation Incomplete", "安装没有完成"), L("The quarantine flag could not be removed. Move Toss to Applications and reopen it.", "隔离标记没能去掉。把 Toss 移到「应用程序」再重新打开。"))
            }
            return false
        }
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where other != NSRunningApplication.current { other.terminate() }
        // $0 source, $1 destination, $2 Trash folder, $3 owner uid.
        // Replace only the current Toss destination.
        let script = "set -e; if [ -e \"$1\" ]; then mv \"$1\" \"$2/Toss Previous $(date +%Y%m%d-%H%M%S).app\"; fi; " +
            "/usr/bin/ditto \"$0\" \"$1\"; /usr/bin/xattr -dr com.apple.quarantine \"$1\"; /usr/sbin/chown -R \"$3\" \"$1\""
        let source = Bundle.main.bundlePath
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        let uid = String(getuid())
        var destination = "/Applications/Toss.app"
        var installed = fm.isWritableFile(atPath: "/Applications") &&
            runShell(script, [source, destination, trash, uid], admin: false)
        if !installed { installed = runShell(script, [source, destination, trash, uid], admin: true) }
        if !installed {
            // Password declined: a per-user install needs no administrator.
            let personal = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            try? fm.createDirectory(at: personal, withIntermediateDirectories: true)
            destination = personal.appendingPathComponent("Toss.app").path
            installed = runShell(script, [source, destination, trash, uid], admin: false)
        }
        guard installed else {
            showAlert(L("Installation Failed", "安装失败"), L("Drag Toss into Applications, then open it from there.", "把 Toss 拖进「应用程序」，再从那里打开。"))
            NSApp.terminate(nil)
            return true
        }
        relaunch(at: destination, showSetup: true)
        return true
    }

    // An older copy still running (e.g. 0.5.1 started at login from
    // ~/Applications) would answer the same chords and fail them first.
    private func retireOtherInstances() {
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where other != NSRunningApplication.current { other.terminate() }
    }

    @discardableResult
    private func runShell(_ script: String, _ arguments: [String], admin: Bool) -> Bool {
        if admin {
            func literal(_ text: String) -> String {
                "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            let command = (["/bin/sh", "-c", script] + arguments).map { "quoted form of " + literal($0) }
                .joined(separator: " & \" \" & ")
            var error: NSDictionary?
            let source = "do shell script " + command + " with administrator privileges"
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            return error == nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func relaunch(at path: String = Bundle.main.bundlePath, showSetup: Bool = false) {
        guard !uninstalling else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"" + (showSetup ? " --args --show-setup" : ""), path]
        try? process.run()
        stop(reason: L("Reopening…", "正在重新打开…"))
        NSApp.terminate(nil)
    }

    private var permissionsReady: Bool {
        #if TOSS_RENDER
        if let ready = RenderState.permissions { return ready }
        #endif
        return AXIsProcessTrusted() && CGPreflightPostEventAccess()
    }

    // 0.7.1: Accessibility is the only permission (the key tap is an active
    // tap; see KeyMonitor). One system toggle + Touch ID, no relaunch.
    private func requestMissingPermissions() {
        if !permissionsReady { requestAccessibility() }
        startPermissionWatch()
    }

    private func startPermissionWatch() {
        guard permissionTimer == nil, !permissionsReady else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.permissionTick() }
        }
    }

    private func permissionTick() {
        guard !uninstalling else { return }
        logPermissionCheck()
        checkGrantFromFreshProcess()
        refreshPermissions()
        guard permissionsReady else { return }
        permissionTimer?.invalidate(); permissionTimer = nil
        permissionHint?.stringValue = ""
        // Bring our window back over System Settings for the next step.
        if let onboarding, onboarding.isVisible {
            onboarding.setAccessibility(true)
            NSApp.activate(ignoringOtherApps: true); onboarding.window.makeKeyAndOrderFront(nil)
        } else if settingsWindow?.isVisible == true { NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil) }
        autoEnableIfFirstRun()
    }
    private var lastPermissionStep = "none"
    private var askedPermissionThisLaunch = false

    // First run only: once paired and permitted, start listening without asking
    // for another click. A user who explicitly disabled it stays disabled.
    private func autoEnableIfFirstRun() {
        guard !uninstalling else { return }
        guard hasPairing, permissionsReady, !enabled, enableTask == nil,
              !startup.desiredEnabled, !startup.firstEnableDone else { return }
        if runningTargetKinds().isEmpty {
            startup.rememberEnabled(true)
            _ = startup.registerAtUserEnable()
            refreshStartupUI() // the login row shows its own state; no extra grey lines
            restoreIfPossible()
        } else {
            beginEnable(userInitiated: true)
        }
    }

    private func afterSettingsShown() {
        guard !uninstalling else { return }
        // While the onboarding is open it owns pairing and the Accessibility prompt.
        guard onboarding?.isVisible != true else { return }
        if !permissionsReady && !askedPermissionThisLaunch {
            askedPermissionThisLaunch = true
            requestMissingPermissions()
        }
        if !hasPairing {
            if !setupAutoStarted && !setupWizard.isRunning && !runtimeQuarantined {
                setupAutoStarted = true
                startSetup(action: "auto")
            }
        } else if permissionsReady {
            autoEnableIfFirstRun()
        }
        if !permissionsReady { startPermissionWatch() }
    }

    // A changed network invalidates the old route at once; reconnect now rather
    // than waiting for TCP keepalive. Connection only, never a capture.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            DispatchQueue.main.async { [weak self] in
                self?.networkAvailable = available
                self?.refreshMenuStatus()
                if available { self?.networkChanged() }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    private func networkChanged() {
        pathUpdates += 1
        guard pathUpdates > 1 else { return } // The first update is the current state.
        networkRewarm?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled, !self.sleeping, !self.hasActiveWork, !self.anyWorkerBusy,
                  self.transaction == nil, !self.setupWizard.isRunning else { return }
            self.captureWorkers.values.forEach { $0.invalidateWiFi() }
            self.rewarmWorker(after: 0)
        }
        networkRewarm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // Build before entering the event loop as well as from the launch callback.
    // Idempotence avoids duplicate menu items or windows on either path.
    func prepareInterface() {
        guard !interfacePrepared else { return }
        interfacePrepared = true
        refreshPairedDevice()
        startKeepAliveCheck()
        // Load once without playing. Never put audio I/O in the capture path.
        // Toss's own cues (Assets/Sounds, Ashley's picks); there is no Codex fallback.
        func sound(_ name: String) -> NSSound? {
            Bundle.main.url(forResource: name, withExtension: "aiff").flatMap { NSSound(contentsOf: $0, byReference: false) }
        }
        for tier in SuccessSound.allCases {
            successSounds[tier] = sound(tier.rawValue)
        }
        failureSound = sound("Toss-Failure")
        NSApp.setActivationPolicy(startup.shouldShowInitialSettings ? .regular : .accessory)
        // First launch: start near the right edge so a crowded bar doesn't push the icon under the
        // notch. A position the user dragged is never overridden.
        if UserDefaults.standard.object(forKey: MenuIconPolicy.positionKey) == nil {
            UserDefaults.standard.set(Double(MenuIconPolicy.defaultPosition), forKey: MenuIconPolicy.positionKey)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        _ = add(menu, L("Settings…", "设置…"), #selector(showSettings))
        menu.addItem(.separator())
        statusItem = NSMenuItem(title: L("Status: Disabled", "状态：已关闭"), action: nil, keyEquivalent: "")
        menu.addItem(statusItem)
        menu.addItem(.separator())
        toggleItem = add(menu, L("Enable Shortcuts", "打开快捷键"), #selector(toggle))
        loginMenuItem = add(menu, L("Launch at Login", "登录时打开"), #selector(toggleLogin))
        _ = add(menu, L("Check Current Target · No Paste", "检查当前目标 · 不粘贴"), #selector(checkTarget))
        _ = add(menu, L("Cancel Capture", "取消截图"), #selector(cancelCurrent))
        menu.addItem(.separator())
        _ = add(menu, L("Check Connection", "检查连接"), #selector(runSetup))
        _ = add(menu, L("Allow Accessibility Access…", "允许辅助功能…"), #selector(requestAccessibility))
        _ = add(menu, L("Installation and Usage Guide", "安装和使用说明"), #selector(showInstructions))
        _ = add(menu, L("View Diagnostics", "查看诊断信息"), #selector(showDiagnostics))
        _ = add(menu, L("Copy Diagnostics", "复制诊断信息"), #selector(copyDiagnostics))
        menu.addItem(.separator())
        _ = add(menu, L("Quit", "退出"), #selector(quit))
        menuStatus = makeStatusController(item: item, menu: menu)
        for (kind, worker) in captureWorkers {
            worker.onConnectionChange = { [weak self] status in
                guard let self else { return }
                self.devicePressRouting.observe(kind, unavailable: status.state != .ready && status.state != .notChecked,
                                                at: ProcessInfo.processInfo.systemUptime)
                if kind == self.activeDeviceClass {
                    if status.state == .ready || status.state == .notChecked { self.lastConnectionFailure = nil }
                    else if status.state == .failed { self.lastConnectionFailure = status.errorMessage }
                }
                self.refreshMenuStatus()
                self.recordConnectionEvent(status, deviceClass: kind)
            }
            worker.onUSBLost = { [weak self] in self?.checkUSBDrop(kind) }
            worker.onDeviceLockChange = { [weak self] in
                self?.refreshSettingsUI()
                self?.writeLastRun()
            }
            worker.onCaptureSlow = { [weak self] requestID in
                guard let self else { return }
                self.slowPipelineIDs.insert(requestID)
                self.updateTransferNotice()
            }
            worker.onCaptureProgress = { [weak self] requestID, received, expected in
                guard let self else { return }
                self.pipelineProgress[requestID] = (received, expected)
                self.updateTransferNotice()
            }
        }
        refreshMenuStatus()
        monitor.onChange = { [weak self] keys, timestamp in self?.receiveKeys(keys, at: timestamp) }
        monitor.onLoss = { [weak self] in self?.stop(reason: L("Shortcut listening stopped. The capture was cancelled. Enable shortcuts again.", "快捷键监听停了，这次截图已取消。请重新打开快捷键。")) }
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self,
                selector: #selector(targetApplicationChanged(_:)), name: name, object: nil)
        }
        startNetworkMonitor()
        // The worker child keeps itself connected; this only restarts it if it
        // exited (e.g. after a failed request) while listening is enabled.
        workerWatchdog = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rewarmWorker(after: 0) }
        }
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
        purgeOldCaptures()
        // A previously saved explicit Enable may restore listening silently.
        // No startup path requests a screenshot or prompts for new permissions.
        let mainMenu = NSMenu()
        let appEntry = NSMenuItem()
        let appMenu = NSMenu(title: "Toss")
        _ = add(appMenu, L("Connection Status", "连接状态"), #selector(showMenuStatus))
        _ = add(appMenu, L("Settings…", "设置…"), #selector(showSettings))
        appMenu.addItem(.separator())
        let quitItem = add(appMenu, L("Quit Toss", "退出 Toss"), #selector(quit))
        quitItem.keyEquivalent = "q"
        appEntry.submenu = appMenu
        mainMenu.addItem(appEntry)
        NSApp.mainMenu = mainMenu
        buildSettingsWindow()
    }

    private func buildSettingsWindow() {
        _ = SettingsStyle.fontsRegistered
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsStyle.settingsWidth, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L("Toss · Settings", "Toss · 设置")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let inner = SettingsStyle.settingsWidth - 2 * SettingsStyle.margin
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        settingsStack = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsStyle.margin),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: SettingsStyle.settingsTop),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -SettingsStyle.settingsBottom)
        ])
        func text(_ string: String, size: CGFloat = 14.5, color: NSColor = SettingsStyle.ink) -> NSTextField {
            let view = NSTextField(labelWithString: string)
            view.font = SettingsStyle.sans(size)
            view.textColor = color
            return view
        }
        func detail(_ string: String) -> NSTextField {
            let view = SettingsDetail(wrappingLabelWithString: string)
            view.font = SettingsStyle.sans(12.5)
            view.textColor = SettingsStyle.muted
            view.stringValue = string // applies the note's line spacing now that font and colour are set
            view.preferredMaxLayoutWidth = inner - 190
            view.setContentCompressionResistancePriority(.required, for: .vertical)
            return view
        }
        func heading(_ string: String, size: CGFloat) -> NSTextField {
            let view = NSTextField(labelWithString: string)
            view.font = SettingsStyle.serif(size)
            view.textColor = SettingsStyle.ink
            return view
        }
        func place(_ view: NSView, gap: CGFloat) {
            stack.addArrangedSubview(view)
            stack.setCustomSpacing(gap, after: view)
        }
        func hstack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
            let view = NSStackView(views: views)
            view.orientation = .horizontal
            view.alignment = .centerY
            view.spacing = spacing
            return view
        }
        func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            return view
        }
        func hairline() -> NSView {
            let view = NSBox()
            view.boxType = .custom
            view.titlePosition = .noTitle
            view.borderWidth = 0
            view.fillColor = SettingsStyle.line
            view.heightAnchor.constraint(equalToConstant: 1).isActive = true
            view.widthAnchor.constraint(equalToConstant: inner).isActive = true
            return view
        }
        // Rows separated by thin lines, with a line above the first and below the last.
        func list(_ rows: [NSView]) -> NSView {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 0
            column.addArrangedSubview(hairline())
            for row in rows {
                column.addArrangedSubview(row)
                column.addArrangedSubview(hairline())
            }
            return column
        }
        func row(_ title: String, _ note: NSTextField? = nil, _ trailing: [NSView]) -> NSView {
            let labels = NSStackView(views: [text(title)] + (note.map { [$0] } ?? []))
            // Wide window: the grey note sits on the title's line, so rows stay one line tall.
            labels.orientation = SettingsStyle.settingsInlineNotes ? .horizontal : .vertical
            labels.alignment = SettingsStyle.settingsInlineNotes ? .firstBaseline : .leading
            labels.spacing = SettingsStyle.settingsInlineNotes ? 12 : SettingsStyle.noteGap
            labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
            // Keep the column as tall as its text, so the title re-centres when the note hides.
            labels.setHuggingPriority(.defaultHigh, for: .vertical)
            let view = hstack([labels, spacer()] + trailing, spacing: 10)
            // Roomier rows (Ashley 2026-10-30: 「太紧凑了」).
            let pad = SettingsStyle.settingsRowPad ?? SettingsStyle.rowPad
            view.edgeInsets = NSEdgeInsets(top: pad, left: 0, bottom: pad, right: 0)
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 28 + 2 * pad).isActive = true
            // A wrapped note keeps clear room above and below, never touching the dividers.
            labels.setContentCompressionResistancePriority(.required, for: .vertical)
            view.heightAnchor.constraint(greaterThanOrEqualTo: labels.heightAnchor, constant: 2 * pad).isActive = true
            view.widthAnchor.constraint(equalToConstant: inner).isActive = true
            return view
        }
        func keys(_ symbol: String) -> NSView {
            hstack([SettingsKeycap(symbol), text("+", size: 12, color: SettingsStyle.muted), SettingsKeycap(symbol)], spacing: 7)
        }

        // Header: serif name, one status line, the on/off pill.
        let state = SettingsStatus(size: 14, emphasizesLead: true)
        settingsState = state
        let titles = NSStackView(views: [heading("Toss", size: 34), state])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 8
        let toggle = SettingsPill(SettingsStyle.shortToggle(L("Enable Shortcuts", "打开快捷键")), compact: false,
                                  target: self, action: #selector(toggle))
        windowToggle = toggle
        let header = hstack([titles, spacer(), toggle], spacing: 16)
        header.alignment = .bottom
        header.widthAnchor.constraint(equalToConstant: inner).isActive = true
        place(header, gap: SettingsStyle.settingsSectionGap + 2)

        place(heading(L("Shortcuts", "快捷键"), size: 18), gap: 8)
        let optionNote = detail(DeviceCopy.shortcutNote(option: true, twoDevices: false))
        let shiftNote = detail(DeviceCopy.shortcutNote(option: false, twoDevices: false))
        shortcutNotes = [optionNote, shiftNote]
        place(list([row("ChatGPT / Codex", optionNote, [keys("⌥")]),
                    row("Claude", shiftNote, [keys("⇧")])]), gap: SettingsStyle.settingsSectionGap)

        // Setup: pairing, Accessibility, live iPad connection, login item.
        place(heading(L("Setup", "常规"), size: 18), gap: 8)
        let pairDetail = detail(hasPairing ? "" : L("Connect with USB once and unlock it.", "用数据线连一次，并解锁 \(deviceZH)。"))
        setupStatus = pairDetail
        let pairStatus = SettingsStatus()
        pairState = pairStatus
        let pairButton = SettingsPill(hasPairing ? L("Check", "检查") : L("Pair", "配对"), kind: .filled, target: self, action: #selector(runSetup))
        setupButtons = [pairButton]
        let accessDetail = detail(L("Turn on Toss in System Settings.", "在系统设置里打开 Toss。"))
        permissionHint = accessDetail
        let accessStatus = SettingsStatus()
        accessState = accessStatus
        let accessButtonView = SettingsPill(L("Open Settings", "打开设置"), target: self, action: #selector(requestAccessibility))
        accessButton = accessButtonView
        let networkDetailView = detail("")
        networkDetail = networkDetailView
        let networkStatus = SettingsStatus()
        networkState = networkStatus
        let networkButtonView = SettingsPill(L("Retry", "重试"), target: self, action: #selector(retryConnection))
        networkButton = networkButtonView
        let login = SettingsSwitch(target: self, action: #selector(toggleLogin))
        login.setAccessibilityLabel(L("Launch at login", "登录时打开"))
        loginToggle = login
        let loginNote = detail("")
        startupStatus = loginNote
        let notifications = SettingsSwitch(target: self, action: #selector(toggleToast))
        notifications.setAccessibilityLabel(ToastCopy.strings().notifications)
        notifications.state = toastPreferences.enabled ? .on : .off
        toastToggle = notifications
        place(list([row(DeviceCopy.label, pairDetail, [pairStatus, pairButton]),
                    row(L("Accessibility", "辅助功能"), accessDetail, [accessStatus, accessButtonView]),
                    row(L("Connection", "连接"), networkDetailView, [networkStatus, networkButtonView]),
                    row(L("Launch at login", "登录时打开"), loginNote, [login]),
                    row(ToastCopy.strings().notifications, nil, [notifications]),
                    row(L("Language", "语言"), nil, [languageMenu()])]), gap: SettingsStyle.settingsFooterGap)

        // Rare actions live under More.
        let more = NSMenu()
        more.autoenablesItems = false
        func moreItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            more.addItem(entry)
            return entry
        }
        checkMenuItem = moreItem(L("Check Connection", "检查连接"), #selector(runSetup))
        _ = moreItem(L("Cancel Capture", "取消截图"), #selector(cancelCurrent))
        _ = moreItem(L("Refresh Access", "刷新权限"), #selector(refreshPermissions))
        more.addItem(.separator())
        _ = moreItem(L("Copy Diagnostics", "复制诊断信息"), #selector(copyDiagnostics))
        more.addItem(.separator())
        forgetMenuItem = moreItem(L("Forget This Device…", "忘记这台设备…"), #selector(forgetDevice))
        settingsMore = more
        let footer = hstack([SettingsPill(L("Setup guide", "设置引导"), target: self, action: #selector(openOnboarding)),
                             SettingsPill(L("Diagnostics", "诊断信息"), target: self, action: #selector(showDiagnostics)),
                             SettingsPill(L("More…", "更多…"), target: self, action: #selector(showSettingsMore(_:))), spacer(),
                             SettingsPill(L("Quit Toss", "退出 Toss"), kind: .quiet, target: self, action: #selector(quit))], spacing: 8)
        footer.widthAnchor.constraint(equalToConstant: inner).isActive = true
        place(footer, gap: 18)
        place(SettingsPill(UninstallCopy.link, kind: .quiet, target: self, action: #selector(confirmUninstall)), gap: 0)

        settingsWindow = window
        refreshPermissions()
        refreshStartupUI()
        refreshSettingsUI()
        window.center()
        SettingsStyle.applyUnifiedWindowStyle(in: window, backgroundColor: SettingsStyle.settingsBackground)
    }

    // Settings → Language: Follow System (default) and every AppLanguage. Each choice is named in its own
    // language so it can be found whatever the current one is.
    private func languageMenu() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = SettingsStyle.sans(13)
        popup.addItems(withTitles: AppLanguage.allCases.map { $0 == .system ? L("Follow System", "跟随系统") : $0.nativeName })
        popup.selectItem(at: AppLanguage.allCases.firstIndex(of: AppLanguage.choice) ?? 0)
        popup.target = self
        popup.action = #selector(languageChosen(_:))
        popup.setAccessibilityLabel(L("Language", "语言"))
        return popup
    }

    // Every window, menu and toast is built in one language, so a change reopens Toss (about two
    // seconds) and comes back to Settings; shortcuts resume as before.
    @objc private func languageChosen(_ sender: NSPopUpButton) {
        guard !uninstalling else { return }
        let languages = AppLanguage.allCases
        let choice = languages[max(0, min(languages.count - 1, sender.indexOfSelectedItem))]
        let before = AppLanguage.current
        AppLanguage.choice = choice
        guard AppLanguage.current != before else { return }
        UserDefaults.standard.set(true, forKey: Self.reopenSettingsKey)
        UserDefaults.standard.synchronize()
        relaunch()
    }
    static let reopenSettingsKey = "Toss.reopenSettingsAfterLanguage"

    @objc private func showSettingsMore(_ sender: NSButton) {
        settingsMore?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.height + 6 : -6), in: sender)
    }

    private var currentConnection: TossConnectionStatus {
        #if TOSS_RENDER
        if let connection = RenderState.connection { return connection }
        #endif
        return deviceConnections[activeDeviceClass] ?? .notChecked
    }

    // Public data for Claude's per-device UI. Never treat a ready sibling as proof of this link.
    var deviceConnections: [DeviceClass: TossConnectionStatus] {
        Dictionary(uniqueKeysWithValues: pairedDeviceClasses.map { kind in
            let status = captureWorkers[kind]!.connectionStatus
            return (kind, networkAvailable == false && !status.isHealthyUSB
                ? TossConnectionStatus(state: .disconnected, reason: "network_unavailable") : status)
        })
    }

    private var deviceConnectionRows: [(String, TossConnectionStatus)] {
        DeviceClass.allCases.compactMap { kind in deviceConnections[kind].map { (kind.rawValue, $0) } }
    }


    @objc private func retryConnection() { recheckMenuConnection() }

    @objc private func toggleToast() {
        guard !uninstalling else { return }
        toastPreferences.enabled.toggle()
        toastToggle?.state = toastPreferences.enabled ? .on : .off
    }

    private var setupRunning: Bool {
        #if TOSS_RENDER
        if let running = RenderState.pairing { return running }
        #endif
        return setupWizard.isRunning
    }

    // Settings shows state only; it never starts a capture or changes permissions.
    private func refreshSettingsUI() {
        guard settingsWindow != nil else { return }
        toastToggle?.state = toastPreferences.enabled ? .on : .off
        if shortcutNotes.count == 2 {
            let two = pairedDeviceClasses.count == 2
            shortcutNotes[0].stringValue = DeviceCopy.shortcutNote(option: true, twoDevices: two)
            shortcutNotes[1].stringValue = DeviceCopy.shortcutNote(option: false, twoDevices: two)
        }
        let paired = hasPairing
        let access = permissionsReady
        let connection = currentConnection
        let pairing = setupRunning

        if !pairing, let pair = setupButtons.first {
            pair.title = paired ? L("Check", "检查") : L("Pair", "配对")
            pair.keyEquivalent = paired ? "" : "\r"
        }
        (setupButtons.first as? SettingsPill)?.kind = pairing ? .ghost : .filled
        setupButtons.first?.isHidden = paired && !pairing
        pairState?.show(paired && !pairing ? L("Paired", "已配对") : nil, dot: SettingsStyle.ok)
        // A paired, idle iPad needs no explanation unless the last check said something.
        if paired && !pairing && ["ready", "not_run", "cancelled"].contains(lastSetupCode) { setupStatus?.isHidden = true }
        else { setupStatus?.isHidden = setupStatus?.stringValue.isEmpty ?? true }
        checkMenuItem?.isEnabled = paired && !pairing
        forgetMenuItem?.isEnabled = paired && !pairing && !hasActiveWork

        accessState?.show(access ? L("Allowed", "已允许") : nil, dot: SettingsStyle.ok)
        accessButton?.isHidden = access
        if access { permissionHint?.stringValue = "" }
        else if permissionHint?.stringValue.isEmpty ?? false { permissionHint?.stringValue = L("Turn on Toss in System Settings.", "在系统设置里打开 Toss。") }

        switch (paired, connection.state) {
        case (false, _):
            networkState?.show(L("After pairing", "配对后可用"))
            networkDetail?.stringValue = L("Keep \(deviceEN) unlocked, on the same Wi-Fi.", "\(deviceZH) 保持解锁，连同一个 Wi-Fi。")
            networkButton?.isHidden = true
        case (true, .ready):
            // Not "Same network": a USB connection needs no shared Wi-Fi (UI copy review 2026-10-28).
            networkState?.show(L("Connected", "已连接") + (connection.transportLabel.map { " · " + $0 } ?? ""), dot: SettingsStyle.ok)
            networkDetail?.stringValue = ""
            networkButton?.isHidden = true
        case (true, .connecting):
            networkState?.show(L("Connecting…", "正在连接…"), dot: SettingsStyle.accent)
            networkDetail?.stringValue = ""
            networkButton?.title = L("Retry", "重试")
            networkButton?.isHidden = false
        case (true, .disconnected), (true, .failed):
            networkState?.show(L("Not connected", "没连上"), dot: SettingsStyle.accent)
            networkDetail?.stringValue = connection.errorMessage ?? L("Unlock \(deviceEN), use the same Wi-Fi.", "解锁 \(deviceZH)，连同一个 Wi-Fi。")
            networkButton?.title = L("Retry", "重试")
            networkButton?.isHidden = false
        case (true, .notChecked):
            networkState?.show(nil)
            networkDetail?.stringValue = enabled ? L("Not checked yet.", "还没检查。") : L("Checked when shortcuts are on.", "快捷键打开后会检查。")
            networkButton?.title = L("Check", "检查")
            networkButton?.isHidden = false
        }
        networkButton?.isEnabled = !sleeping && !hasActiveWork && !anyWorkerBusy &&
            !pairing && enableTask == nil
        if pairedDeviceClasses.count == 2 {
            // Two devices: the row says how many are in, the note gives each device its own line.
            let rows = deviceConnectionRows
            let ready = rows.filter { $0.1.state == .ready }.count
            let down = rows.contains { $0.1.state == .disconnected || $0.1.state == .failed }
            // Ashley 2026-11-02: name the device that is out, not "one of them".
            let downNames = DeviceCopy.names(rows.filter { $0.1.state == .disconnected || $0.1.state == .failed }.map { $0.0 })
            let connectingNames = DeviceCopy.names(rows.filter { $0.1.state == .connecting }.map { $0.0 })
            if ready == rows.count { networkState?.show(L("Both connected", "都已连上"), dot: SettingsStyle.ok) }
            else if down && ready == 0 && !rows.contains(where: { $0.1.state == .connecting }) {
                networkState?.show(L("Neither connected", "都没连上"), dot: SettingsStyle.accent)
            }
            else if down { networkState?.show(L("\(downNames) not connected", "\(downNames) 没连上"), dot: SettingsStyle.accent) }
            else if rows.contains(where: { $0.1.state == .connecting }) {
                networkState?.show(L("Connecting \(connectingNames)…", "正在连接 \(connectingNames)…"), dot: SettingsStyle.accent)
            }
            else { networkState?.show(nil) }
            networkDetail?.stringValue = DeviceCopy.connectionLines(rows)
            let connecting = rows.contains { $0.1.state == .connecting }
            networkButton?.title = down || connecting ? L("Retry", "重试") : L("Check", "检查")
            networkButton?.isHidden = ready == rows.count
        }

        let summary = statusSummary
        settingsState?.show(summary.text, dot: summary.tone)
        fitSettingsWindow()
    }

    // One status line, shown by both Settings and the menu-bar popover.
    private var statusSummary: (text: String, tone: NSColor) {
        let steps = (hasPairing ? 0 : 1) + (permissionsReady ? 0 : 1)
        if steps > 0 {
            return (steps == 2 ? L("Two steps left, then shortcuts turn on", "还差两步，快捷键就会打开") : L("One step left, then shortcuts turn on", "还差一步，快捷键就会打开"),
                    SettingsStyle.accent)
        }
        // USB alone is never "set up": while pairing runs, and after "Use cable only for now", the status stays grey.
        let words = OnboardingCopy(language: .current())
        if setupRunning { return (words.settingUpStatus(code: lastSetupCode), SettingsStyle.muted) }
        if enableTask != nil { return (L("Turning on…", "正在打开…"), SettingsStyle.accent) }
        if !enabled {
            if let reason = enableFailureReason { return (L("Couldn't turn on · ", "打不开 · ") + reason, SettingsStyle.muted) }
            return (startup.desiredEnabled ? L("Waiting for ChatGPT or Claude to open", "等 ChatGPT 或 Claude 打开") : L("Off · Shortcuts are paused", "已关闭 · 快捷键暂停"),
                    SettingsStyle.muted)
        }
        if pairedDeviceClasses.count == 2 {
            // Two devices: name the ones that need attention, else say both are in.
            let rows = deviceConnectionRows
            let down = rows.filter { $0.1.state == .disconnected || $0.1.state == .failed }.map { $0.0 }
            let connecting = rows.filter { $0.1.state == .connecting }.map { $0.0 }
            let ready = rows.filter { $0.1.state == .ready }.map { $0.0 }
            if down.count == 2 { return (L("On · Neither device connected", "已打开 · 都没连上"), SettingsStyle.accent) }
            let downNames = DeviceCopy.names(down), connectingNames = DeviceCopy.names(connecting), readyNames = DeviceCopy.names(ready)
            if !down.isEmpty { return (L("On · \(downNames) not connected", "已打开 · \(downNames) 没连上"), SettingsStyle.accent) }
            if !connecting.isEmpty { return (L("Connecting to \(connectingNames)…", "正在连接 \(connectingNames)…"), SettingsStyle.accent) }
            if ready.isEmpty { return (L("On · Press both Option or both Shift", "已打开 · 按两个 Option 或两个 Shift"), SettingsStyle.ok) }
            if ready.count == 2 { return (L("Ready · Both connected", "就绪 · 都已连上"), SettingsStyle.ok) }
            return (L("Ready · \(readyNames) connected", "就绪 · \(readyNames) 已连接"), SettingsStyle.ok)
        }
        switch currentConnection.state {
        case .ready:
            if currentConnection.transport != "wifi",
               UserDefaults.standard.object(forKey: OnboardingPolicy.wirelessKey) as? Bool == false {
                return (words.cableOnlyStatus, SettingsStyle.muted)
            }
            return (L("Ready · \(deviceEN) connected", "就绪 · \(deviceZH) 已连接"), SettingsStyle.ok)
        case .connecting: return (L("Connecting to \(deviceEN)…", "正在连接 \(deviceZH)…"), SettingsStyle.accent)
        case .notChecked: return (L("On · Press both Option or both Shift", "已打开 · 按两个 Option 或两个 Shift"), SettingsStyle.ok)
        case .disconnected, .failed: return (L("On · \(deviceEN) not connected", "已打开 · \(deviceZH) 没连上"), SettingsStyle.accent)
        }
    }

    // Grow or shrink with the content, keeping the window's top edge in place.
    private func fitSettingsWindow() {
        guard let window = settingsWindow, let stack = settingsStack, let content = window.contentView else { return }
        stack.layoutSubtreeIfNeeded()
        let delta = stack.fittingSize.height + SettingsStyle.settingsTop + SettingsStyle.settingsBottom - content.frame.height
        guard abs(delta) > 0.5 else { return }
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true)
    }

    // Read-only presentation of the live worker and the current transaction.
    // "Enabled" alone is never treated as evidence of an iPad connection.
    private func refreshMenuStatus() {
        var phase = TossTransferPhase.from(code: lastCode)
        if !capturePipeline.running.isEmpty || (phase == .preparing && earlyCapture != nil) { phase = .uploading }
        let summary = statusSummary
        onboarding?.setTransport(currentConnection.state == .ready ? currentConnection.transportLabel : nil)
        menuStatus?.update(.init(connection: currentConnection,
            phase: phase, paired: hasPairing, enabled: enabled,
            canRecheck: !sleeping && !hasActiveWork && !anyWorkerBusy &&
                !setupWizard.isRunning && enableTask == nil,
            lastMessage: lastStatus, retryError: lastConnectionFailure,
            uploadTarget: targetKind == .claude ? .claude : .codex,
            summary: summary.text, summaryTone: summary.tone,
            lastCaptureResult: lastCaptureResult, captureInProgress: captureRecord != nil,
            deviceConnections: deviceConnectionRows))
        refreshSettingsUI()
    }

    private func recheckMenuConnection() {
        guard !uninstalling else { return }
        guard !sleeping, !hasActiveWork, !anyWorkerBusy,
              !setupWizard.isRunning, enableTask == nil else { return }
        guard hasPairing else { showSettings(); return }
        do {
            let config = try configuration()
            stopWorkers()
            try prepareWorkers(config)
        } catch {
            failure(error, code: "connection_check_failed")
        }
        refreshMenuStatus()
    }

    private func makeStatusController(item: NSStatusItem, menu: NSMenu) -> TossStatusController {
        TossStatusController(item: item, menu: menu,
            recheck: { [weak self] in self?.recheckMenuConnection() },
            settings: { [weak self] in self?.showSettings() },
            diagnostics: { [weak self] in self?.showDiagnostics() },
            exportLogs: { [weak self] in self?.exportLogs() },
            openSetupIfNeeded: { [weak self] in self?.openSetupIfNeeded() ?? false })
    }

    @objc private func showMenuStatus() {
        refreshMenuStatus()
        menuStatus?.showPanel()
    }

    @objc private func showSettings() {
        guard !uninstalling else { return }
        #if TOSS_RENDER
        if let opened = RenderState.onOpenInterface { opened("settings"); return }
        #endif
        prepareInterface()
        refreshPermissions()
        refreshStartupUI()
        NSApp.setActivationPolicy(.regular)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        afterSettingsShown()
    }

    @discardableResult private func openSetupIfNeeded() -> Bool {
        guard OnboardingPolicy.opensFromIcon(paired: hasPairing, guideVisible: onboarding?.isVisible == true) else { return false }
        showOnboarding()
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if openSetupIfNeeded() { return true }
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) { refreshPermissions() }

    private var usbSetupObserver: USBSetupObserver?
    private var usbSetupPolicy = USBSetupPolicy(dismissals: USBSetupDismissals(preferences: UserDefaults.standard))
    private var usbSetupRetry: Timer?

    private func startUSBSetupObserver() {
        #if !TOSS_RENDER
        guard usbSetupObserver == nil, !uninstalling else { return }
        let observer = USBSetupObserver { [weak self] devices in
            guard let self, !self.uninstalling, !self.terminating else { return }
            self.usbSetupPolicy.update(devices)
            self.offerUSBSetup()
        }
        usbSetupObserver = observer
        observer.start()
        #endif
    }

    private func stopUSBSetupObserver() {
        usbSetupRetry?.invalidate(); usbSetupRetry = nil
        usbSetupObserver?.stop(); usbSetupObserver = nil
    }

    private func pairedUSBSetupHashes() -> [String: String] {
        var hashes: [String: String] = [:]
        for (kind, directory) in pairedDevice.directories {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: directory + "/target.json")),
               let pin = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let hash = pin["device_hash"] as? String { hashes[kind.rawValue] = hash }
        }
        return hashes
    }

    private func offerUSBSetup() {
        guard !uninstalling, !terminating else { return }
        let paired = hasPairing
        let hashes = pairedUSBSetupHashes()
        let candidates = usbSetupPolicy.pending(paired: hashes, iPadOnly: false, hasPairing: paired)
        let otherSetupTarget = !SetupWizard.canAttachUSBPrompt(
            running: setupWizard.isRunning, targetHash: setupDeviceHash, code: lastSetupCode,
            candidateHashes: candidates.map(\.deviceHash))
        let blocked = core.isBusy || hasActiveWork || transaction != nil || enableTask != nil ||
            anyWorkerBusy || sleeping || runtimeQuarantined || onboarding != nil || otherSetupTarget
        if let device = usbSetupPolicy.take(paired: hashes, iPadOnly: false, hasPairing: paired, blocked: blocked) {
            openOnboarding()
            usbSetupPolicy.automaticPresented(candidates, visible: onboarding?.isVisible == true)
            // An existing run owns its target and its copy; opening only attaches UI.
            if !setupWizard.isRunning {
                setupDeviceClass = DeviceClass(rawValue: device.deviceClass)
                updateDeviceCopy()
                onboarding?.setDeviceClass(setupDeviceClass)
            }
        }
        // Only an outstanding insertion needs this timer; an idle listener has no polling.
        let pending = !usbSetupPolicy.pending(paired: hashes, iPadOnly: false, hasPairing: paired).isEmpty
        if pending && usbSetupRetry == nil {
            usbSetupRetry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.offerUSBSetup() }
            }
        } else if !pending { usbSetupRetry?.invalidate(); usbSetupRetry = nil }
    }

    func showInitialInterface() {
        guard !initialInterfaceShown else { return }
        initialInterfaceShown = true
        if installIfNeeded() { return }
        retireOtherInstances()
        startUSBSetupObserver()
        presentInitialInterface(afterInstall: CommandLine.arguments.contains("--show-setup"))
    }

    private func presentInitialInterface(afterInstall: Bool) {
        if afterInstall {
            showOnboarding()
            if hasPairing && permissionsReady {
                onboarding?.setTransport(currentConnection.state == .ready ? currentConnection.transportLabel : nil)
                onboarding?.jump(to: .done)
            }
            restoreIfPossible()
            return
        }
        if UserDefaults.standard.bool(forKey: Self.reopenSettingsKey) {
            UserDefaults.standard.removeObject(forKey: Self.reopenSettingsKey)
            if onboarding == nil && hasPairing { showSettings(); restoreIfPossible(); return }
        }
        if OnboardingPolicy.opensAutomatically(paired: hasPairing, firstRun: startup.shouldShowInitialSettings,
                                               seen: UserDefaults.standard.bool(forKey: OnboardingPolicy.seenKey)) { showOnboarding() }
        else if startup.shouldShowInitialSettings { showSettings(); checkMenuIconSoon() }
        else { restoreIfPossible(); checkMenuIconSoon() }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    @objc private func toggle() {
        guard !uninstalling else { return }
        switch StartupPolicy.enableAction(enabled: enabled, enabling: enableTask != nil,
                                          desired: startup.desiredEnabled, targetRunning: !runningTargetKinds().isEmpty) {
        case .disable:
            pendingUserEnable = false
            startup.rememberEnabled(false)
            stop(reason: L("Disabled. Shortcuts will stay off on the next launch.", "已关闭。下次打开 Toss 快捷键也保持关闭。"))
            refreshStartupUI()
        case .waitForTarget:
            // Nothing to prepare yet: keep the choice, and restoreIfPossible()
            // turns shortcuts on when ChatGPT / Codex or Claude opens.
            enableFailureReason = nil
            pendingUserEnable = true
            startup.rememberEnabled(true)
            refreshStartupUI()
            restoreIfPossible()
        case .start:
            beginEnable(userInitiated: true)
        }
    }

    private func restoreIfPossible() {
        guard !uninstalling else { return }
        guard startup.desiredEnabled, !enabled, enableTask == nil else { return }
        toggleItem.title = L("Disable Auto-Resume", "关闭自动恢复")
        windowToggle?.title = SettingsStyle.shortToggle(L("Disable Auto-Resume", "关闭自动恢复"))
        guard permissionsReady else {
            setStatus(L("Shortcuts are enabled, but permissions are missing. Open Settings to continue.", "快捷键已打开，但还缺权限。打开设置继续。"), code: "waiting_permissions")
            return
        }
        guard !runningTargetKinds().isEmpty else {
            setStatus(L("Waiting for ChatGPT / Codex or Claude to open.", "等 ChatGPT / Codex 或 Claude 打开。"), code: "waiting_target")
            return
        }
        let userInitiated = pendingUserEnable
        pendingUserEnable = false
        beginEnable(userInitiated: userInitiated)
    }

    private func targetFor(_ kind: TargetKind) -> ChatTarget {
        switch kind {
        case .chatGPT: return chatGPTTarget
        case .claude: return claudeTarget
        }
    }

    private func runningTargetKinds() -> [TargetKind] {
        [TargetKind.chatGPT, .claude].filter { kind in
            NSRunningApplication.runningApplications(withBundleIdentifier: kind.bundleID)
                .filter { !$0.isTerminated }.count == 1
        }
    }

    // Prepares every running target; enabling needs at least one to succeed.
    private func prepareRunningTargets() async throws {
        var firstError: Error?
        var prepared = 0
        for kind in runningTargetKinds() {
            do { try await targetFor(kind).prepareAccessibility(); prepared += 1 }
            catch is CancellationError { throw CancellationError() }
            catch { firstError = firstError ?? error }
        }
        if prepared == 0 { throw firstError ?? TargetFailure.appUnavailable }
    }

    @objc private func targetApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let kind = TargetKind.forBundleID(application.bundleIdentifier) else { return }
        if notification.name == NSWorkspace.didTerminateApplicationNotification {
            // Only the transaction aimed at the quitting app is cancelled; the
            // other target keeps working and listening continues.
            if let tx = transaction, tx.lease.pid == application.processIdentifier { cancelCurrent() }
            if let pending = pendingClipboard, pending.lease.pid == application.processIdentifier {
                if pending.clipboard.finish(pastePosted: true, consumptionConfirmed: false, targetTerminated: true) {
                    pendingClipboard = nil
                } else {
                    pendingClipboard?.safeToRestore = true
                }
            }
            return
        }
        guard enabled else { restoreIfPossible(); return }
        // A target that launched after Enable is prepared in the background. The
        // request is idempotent per process and never touches a draft.
        Task { @MainActor [weak self] in
            try? await self?.targetFor(kind).prepareAccessibility()
        }
    }

    private func beginEnable(userInitiated: Bool) {
        guard !uninstalling else { return }
        guard !enabled, enableTask == nil else { return }
        enableFailureReason = nil
        enableGeneration &+= 1
        let generation = enableGeneration
        do {
            let config = try configuration()
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw TossError.accessibilityPermission }
            toggleItem.title = L("Cancel Enabling", "取消打开")
            windowToggle?.title = SettingsStyle.shortToggle(L("Cancel Enabling", "取消打开"))
            setStatus(L("Preparing chat access and the wireless connection… About 3 seconds.", "正在准备聊天窗口和无线连接…约 3 秒。"), code: "preparing_accessibility")
            // An explicit Enable or its saved startup intent only. Never request
            // this mode in the middle of a screenshot/target lease.
            enableTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    guard self.enableGeneration == generation else { throw TossError.cancelled }
                    try self.prepareWorkers(config)
                    try await self.prepareRunningTargets()
                    try Task.checkCancellation()
                    guard self.enableGeneration == generation else { throw TossError.cancelled }
                    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw TossError.accessibilityPermission }
                    try self.monitor.start()
                    self.enabled = true
                    self.ignoreKeyboardEventsThrough = ProcessInfo.processInfo.systemUptime
                    self.toggleItem.title = L("Disable Shortcuts", "关闭快捷键")
                    self.windowToggle?.title = SettingsStyle.shortToggle(L("Disable Shortcuts", "关闭快捷键"))
                    _ = self.core.reset()
                    self.readKeys()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.enabled else { return }
                            self.handle(self.core.tick(at: ProcessInfo.processInfo.systemUptime))
                        }
                    }
                    self.enableTask = nil
                    if userInitiated {
                        self.startup.rememberEnabled(true)
                        _ = self.startup.registerAtUserEnable()
                        self.refreshStartupUI()
                    } else { self.refreshStartupUI() }
                    // A failure before this enable is not this state's reason.
                    self.failureCategory = "none"
                    self.backendReason = "none"
                    self.setStatus(L("Enabled: both Option keys → ChatGPT; both Shift keys → Claude", "已打开：两个 Option → ChatGPT；两个 Shift → Claude"), code: "ready")
                } catch {
                    guard !Task.isCancelled, self.enableGeneration == generation else { return }
                    self.stopWorkers()
                    self.enableTask = nil
                    let title = self.startup.desiredEnabled ? L("Disable Auto-Resume", "关闭自动恢复") : L("Enable Shortcuts", "打开快捷键")
                    self.toggleItem.title = title
                    self.windowToggle?.title = SettingsStyle.shortToggle(title)
                    if userInitiated {
                        self.enableFailureReason = Self.shortEnableFailure(error)
                        self.failure(error, code: "enable_failed")
                    } else { self.setStatus(L("Auto-resume is not ready. Disable and re-enable shortcuts in Settings.", "自动恢复没准备好。在设置里关掉再打开快捷键。"), code: "restore_failed") }
                }
            }
        } catch {
            if userInitiated {
                enableFailureReason = Self.shortEnableFailure(error)
                failure(error, code: "enable_failed")
            } else { setStatus(L("Auto-resume is not ready. Check pairing and permissions in Settings.", "自动恢复没准备好。在设置里检查配对和权限。"), code: "restore_failed") }
        }
    }

    // A few words for the summary line; the full text stays in the status and Diagnostics.
    private static func shortEnableFailure(_ error: Error) -> String {
        if let error = error as? TossError {
            switch error {
            case .configuration: return "pair your \(deviceEN) in Settings"
            case .accessibilityPermission, .inputPermission: return "allow Accessibility access"
            case .monitorUnavailable: return "could not listen for shortcuts"
            case .backendUnavailable: return "capture service unavailable"
            default: break
            }
        }
        if let error = error as? TargetFailure {
            switch error {
            case .denied: return "allow Accessibility access"
            case .appUnavailable: return "open ChatGPT / Codex or Claude"
            case .accessibilityPreparationFailed, .accessibilityPreparationChanged, .accessibilityPreparationBusy:
                return "chat app not ready, try again"
            default: break
            }
        }
        return "see Diagnostics"
    }

    private func refreshStartupUI() {
        let status = startup.loginStatus
        let state: NSControl.StateValue = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginToggle?.state = state
        loginMenuItem?.state = state
        startupStatus?.stringValue = status == .enabled || status == .notRegistered
            ? ""
            : startup.loginStatusText
    }

    @objc private func toggleLogin() {
        guard !uninstalling, startupChangeTask == nil, enableTask == nil else { return }
        let turnOn = startup.loginStatus != .enabled && startup.loginStatus != .requiresApproval
        loginToggle?.isEnabled = false
        startupChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.startup.setLoginEnabled(turnOn) }
            catch {
                self.refreshStartupUI()
                self.startupStatus?.stringValue = (error as? LocalizedError)?.errorDescription ?? L("Couldn't update. Check Login Items.", "没能更新，请看登录项。")
                self.loginToggle?.isEnabled = true
                self.startupChangeTask = nil
                return
            }
            self.refreshStartupUI()
            self.loginToggle?.isEnabled = true
            self.startupChangeTask = nil
        }
    }

    private func readKeys() {
        guard enabled, !setupWizard.isRunning else { return }
        let keys = KeyMonitor.modifiers()
        _ = chordDetector.observe(keys, allow: false)
        handle(core.observe(keys, at: ProcessInfo.processInfo.systemUptime, allowNewCapture: false))
    }

    private func receiveKeys(_ keys: ModifierSnapshot, at timestamp: Double) {
        let previousKeys = lastKeys
        lastKeys = keys
        guard enabled, !setupWizard.isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch HotkeyEventAdmission.evaluate(timestamp: timestamp, now: now,
                                             ignoreThrough: ignoreKeyboardEventsThrough) {
        case .ignore:
            return
        case .invalid:
            cancelPendingCaptures()
            chordDetector = CaptureChordDetector()
            appendTask?.cancel()
            handle(core.reset())
            _ = core.observe(KeyMonitor.modifiers(), at: now, allowNewCapture: false)
            setStatus(L("Invalid shortcut timing. Release the keys and try again.", "按键节奏不对。松开按键再试一次。"), code: "hotkey_rejected")
        case .observe(let allowNewCapture):
            // First key of a possible chord: start waking the iPad's Wi-Fi. A side
            // effect only; the core gets the same snapshot and time either way.
            if allowNewCapture, captureWorker.connectionStatus.state == .ready,
               keys.startsChord(after: previousKeys) { iPadWaker.poke() }
            handle(core.observe(keys, at: now, allowNewCapture: false))
            if let chord = chordDetector.observe(keys, allow: allowNewCapture, at: timestamp,
                    partialReleaseWindow: pairedDeviceClasses.count == 2 ? DualHotkeyCore.doublePressWindow : 0) {
                selectCapture(chord, at: timestamp)
            }
        }
    }

    private func handle(_ actions: [HotkeyAction]) {
        for action in actions {
            switch action {
            case .capture(let request): startCapture(request)
            case .retarget(let request): retargetCapture(request)
            case .retargetQueued(let pressedAt):
                if queuedPrefetch?.pressedAt == pressedAt { discardQueuedPrefetch() }
                prefetchQueuedScreenshot()
            case .pasteIntent(let request, let token): beginAppend(request, token: token)
            case .busyRepeat(let id, let phase):
                // Acknowledged and logged; the core also queues the press, which starts as a new
                // request of its own after this one (Cmd+V is never re-sent for the running one).
                busyRepeatsTotal += 1
                bindQueuedPress()
                prefetchQueuedScreenshot() // starts at once if the worker is already free
                let refined = phase == "appending" && transaction?.id == id && transaction?.pastePosted == true ? "pasted" : phase
                if let record = captureRecord {
                    captureRecord?.repeats.append((refined, Int(Date().timeIntervalSince(record.startedAt) * 1000)))
                }
                menuStatus?.nudge()
            case .rejected(let id, let reason):
                if activationTask?.id == id {
                    cancelActivation()
                    newDraftInteraction.stop()
                    captureAnimation.cancel(requestID: id)
                    setStatus(L("Capture cancelled. Release the keys before trying again.", "截图已取消。松开按键再试。"), code: "input_interrupted")
                    startQueuedPress()
                    continue
                }
                guard transaction?.id == id else { continue }
                if reason == .imageExpired || reason == .chordInterrupted {
                    if preserveReceivedCapture(error: TossError.keysStillPressed) { continue }
                }
                if reason == .chordInterrupted || reason == .cancelled || reason == .imageExpired {
                    captureAnimation.cancel(requestID: id)
                    cleanup(cancelProcess: true)
                    failureCategory = "none"
                    setStatus(L("Capture cancelled. Release the keys before trying again.", "截图已取消。松开按键再试。"), code: "input_interrupted")
                    continue
                }
                // A failed capture is reported by failure(), which collapses this card
                // into the result; every other rejection removes it here. (captureSucceeded's
                // empty-token .captureFailed cannot occur: the token is the transaction UUID.)
                if reason != .captureFailed { captureAnimation.cancel(requestID: id) }
                cleanup(cancelProcess: true)
                setStatus(L("Stopped: \(reason). No retry was made.", "已停止：\(reason)。没有自动重试。"), code: "hotkey_rejected")
            }
        }
    }

    // Use only this app's bundled runtime and Toss's own pairing directory.
    private func runtimeConfiguration() throws -> TossConfiguration {
        guard let python = Bundle.main.resourceURL?.appendingPathComponent("Runtime/python/bin/python3").path,
              fm.isExecutableFile(atPath: python) else { throw TossError.backendUnavailable }
        return TossConfiguration(python: python,
                                 state_dir: base.appendingPathComponent("DeviceState", isDirectory: true).path)
    }

    // A browser download marks every file; macOS then blocks the bundled Python
    // when this app launches it. installIfNeeded() removes the mark with consent.
    private var runtimeQuarantined: Bool {
        guard let python = Bundle.main.resourceURL?.appendingPathComponent("Runtime/python/bin/python3.13").path,
              fm.fileExists(atPath: python) else { return false }
        return getxattr(python, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    private func refreshPairedDevice() {
        guard let config = try? runtimeConfiguration() else { pairedDevice.forget(); updateDeviceCopy(); return }
        pairedDevice.restore(root: config.state_dir,
            read: { try? Data(contentsOf: URL(fileURLWithPath: $0)) }, exists: { fm.fileExists(atPath: $0) })
        updateDeviceCopy()
    }

    private var hasPairing: Bool {
        #if TOSS_RENDER
        if let devices = RenderState.pairedDevices { pairedDevice = devices; return pairedDeviceClass != nil }
        if let paired = RenderState.paired { return paired }
        #endif
        refreshPairedDevice()
        return pairedDeviceClass != nil
    }

    private func configuration() throws -> TossConfiguration {
        let config = try runtimeConfiguration()
        guard hasPairing else { throw TossError.configuration }
        return config
    }

    // MARK: - Pairing wizard (user-clicked only)

    @objc private func runSetup() {
        guard !uninstalling else { return }
        if setupWizard.isRunning {
            setupWizard.cancel()
            setupFinished(.init(code: "cancelled", model: nil, ipados: nil))
            return
        }
        // Pairing a new iPad goes through the step-by-step setup; "Check" on a paired one stays here.
        if !hasPairing { showOnboarding(); return }
        showSettings()
        // One device: unchanged from the iPad build (USB auto setup re-checks the pairing). Two devices: the USB auto
        // setup could act on whichever one is plugged in, so "Check" only rebuilds each device's own connection.
        if pairedDeviceClasses.count == 2 { recheckMenuConnection() } else { startSetup(action: "auto") }
    }

    private func startSetup(action: String) {
        guard !uninstalling, !setupWizard.isRunning, !hasActiveWork, transaction == nil else { return }
        guard !runtimeQuarantined || !installIfNeeded() else { return }
        guard let config = try? runtimeConfiguration(),
              let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/setup_device.py").path,
              fm.fileExists(atPath: script) else {
            setupStatus?.stringValue = SetupWizard.message(for: .init(code: "setup_unavailable", model: nil, ipados: nil))
            return
        }
        try? fm.createDirectory(atPath: base.path, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Setup owns pairing records; resume each independent worker when it finishes.
        stopWorkers()
        _ = core.reset()
        onboarding?.setDeviceClass(nil)
        setupButtons.first?.title = L("Cancel Pairing", "取消配对")
        setupButtons.dropFirst().forEach { $0.isEnabled = false }
        setupStatus?.stringValue = L("Checking your \(deviceEN)…", "正在检查 \(deviceZH)…")
        setupDeviceHash = nil
        lastSetupCode = "not_run"
        setupWizard.run(python: config.python, script: script, action: action, stateDirectory: config.state_dir,
                        progress: { [weak self] result in self?.setupProgress(result) },
                        completion: { [weak self] result in self?.setupFinished(result) })
    }

    private var trustWaitStarted: Double?
    private func setupProgress(_ result: SetupWizard.Result) {
        guard !uninstalling else { return }
        lastSetupCode = result.code
        setupDeviceHash = result.setupDeviceHash
        // Name the device in this result before any text below is generated.
        if ["no_usb_ipad", "multiple_usb_ipads", "mixed_usb_devices", "unsupported_device"].contains(result.code) {
            setupDeviceClass = nil
        } else if let found = result.deviceClass { setupDeviceClass = found }
        updateDeviceCopy()
        setupStatus?.stringValue = SetupWizard.message(for: result)
        // Still no Trust after 30 s: the one grey line becomes the replug hint.
        if result.code == "trust_needed" {
            let now = ProcessInfo.processInfo.systemUptime
            if trustWaitStarted == nil {
                trustWaitStarted = now
                DispatchQueue.main.asyncAfter(deadline: .now() + SetupWizard.trustHintAfter) { [weak self] in
                    guard let self, self.lastSetupCode == "trust_needed", self.setupRunning else { return }
                    self.setupStatus?.stringValue = SetupWizard.trustHint
                }
            } else if now - (trustWaitStarted ?? now) >= SetupWizard.trustHintAfter {
                setupStatus?.stringValue = SetupWizard.trustHint
            }
        } else { trustWaitStarted = nil }
        updateSetupPrompt(SetupWizard.needsIPadAction(result.code) ? result : nil)
        onboarding?.setupCode(result.code, final: false, ipados: result.ipados,
                              deviceClass: result.deviceClass, osVersion: result.osVersion)
        refreshMenuStatus()
    }

    private func setupFinished(_ result: SetupWizard.Result) {
        guard !uninstalling else { return }
        ignoreKeyboardEventsThrough = ProcessInfo.processInfo.systemUptime
        _ = core.observe(KeyMonitor.modifiers(), at: ignoreKeyboardEventsThrough, allowNewCapture: false)
        lastSetupCode = result.code
        setupDeviceHash = nil
        setupDeviceClass = result.deviceClass   // the device just seen, or nil
        // Read committed target.json, including USB-only pairing; progress is not proof of pairing.
        refreshPairedDevice()
        setupButtons.first?.title = hasPairing ? L("Check", "检查") : L("Pair", "配对")
        setupButtons.forEach { $0.isEnabled = true }
        setupStatus?.stringValue = SetupWizard.message(for: result)
        updateSetupPrompt(nil)
        if result.code == "ready" { UserDefaults.standard.set(true, forKey: OnboardingPolicy.wirelessKey) }
        if result.code == "wifi_unreachable" { UserDefaults.standard.set(false, forKey: OnboardingPolicy.wirelessKey) }
        onboarding?.setupCode(result.code, final: true, ipados: result.ipados,
                              deviceClass: result.deviceClass ?? pairedDeviceClass, osVersion: result.osVersion)
        setupDeviceClass = nil
        updateDeviceCopy()
        refreshMenuStatus()
        recordDiagnosticEvent()
        rewarmWorker(after: 0.5)
        // Paired with only USB working still turns the shortcuts on: Toss is never left dead,
        // but the onboarding stays on its wireless step and the status stays grey.
        guard result.code == "ready" || (result.code == "wifi_unreachable" && hasPairing) else { return }
        if permissionsReady { autoEnableIfFirstRun() }
        else if onboarding?.isVisible != true { lastPermissionStep = "accessibility"; requestMissingPermissions() }
    }

    // Steps only the user can do on the iPad appear as a prompt on the settings
    // window. It closes by itself as soon as the step is done.
    private func updateSetupPrompt(_ result: SetupWizard.Result?) {
        guard !uninstalling, uninstallSheet == nil else { return }
        // The onboarding shows these steps on its own screens instead of alerts.
        let result = onboarding?.isVisible == true ? nil : result
        if let prompt = setupPrompt {
            if let result, prompt.messageText == SetupWizard.title(for: result.code) {
                prompt.informativeText = SetupWizard.message(for: result)
                return
            }
            setupPrompt = nil
            settingsWindow?.endSheet(prompt.window)
        }
        guard let result, let window = settingsWindow else { return }
        showSettingsWindowOnly()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = SetupWizard.title(for: result.code)
        alert.informativeText = SetupWizard.message(for: result)
        alert.addButton(withTitle: L("OK", "好"))
        setupPrompt = alert
        alert.beginSheetModal(for: window) { [weak self] _ in
            if self?.setupPrompt === alert { self?.setupPrompt = nil }
        }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func showSettingsWindowOnly() {
        NSApp.setActivationPolicy(.regular)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding (step-by-step first setup)

    @objc private func openOnboarding() {
        guard !core.isBusy else { return }
        usbSetupPolicy.markPresented()
        if !setupWizard.isRunning {
            // Copy first: the guide draws on reset and redraws a step only when its status changes.
            setupDeviceClass = nil
            guideAwaitsDevice = true
            updateDeviceCopy()
            let controller = onboarding ?? makeOnboarding()
            controller.resetForDeviceSetup()
        }
        showOnboarding()
    }

    // System Settings → Menu Bar (macOS 26: the Control Center settings extension).
    private func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    // After setup: if the icon is hidden at launch, show the one menu-bar step, once per launch.
    private var menuIconPromptShown = false
    private func checkMenuIconSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.menuIconPromptShown, self.onboarding == nil,
                  let state = self.menuStatus?.iconVisibility(), state != .visible else { return }
            self.menuIconPromptShown = true
            prepareInterfaceAndShowMenuStep(state)
        }
        func prepareInterfaceAndShowMenuStep(_ state: MenuIconVisibility) {
            NSApp.setActivationPolicy(.regular)
            let controller = onboarding ?? makeOnboarding()
            controller.setMenuIcon(state)
            controller.showMenuBarOnly()
            controller.show()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // While the onboarding waits on Accessibility, record both checks once per change, to see which one
    // macOS keeps stale inside a running process (2026-10-29: a grant was seen only after a relaunch).
    private var lastPermissionLog: String?
    private var freshCheckRunning = false
    private var lastFreshCheck = 0.0

    // macOS may keep a running process's Accessibility answer stale after a grant (seen after
    // Uninstall.command reset it). A child process reads it fresh; when it says granted while this
    // process still says no, Toss relaunches itself into step 2, which then shows the tick.
    private func checkGrantFromFreshProcess() {
        guard onboarding?.isVisible == true, !permissionsReady, !freshCheckRunning,
              let executable = Bundle.main.executablePath else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFreshCheck >= 2 else { return }
        lastFreshCheck = now
        freshCheckRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--check-accessibility"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var output = ""
            if (try? process.run()) != nil {
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < deadline { usleep(50_000) }
                if process.isRunning { process.terminate() }
                output = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            }
            DispatchQueue.main.async { self?.freshCheckFinished(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    private func freshCheckFinished(_ output: String) {
        guard !uninstalling else { return }
        freshCheckRunning = false
        guard output == "ax=true post=true", onboarding?.isVisible == true, !permissionsReady else { return }
        // One automatic relaunch per two minutes, so a disagreement can never loop; "Reopen Toss" stays.
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: OnboardingPolicy.autoRelaunchKey)
        guard Date().timeIntervalSince1970 - last > 120 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: OnboardingPolicy.autoRelaunchKey)
        defaults.set(true, forKey: OnboardingPolicy.resumeAccessKey)
        defaults.synchronize()
        lastPermissionLog = nil
        appendPermissionLog("fresh process: \(output); relaunching")
        onboarding?.showRelaunching()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.relaunch() }
    }
    private func logPermissionCheck() {
        guard onboarding?.isVisible == true else { return }
        let line = "ax=\(AXIsProcessTrusted()) post=\(CGPreflightPostEventAccess())"
        guard line != lastPermissionLog else { return }
        lastPermissionLog = line
        appendPermissionLog(line)
    }
    private func appendPermissionLog(_ line: String) {
        guard !uninstalling else { return }
        let file = base.appendingPathComponent("permission-checks.log")
        let entry = ISO8601DateFormatter().string(from: Date()) + " pid=\(getpid()) " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
        } else {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? Data(entry.utf8).write(to: file)
        }
    }

    private func showOnboarding() {
        guard !uninstalling else { return }
        #if TOSS_RENDER
        if let opened = RenderState.onOpenInterface { opened("setup"); return }
        #endif
        prepareInterface()
        NSApp.setActivationPolicy(.regular)
        let controller = onboarding ?? makeOnboarding()
        controller.setAccessibility(permissionsReady)
        // Back from "Reopen Toss": continue on the Accessibility step.
        if UserDefaults.standard.bool(forKey: OnboardingPolicy.resumeAccessKey) {
            UserDefaults.standard.removeObject(forKey: OnboardingPolicy.resumeAccessKey)
            if controller.flow.step == .welcome { controller.jump(to: .access) }
        }
        // A pairing already running shows on its step, but never skips the Accessibility step.
        if setupWizard.isRunning, permissionsReady, controller.flow.step.rawValue < OnboardingStep.cable.rawValue {
            controller.jump(to: .cable)
            controller.setupCode(lastSetupCode, final: false, ipados: nil, deviceClass: setupDeviceClass)
        }
        updateSetupPrompt(nil)
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
        if !permissionsReady { startPermissionWatch() }
    }

    private func makeOnboarding() -> OnboardingController {
        let controller = OnboardingController()
        controller.setDeviceClass(pairedDeviceClass)
        controller.onRequestAccessibility = { [weak self] in self?.requestAccessibility() }
        controller.onStartSetup = { [weak self] in
            guard let self else { return }
            let running = self.setupWizard.isRunning
            self.startSetup(action: "auto")
            // startSetup can refuse (a capture in progress, runtime missing): fail the step instead of waiting forever.
            if !running && !self.setupWizard.isRunning {
                self.onboarding?.setupCode("setup_unavailable", final: true, ipados: nil)
            }
        }
        controller.onCableOnly = { [weak self] in
            guard self?.uninstalling == false else { return }
            UserDefaults.standard.set(false, forKey: OnboardingPolicy.wirelessKey)
        }
        controller.menuIconProbe = { [weak self] in self?.menuStatus?.iconVisibility() ?? .visible }
        controller.onOpenMenuBarSettings = { [weak self] in self?.openMenuBarSettings() }
        controller.setupRunningProbe = { [weak self] in self?.setupWizard.isRunning == true }
        controller.onCancelSetup = { [weak self] in
            guard let self, self.setupWizard.isRunning else { return }
            self.runSetup()
        }
        controller.onReopen = { [weak self] in
            guard self?.uninstalling == false else { return }
            UserDefaults.standard.set(true, forKey: OnboardingPolicy.resumeAccessKey)
            UserDefaults.standard.synchronize()
            self?.relaunch()
        }
        controller.onFinish = {}
        // Closing it any way (done, cable only, or early) never cancels a running pairing and never
        // reopens it at the next launch; "Set Up iPad…" under More opens it again.
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            let dismissedAutomatic = self.usbSetupPolicy.closed(
                terminating: self.terminating || self.uninstalling,
                completed: controller?.flow.step == .done, paired: self.pairedUSBSetupHashes())
            if !self.terminating, dismissedAutomatic || OnboardingPolicy.closeMarksSeen(step: controller?.flow.step ?? .done) {
                UserDefaults.standard.set(true, forKey: OnboardingPolicy.seenKey)
            }
            self.onboarding = nil
            self.guideAwaitsDevice = false
            self.updateDeviceCopy()
            if self.hasPairing && self.permissionsReady { self.autoEnableIfFirstRun() }
            self.refreshSettingsUI()
            self.refreshMenuStatus()
        }
        onboarding = controller
        return controller
    }

    @objc private func forgetDevice() {
        guard !uninstalling else { return }
        guard !setupWizard.isRunning, !hasActiveWork, let config = try? runtimeConfiguration(),
              let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/setup_device.py").path,
              let primary = pairedDeviceClass else { return }
        var kinds: [DeviceClass] = [primary]
        if pairedDeviceClasses.count == 2 {
            let choose = NSAlert()
            choose.messageText = L("Forget which device?", "忘记哪一台？")
            choose.informativeText = L("Forgetting one leaves the other paired.", "只忘一台时，另一台不受影响。")
            choose.addButton(withTitle: "iPad"); choose.addButton(withTitle: "iPhone")
            choose.addButton(withTitle: L("Forget Both", "都忘掉"))
            choose.addButton(withTitle: L("Cancel", "取消"))
            switch choose.runModal() {
            case .alertFirstButtonReturn: kinds = [.iPad]
            case .alertSecondButtonReturn: kinds = [.iPhone]
            case .alertThirdButtonReturn: kinds = [.iPad, .iPhone]
            default: return
            }
        }
        let alert = NSAlert()
        if kinds.count == 2 {
            alert.messageText = L("Forget both devices?", "两台都忘掉？")
            alert.informativeText = L("This removes the pairing files for the iPad and the iPhone from this Mac. You will need to pair again via USB. Trust settings on both devices are unchanged.",
                                      "会删掉这台 Mac 上 iPad 和 iPhone 的配对文件，之后要用数据线重新配对。两台上的「信任」设置不变。")
            alert.addButton(withTitle: L("Forget Both", "都忘掉"))
        } else {
            let kind = kinds[0]
            alert.messageText = L("Forget this \(kind.displayName)?", "忘记这台 \(kind.displayName)？")
            alert.informativeText = L("This removes its pairing files from this Mac. You will need to pair again via USB. Trust settings on the \(kind.displayName) are unchanged.",
                                      "会删掉这台 Mac 上它的配对文件，之后要用数据线重新配对。\(kind.displayName) 上的「信任」设置不变。")
            alert.addButton(withTitle: L("Forget", "忘记"))
        }
        alert.addButton(withTitle: L("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for kind in kinds {
            captureWorkers[kind]?.stop()
            deviceWakers[kind]?.setKeepAlive(false)
        }
        forget(kinds, python: config.python, script: script, stateDirectory: config.state_dir)
    }

    /// Forgets the devices one after another (the wizard runs one process at a time),
    /// then shows one status line for the whole request.
    private func forget(_ kinds: [DeviceClass], python: String, script: String, stateDirectory: String) {
        guard let kind = kinds.first else { return }
        let forgottenHash = pairedUSBSetupHashes()[kind.rawValue]
        setupWizard.run(python: python, script: script, action: "forget", stateDirectory: stateDirectory,
                        deviceClass: kind) { [weak self] result in
            guard let self else { return }
            if result.code == "not_paired", let forgottenHash { self.usbSetupPolicy.forget(forgottenHash) }
            let rest = Array(kinds.dropFirst())
            if result.code == "not_paired", !rest.isEmpty {
                self.forget(rest, python: python, script: script, stateDirectory: stateDirectory)
                return
            }
            self.refreshPairedDevice()
            if result.code == "not_paired" {
                self.setupDeviceClass = nil
                self.updateDeviceCopy()
                self.onboarding?.setDeviceClass(self.pairedDeviceClass)
                self.lastSetupCode = "forgotten"
                self.setupAutoStarted = false
                self.setupStatus?.stringValue = self.pairedDeviceClasses.isEmpty
                    ? L("Forgotten. Plug in and unlock to pair again.", "已忘记。插线解锁就会重新配对。")
                    : L("Forgot this \(kind.displayName).", "已忘记这台 \(kind.displayName)。")
                if self.pairedDeviceClasses.isEmpty {
                    self.startup.rememberEnabled(false)
                    self.stop(reason: L("Device forgotten. Pair again before enabling shortcuts.", "已忘记这台设备。重新配对后再打开快捷键。"))
                    UserDefaults.standard.removeObject(forKey: OnboardingPolicy.wirelessKey)
                }
            } else { self.setupStatus?.stringValue = SetupWizard.message(for: result) }
            self.refreshMenuStatus()
            self.rewarmWorker(after: 0)
        }
    }

    private func startCapture(_ request: HotkeyRequest) {
        settlePendingClipboard()
        // Keep the iPad's radio awake while the screenshot request goes out.
        iPadWaker.poke()
        captureAnimation.begin(requestID: request.id)
        updateTransferNotice()
        // Every composer can lose the user's intent while capture/AX work runs.
        // Record navigation/edit interactions from before locating it until paste.
        newDraftInteraction.start()
        failureCategory = "none"
        backendReason = "none"
        backendTimings = [:]
        connectionReused = nil
        let kind: TargetKind = DualHotkeyCore.chord(of: request.id) == .options ? .chatGPT : .claude
        targetKind = kind
        if captureRecord == nil || diagnosticRequestStartedAt != request.startedAt {
            if captureRecord != nil { finishCaptureRecord(outcome: "unfinished") }
            captureRecord = CaptureRecord(
                startedAt: Date(timeIntervalSinceNow: request.startedAt - ProcessInfo.processInfo.systemUptime),
                target: kind.rawValue)
            captureRecord?.deviceClass = selectedDeviceClass(requestID: request.id)?.rawValue
        }
        diagnosticRequestStartedAt = request.startedAt
        let config: TossConfiguration
        do { config = try configuration() } catch { captureSetupFailed(request, error); return }
        let queued = startingQueuedPress
        startingQueuedPress = false
        if queued { captureRecord?.queued = queuedBindings[request.startedAt] == nil ? "unbound" : "bound" }
        // A queued press often starts while the previous paste is still settling in the same chat
        // (2026-10-28 11:47: three Claude presses failed at once on a transient dialog layer), so
        // it always goes through the retrying locate below; the activation step is a no-op then.
        if !queued, ActivationPolicy.isReady(TargetActivator.observe(kind)) {
            do {
                setStatus(L("Checking the current window and chat…", "正在检查当前窗口和聊天…"), code: "locating_target")
                // Speed (提速副本): ask the iPad now, so the screenshot RPC runs
                // while locateLease() reads the chat, instead of after it. The
                // result is still used only once the lease exists and passes
                // every check below; on any failure it is discarded.
                startEarlyCapture(request, config: config)
                guard core.activeRequestID == request.id else { return }
                try beginCapture(request, kind: kind, config: config, lease: targetFor(kind).locateLease())
                return
            } catch TargetFailure.currentThreadUnavailable {
                // The editor can be present before its focus-dependent current
                // row is published. Continue through capture-only focus recovery.
            } catch { captureSetupFailed(request, error); return }
        }
        // 0.7.1: another app (or Space, a minimized/hidden window) is in front.
        // Jump to the target's own focused window first; the lease checks below
        // are unchanged and still refuse anything they cannot prove.
        setStatus(L("Switching to \(kind.displayName)…", "正在切换到 \(kind.displayName)…"), code: "activating_target")
        // A failed fast locate already owns this screenshot. Keep that request,
        // including a second tap's device selection; never issue a replacement RPC.
        if earlyCapture?.id != request.id { startEarlyCapture(request, config: config) }
        guard core.activeRequestID == request.id else { return }
        let task = Task { @MainActor [weak self] in
            do {
                // Clicks, typing or scrolling never abandon the keypress (Ashley 2026-10-28):
                // the paste still goes to the chat the shortcut was pressed for.
                let outcome = try await TargetActivator.bringForward(kind, shouldContinue: { [weak self] in self != nil })
                guard let self, self.isCurrentActivation(request.id) else { return }
                switch outcome {
                case .alreadyFront, .activated: break
                case .launched: throw TossError.targetLaunched
                case .failed: throw TossError.activationFailed
                }
                self.setStatus(L("Checking the current window and chat…", "正在检查当前窗口和聊天…"), code: "locating_target")
                var lease = try await self.locateAfterActivation(kind, queued: queued)
                guard self.isCurrentActivation(request.id) else { return }
                // A queued press whose chat was switched away: go back to that chat first. If that
                // cannot be proven, beginCapture marks it and the picture goes to the clipboard instead.
                if let bound = self.queuedBindings[request.startedAt], !bound.sameDestination(as: lease) {
                    let target = self.targetFor(kind)
                    self.setStatus(L("Going back to the chat you pressed in…", "正在回到你按快捷键时的聊天…"), code: "locating_target")
                    var current = lease
                    let back = try await QueuedDestinationPolicy.restore(
                        isBound: { current = try target.locateLease(); return bound.sameDestination(as: current) },
                        raiseWindow: { try await target.raiseLeaseWindow(bound) },
                        openConversation: { try target.openLeaseConversation(bound) },
                        pause: { try await Task.sleep(nanoseconds: 120_000_000) })
                    guard self.isCurrentActivation(request.id) else { return }
                    if back { lease = current }
                    self.captureRecord?.queued = back ? "bound-returned" : "bound-not-provable"
                }
                self.activationTask = nil
                // Its own catch: once activationTask is cleared and a transaction exists, the
                // outer catch's isCurrentActivation() is false and would drop the error, leaving
                // the keypress hanging silently until the 45 s core timeout (2026-10-24 16:46).
                do { try self.beginCapture(request, kind: kind, config: config, lease: lease) }
                catch { self.captureSetupFailed(request, error) }
            } catch {
                guard let self, self.isCurrentActivation(request.id) else { return }
                self.activationTask = nil
                self.captureSetupFailed(request, error)
            }
        }
        activationTask = (request.id, task)
    }

    private func isCurrentActivation(_ id: UInt64) -> Bool {
        enabled && activationTask?.id == id && transaction == nil && core.activeRequestID == id
    }

    private func cancelActivation() {
        activationTask?.task.cancel()
        activationTask = nil
        discardEarlyCapture()
    }

    // A worker still busy with an abandoned request is stopped, so this keypress gets a
    // fresh one; a request that belongs to a live keypress is never touched.
    private func releaseAbandonedCapture() {
        let kind = activeDeviceClass
        if let abandoned = abandonedCaptureIDs[kind], captureWorker.pendingRequestID == abandoned { captureWorker.stop() }
        abandonedCaptureIDs.removeValue(forKey: kind)
    }

    private func startEarlyCapture(_ request: HotkeyRequest, config: TossConfiguration) {
        guard let deviceClass = selectedDeviceClass(requestID: request.id) else { return }
        // Adopt the one result belonging to this press. Freshness is measured at receipt;
        // delayed UI delivery never authorizes a second screenshot.
        if let prefetch = queuedPrefetch, prefetch.pressedAt == request.startedAt {
            // Adopt the in-flight request too: targeting must not wait for its bytes.
            queuedPrefetch = nil
            prefetchRequest = request
            adoptedPrefetchArrivedAt = prefetch.arrivedAt
            let adopted = prefetch.capture
            earlyCapture = EarlyCapture(id: request.id, uuid: adopted.uuid, image: adopted.image,
                deviceClass: adopted.deviceClass, result: adopted.result, receivedAt: adopted.receivedAt, queueFailureHandled: adopted.queueFailureHandled)
            if let result = adopted.result,
               finishEarlyCaptureFailure(request, data: result.data, exitCode: result.exitCode) { return }
            refreshMenuStatus()
            return
        }
        if capturePipeline.delivering != nil {
            captureSetupFailed(request, TossError.captureFailed)
            return
        }
        discardQueuedPrefetch()
        releaseAbandonedCapture()
        let uuid = UUID().uuidString.lowercased()
        let image = cache.appendingPathComponent(deviceClass.captureFilename(uuid: uuid))
        do {
            try captureWorker.capture(configuration: workerConfiguration(config),
                requestID: uuid, file: image, timeout: 40) { [weak self] data, exitCode in
                    guard let self, !self.uninstalling else { return }
                    self.deliverCaptureResult(request, uuid: uuid, image: image, data: data, exitCode: exitCode)
                }
            earlyCapture = EarlyCapture(id: request.id, uuid: uuid, image: image, deviceClass: deviceClass)
            refreshMenuStatus()
        } catch {
            // Worker busy/unavailable: beginCapture() requests it after locate.
            earlyCapture = nil
        }
    }

    private func discardEarlyCapture() {
        guard !uninstalling else { return }
        guard let early = earlyCapture else { return }
        earlyCapture = nil
        earlyTargetFailure = nil
        abandonedCaptureIDs[early.deviceClass] = early.uuid
        // Speed (提速副本): an unanswered request no longer stops the worker.
        // Stopping it threw away the authenticated iPad connection, so the next
        // keypress paid a multi-second reconnect. The late receipt is ignored
        // and its file deleted by the completion in startEarlyCapture().
        try? fm.removeItem(at: early.image)
    }

    // Retain the original lease/activation task. Only the screenshot generation changes.
    private func retargetCapture(_ request: HotkeyRequest) {
        guard core.activeRequestID == request.id, transaction?.pastePosted != true,
              transaction?.clipboard == nil, let config = try? configuration() else { return }
        let previous = transaction
        let targetFailure = earlyTargetFailure
        if let previous {
            abandonedCaptureIDs[previous.deviceClass] = previous.uuid
            try? fm.removeItem(at: previous.image)
            transaction = nil
        }
        discardEarlyCapture()
        slowCaptureID = nil
        backendTimings = [:]
        connectionReused = nil
        startEarlyCapture(request, config: config)
        earlyTargetFailure = targetFailure
        if earlyTargetFailure != nil { finishTargetlessCapture(); return }
        if let previous {
            do {
                try beginCapture(request, kind: previous.kind, config: config, lease: previous.lease)
                transaction?.destinationChanged = previous.destinationChanged
            } catch { captureSetupFailed(request, error) }
        }
    }

    // A fast speculative result (including a failure) cannot escape before selection closes.
    // The UUID check also drops a late iPad result after the same request switched to iPhone.
    private func deliverCaptureResult(_ request: HotkeyRequest, uuid: String, image: URL,
                                      data: Data, exitCode: Int32) {
        guard !uninstalling else { return }
        guard core.activeRequestID == request.id,
              (transaction?.id == request.id && transaction?.uuid == uuid) ||
                (earlyCapture?.id == request.id && earlyCapture?.uuid == uuid) else {
            try? fm.removeItem(at: image)
            return
        }
        let delay = selectionDeadline(pressedAt: request.startedAt) - ProcessInfo.processInfo.systemUptime
        if delay > 0 {
            if earlyCapture?.uuid == uuid { earlyCapture?.result = (data, exitCode) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.deliverCaptureResult(request, uuid: uuid, image: image, data: data, exitCode: exitCode)
            }
            return
        }
        if transaction?.uuid == uuid {
            guard transaction?.receipt == nil else { return }
            captureReturned(request, data: data, exitCode: exitCode)
        } else if !finishEarlyCaptureFailure(request, data: data, exitCode: exitCode) {
            earlyCapture?.result = (data, exitCode)
        }
    }

    // Right after activation (or a Space switch) the web view may still be
    // publishing its window/AX tree. Only these not-yet-visible failures are
    // re-read, briefly; a found composer or chat is never second-guessed.
    private func locateAfterActivation(_ kind: TargetKind, queued: Bool = false) async throws -> any ChatLease {
        var settling: Set<TargetFailure> = [.windowUnavailable, .windowsAmbiguous, .treeUnavailable,
            .webAreaUnavailable, .composerUnavailable, .composersAmbiguous, .conversationUnavailable]
        // A queued press: the previous paste may still hold a short-lived dialog layer; wait up to
        // ~1.2 s for it. A dialog that stays is still refused (nothing is pasted under it).
        if queued { settling.insert(.modalPresent) }
        let attempts = QueuedDestinationPolicy.locateAttempts(queued: queued)
        var attempt = 0
        while true {
            do {
                return try await targetFor(kind).locateForCaptureLease(shouldContinue: { [weak self] pid in
                    guard let self else { return false }
                    return self.enabled && self.newDraftInteraction.isObserving &&
                        !self.newDraftInteraction.interventionPIDs.contains(pid)
                })
            }
            catch let error as TargetFailure where attempt < attempts && settling.contains(error) {
                attempt += 1
                try await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    // The busy-repeat that queued a press: bind it to the running toss's chat when that is provably
    // where it was pressed: same target app, and the interaction watch saw no click, scroll or key
    // since that chat was checked (refocus restarts the watch after pulling the chat back). Otherwise
    // nothing is bound and the press uses its app's current chat when its turn comes, as in v21.1.
    private func bindQueuedPress() {
        guard let pressed = core.queue.last, queuedBindings[pressed.at] == nil else { return }
        if let tx = transaction { burstLeases[tx.kind == .chatGPT ? .options : .shifts] = tx.lease }
        let source = burstLeases[pressed.chord]
        let watch = newDraftInteraction.isObserving ? newDraftInteraction : appendInteraction
        guard QueuedDestinationPolicy.binds(sourceAvailable: source != nil, watchObserving: watch.isObserving,
                                            inputInTargetApp: source.map { watch.interventionPIDs.contains($0.pid) } ?? true),
              let source else { return }
        queuedBindings[pressed.at] = source
    }

    private func beginCapture(_ request: HotkeyRequest, kind: TargetKind, config: TossConfiguration,
                              lease: any ChatLease) throws {
        guard let deviceClass = selectedDeviceClass(requestID: request.id) else { throw TossError.configuration }
        DeviceCopy.deviceClass = deviceClass.rawValue
        setStatus(L("Chat verified. Preparing to capture your \(deviceEN)…", "聊天确认好了，准备截取 \(deviceZH)…"), code: "target_located")
        let bound = queuedBindings.removeValue(forKey: request.startedAt)
        let destinationChanged = deliveryBindingMissing || QueuedDestinationPolicy.outcome(bound: bound != nil,
            sameDestination: bound?.sameDestination(as: lease) ?? false) == .manualPaste
        if !destinationChanged { burstLeases[kind == .chatGPT ? .options : .shifts] = lease }
        adoptedPrefetchArrivedAt = nil
        if let early = earlyCapture, early.id == request.id {
            earlyCapture = nil
            transaction = Transaction(id: request.id, uuid: early.uuid, lease: lease, kind: kind,
                                      image: early.image, deviceClass: early.deviceClass)
            transaction?.destinationChanged = destinationChanged
            transaction?.receivedAt = early.receivedAt
            startEarlyFocus(request.id, kind: kind, lease: lease)
            showCaptureStatus(requestID: early.uuid)
            if let result = early.result {
                deliverCaptureResult(request, uuid: early.uuid, image: early.image, data: result.data, exitCode: result.exitCode)
            }
            return
        }
        guard capturePipeline.delivering == nil else { throw TossError.captureFailed }
        let uuid = UUID().uuidString.lowercased()
        let image = cache.appendingPathComponent(deviceClass.captureFilename(uuid: uuid))
        transaction = Transaction(id: request.id, uuid: uuid, lease: lease, kind: kind,
                                  image: image, deviceClass: deviceClass)
        transaction?.destinationChanged = destinationChanged
        startEarlyFocus(request.id, kind: kind, lease: lease)
        releaseAbandonedCapture()
        try captureWorker.capture(configuration: workerConfiguration(config),
            requestID: uuid, file: image, timeout: 40) { [weak self] data, exitCode in
                guard let self else { return }
                guard self.transaction?.id == request.id, self.transaction?.uuid == uuid else {
                    try? self.fm.removeItem(at: image); return
                }
                self.deliverCaptureResult(request, uuid: uuid, image: image, data: data, exitCode: exitCode)
            }
        showCaptureStatus(requestID: uuid)
    }

    private func showCaptureStatus(requestID: String) {
        if slowCaptureID == requestID {
            setStatus(L("Screenshot is taking longer. Still waiting for your \(deviceEN)…", "截图比平时慢，还在等 \(deviceZH)…"), code: "capture_slow")
        } else {
            setStatus(L("Capturing a new \(deviceEN) screenshot…", "正在截取 \(deviceZH) 屏幕…"), code: "capturing")
        }
    }

    private func startEarlyFocus(_ id: UInt64, kind: TargetKind, lease: any ChatLease) {
        earlyFocusTask?.task.cancel()
        let chatTarget = targetFor(kind)
        earlyFocusTask = (id, Task { @MainActor [weak self] in
            guard self?.transaction?.id == id else { return }
            // Best effort: beginAppend() focuses (and fully checks) again anyway.
            try? await chatTarget.focusLease(lease)
        })
    }

    private func captureSetupFailed(_ request: HotkeyRequest, _ error: Error) {
        // Target discovery and capture now overlap. If discovery fails, keep the
        // accepted screenshot until it arrives, then validate it and offer manual paste.
        if let early = earlyCapture, early.id == request.id, capturePipeline.delivering != nil,
           !(error is CancellationError), (error as? TossError) != .cancelled {
            activationTask?.task.cancel(); activationTask = nil
            earlyTargetFailure = (request, error)
            finishTargetlessCapture()
            return
        }
        // The early iPad request now also starts when the chat is already in
        // front; a failed locate must not leave it attached to this keypress.
        discardEarlyCapture()
        newDraftInteraction.stop()
        if Self.isQuietInterruption(error) {
            interruptTransaction(request.id, error: error, cancelWorker: false)
            startQueuedPress()
            return
        }
        handle(core.captureFailed(requestID: request.id, at: ProcessInfo.processInfo.systemUptime))
        failure(error, code: "capture_setup_failed", cue: true)
        startQueuedPress() // no transaction existed, so cleanup() will not start the queue
    }

    private func finishTargetlessCapture() {
        guard let failed = earlyTargetFailure, let early = earlyCapture, let result = early.result else { return }
        let delay = selectionDeadline(pressedAt: failed.request.startedAt) - ProcessInfo.processInfo.systemUptime
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.finishTargetlessCapture() }
            return
        }
        earlyTargetFailure = nil
        recordCaptureReceipt(result.data)
        do {
            _ = try CaptureReceipt.validate(json: result.data, exitCode: result.exitCode,
                requestID: early.uuid, triggeredAt: failed.request.startedAt,
                now: early.receivedAt ?? ProcessInfo.processInfo.systemUptime, file: early.image, deviceClass: early.deviceClass)
            let clipboard = try ClipboardTransaction.continuing(inheritedClipboard)
            try clipboard.publish(file: early.image)
            try clipboard.validate()
            inheritedClipboard = clipboard
            manualDeliveryPaused = true
            earlyCapture = nil // keep the validated file for the manual paste
            cleanup(cancelProcess: false)
            failure(failed.error, code: "copied_for_manual_paste", cue: true)
        } catch {
            discardEarlyCapture()
            cleanup(cancelProcess: false)
            failure(error, code: "capture_result_failed", cue: true)
        }
    }

    private func workerConfiguration(_ config: TossConfiguration, deviceClass: DeviceClass? = nil) throws -> CaptureWorker.Configuration {
        guard !runtimeQuarantined else { throw TossError.backendUnavailable }
        guard let backend = Bundle.main.resourceURL?.appendingPathComponent("Backend/capture_service.py"),
              fm.fileExists(atPath: backend.path) else { throw TossError.backendUnavailable }
        return .init(python: config.python, script: backend.path,
                     stateDirectory: config.state_dir, outputDirectory: cache.path,
                     deviceClass: (deviceClass ?? activeDeviceClass).rawValue)
    }

    private func recordCaptureReceipt(_ data: Data) {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reason = object["reason"] as? String,
           reason.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil {
            backendReason = reason
            if let times = object["timings_ms"] as? [String: Any] {
                // link_*: passive per-transfer timeline (Backend/link_timeline.py), measurement only.
                for key in ["attempts", "connect", "screenshot", "validation", "total",
                            "link_first_byte", "link_rx_kb", "link_stalls", "link_stall_max", "link_stall_total",
                            "link_rx_ooo_kb", "link_tx_retx", "link_rtt", "link_stall_unsent", "link_stall_rto",
                            "link_projected_finish", "reconnect_in_progress", "session_reused",
                            "rpc_fragment_count", "rpc_first_fragment", "rpc_last_fragment",
                            "slow_threshold", "slow_sample_count", "slow_threshold_exempt"] {
                    if let value = times[key] as? Double, value.isFinite, value >= 0, value <= 60_000 {
                        backendTimings[key] = value
                    }
                }
            }
            connectionReused = object["connection_reused"] as? Bool
            captureRecord?.takeImage(from: object)
            // The worker that answered, so a double press is not recorded under its first device.
            if let device = (object["device_class"] as? String).flatMap(DeviceClass.init(rawValue:)) {
                captureRecord?.deviceClass = device.rawValue
            }
        }
    }

    private func captureFailureReason(_ data: Data, exitCode: Int32, requestID: String) -> String? {
        guard case .failure(let reason) = CaptureCompletionPolicy.classify(data, exitCode: exitCode, requestID: requestID)
        else { return nil }
        return reason
    }

    // A screenshot can fail while the target app is still activating. Report it now,
    // without waiting for a chat lease (or allowing that late lease to restart the press).
    @discardableResult
    private func finishEarlyCaptureFailure(_ request: HotkeyRequest, data: Data, exitCode: Int32) -> Bool {
        guard ProcessInfo.processInfo.systemUptime >= selectionDeadline(pressedAt: request.startedAt) else { return false }
        guard let early = earlyCapture, early.id == request.id,
              let reason = CaptureCompletionPolicy.failureBeforeTarget(
                CaptureCompletionPolicy.classify(data, exitCode: exitCode, requestID: early.uuid),
                activeRequestMatches: core.activeRequestID == request.id, transactionExists: transaction != nil)
        else { return false }
        recordCaptureReceipt(data)
        if !early.queueFailureHandled { endUncapturedQueuedPresses(after: reason) }
        cancelActivation()
        newDraftInteraction.stop()
        handle(core.captureFailed(requestID: request.id, at: ProcessInfo.processInfo.systemUptime))
        failure(TossError.captureFailed, code: "capture_result_failed", cue: true)
        startQueuedPress()
        return true
    }

    private func captureReturned(_ request: HotkeyRequest, data: Data, exitCode: Int32) {
        guard let tx = transaction, tx.id == request.id, core.activeRequestID == request.id else { return }
        do {
            recordCaptureReceipt(data)
            transaction?.receipt = try CaptureReceipt.validate(json: data, exitCode: exitCode,
                requestID: tx.uuid, triggeredAt: request.startedAt,
                now: tx.receivedAt ?? ProcessInfo.processInfo.systemUptime, file: tx.image, deviceClass: tx.deviceClass)
            setStatus(L("Screenshot received. Rechecking the current chat…", "截图收到了，再确认一下当前聊天…"), code: "revalidating_capture")
            // 0.7.1: no full tree read here. The full lease (window, chat, draft,
            // attachments, focus) is validated once more right before the sole
            // Cmd+V; reading it here as well only delayed the paste.
            setStatus(L("Screenshot captured. Verifying the target…", "截图完成，正在确认目标…"), code: "captured")
            captureAnimation.captured(requestID: request.id, image: tx.image)
            handle(core.captureSucceeded(requestID: request.id, imageToken: tx.uuid,
                                         at: ProcessInfo.processInfo.systemUptime))
            prefetchQueuedScreenshot() // the worker is free again
        } catch {
            if Self.isQuietInterruption(error) {
                // The fresh RPC has already completed. A draft edit should not
                // discard the healthy authenticated connection for the next keypress.
                interruptTransaction(request.id, error: error, cancelWorker: false)
                return
            }
            endUncapturedQueuedPresses(after: backendReason)
            handle(core.captureFailed(requestID: request.id, at: ProcessInfo.processInfo.systemUptime))
            failure(error, code: "capture_result_failed", cue: true)
        }
    }

    private func beginAppend(_ request: HotkeyRequest, token: String) {
        guard let tx = transaction, tx.id == request.id, tx.uuid == token else { return }
        let chatTarget = targetFor(tx.kind)
        appendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var postedDeadline: TimeInterval?
            do {
                self.setStatus(L("Checking focus in the message composer…", "正在确认输入框…"), code: "focusing_composer")
                // Queued press, and its chat is not the one it was pressed in: keep the picture on the
                // clipboard with the manual-paste notice (option b) rather than paste into this chat.
                if self.transaction?.destinationChanged == true { throw TargetFailure.conversationChanged }
                if let early = self.earlyFocusTask, early.id == tx.id { await early.task.value }
                self.earlyFocusTask = nil
                // If the user switched apps or clicked elsewhere while the screenshot was on its way,
                // bring the original chat back first; focusLease alone fails when another app is in
                // front and would drop to the manual-paste fallback (Ashley: paste in the original place).
                try await self.refocusIfUserMoved(tx, chatTarget)
                // focus() checks focus cheaply; the full lease check runs right before Cmd+V.
                try await self.retryingSettlingTree(tx) { try await chatTarget.focusLease(tx.lease) }
                try Task.checkCancellation()
                guard self.enabled, self.transaction?.id == tx.id else { throw TossError.cancelled }
                try await self.waitForReleasedKeys(tx)
                try await self.refocusIfUserMoved(tx, chatTarget)
                // A previous Cmd+V that was never confirmed may still be waiting in a busy target:
                // publishing this picture at once could let that late paste insert it (a double
                // paste). Give it the same 1.5 s an attachment normally needs to show up.
                if let posted = self.unconfirmedPasteAt {
                    let wait = posted + 1.5 - ProcessInfo.processInfo.systemUptime
                    if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    self.unconfirmedPasteAt = nil
                    try Task.checkCancellation()
                    guard self.enabled, self.transaction?.id == tx.id else { throw TossError.cancelled }
                }
                let clipboard = try ClipboardTransaction.continuing(self.inheritedClipboard)
                self.inheritedClipboard = nil
                self.transaction?.clipboard = clipboard
                try clipboard.publish(file: tx.image)
                var foregroundRetries = 0
                while true {
                    try await self.waitForReleasedKeys(tx)
                    try await self.refocusIfUserMoved(tx, chatTarget)
                    try await self.retryingSettlingTree(tx) { try chatTarget.revalidateLease(tx.lease, requireFocused: true) }
                    try clipboard.validate()
                    try Task.checkCancellation()
                    try self.validatePasteLifetime(tx)
                    // AX reads can take time while another physical Option chord
                    // begins. A rejected preflight has emitted NO event; only that
                    // specific rejection may wait again. A posted paste never retries.
                    do {
                        self.appendInteraction.start()
                        // Early start: the tiles already there predict the new one's slot. Read now,
                        // before the paste can add the new tile; about 2-3 ms, bounded.
                        if UserDefaults.standard.bool(forKey: AttachmentSighting.defaultsKey), predictedSlot == nil,
                           let existing = AttachmentSighting.existingTiles(composer: tx.lease.composerElement) {
                            let composer = AttachmentSighting.composerFrame(tx.lease.composerElement)
                            prePaste = composer.map { ($0, existing.tiles) }
                            let memory = AttachmentSighting.loadMemory(tx.kind == .claude ? "claude" : "codex")
                            slotMemory = memory
                            predictedSlot = AttachmentSighting.predictedSlot(tiles: existing.tiles, rowRight: existing.rowRight,
                                composer: composer, memory: memory)
                            // Why a slot was or was not predicted, for the diagnostics line.
                            predictionNote = String(format: "tiles=%d; memory=%@; width=%.0f/%.0f; gap=%@",
                                existing.tiles.count, memory == nil ? "no" : "yes", composer?.width ?? -1,
                                memory?.composerWidth ?? -1, memory?.gap.map { String(format: "%.0f", $0) } ?? "-")
                        }
                        self.captureAnimation.shieldPointer(requestID: tx.id)
                        try PasteKeystroke.postOnce(to: tx.lease.pid)
                        break
                    } catch TossError.keysStillPressed {
                        self.transaction?.waitedForKeys = true
                        self.appendInteraction.stop()
                        try await Task.sleep(nanoseconds: 16_000_000)
                    } catch TossError.foregroundChanged where foregroundRetries < QueuedDestinationPolicy.foregroundRetriesBeforePaste {
                        // No event was posted. The loop top brings the chat back and re-verifies the
                        // focused composer before the next and only Cmd+V.
                        foregroundRetries += 1
                        self.appendInteraction.stop()
                        try await Task.sleep(nanoseconds: 60_000_000)
                    }
                }
                self.transaction?.pastePosted = true
                self.lastPastePostedAt = ProcessInfo.processInfo.systemUptime
                self.newDraftInteraction.stop()
                self.setStatus(L("Paste requested. Checking the attachment…", "已经粘贴，正在检查附件…"), code: "paste_posted")
                // Early start (off unless jellyEarlyStart): land the jelly the moment the new tile
                // is seen; the sound and ✓ still wait for the full confirmation below.
                if UserDefaults.standard.bool(forKey: AttachmentSighting.defaultsKey) {
                    let id = tx.id, pid = tx.lease.pid, kind = tx.kind
                    let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let look = CaptureTileLook.forTarget(claude: kind == .claude, darkAppearance: dark)
                    // A predicted slot goes up now, before the app draws the tile; the stable
                    // sighting below confirms or corrects it (> 2 pt off: moved at once).
                    if let slot = predictedSlot {
                        self.captureAnimation.sighted(requestID: id, destinationAXFrame: self.landingFrame(slot, claude: kind == .claude, tiles: self.prePaste?.tiles ?? []), targetPID: pid, look: look)
                    }
                    let predicted = predictedSlot
                    predictedSlot = nil
                    self.sighter.start(composer: tx.lease.composerElement, filename: tx.image.lastPathComponent) { rect, _, settle in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.transaction?.id == id else { return }
                            self.setStatus(L("Attachment seen. Confirming it…", "看到附件了，正在确认…"), code: "attachment_sighted")
                            self.firstTileRaw = rect
                            let moved = self.captureAnimation.settle(requestID: id, destinationAXFrame: self.landingFrame(rect, claude: kind == .claude, tiles: self.prePaste?.tiles ?? []), targetPID: pid, look: look)
                            self.earlyLandingNote = String(format: "predicted=%@; moved_pt=%@; settle_ms=%.0f; %@",
                                predicted == nil ? "no" : "yes", moved.map { String(format: "%.1f", $0) } ?? "-", settle * 1000,
                                self.predictionNote)
                        }
                    }
                }
                var confirmed = false
                let confirmationDeadline = ProcessInfo.processInfo.systemUptime + 8
                postedDeadline = confirmationDeadline
                // Speed: first read ~60 ms after Cmd+V, then every 20 ms until 1.2 s, then
                // every 150 ms. Same 8 s deadline. (Was 100 ms / 40 ms: on 2026-10-24 the
                // new tile was on screen 100-170 ms before the jelly could cover it.)
                let fastPollUntil = ProcessInfo.processInfo.systemUptime + 1.2
                var pollDelay: UInt64 = 20_000_000
                try await Task.sleep(nanoseconds: 60_000_000)
                while ProcessInfo.processInfo.systemUptime < confirmationDeadline {
                    try Task.checkCancellation()
                    guard self.transaction?.id == tx.id else { throw TossError.cancelled }
                    // Right after Cmd+V the web view rebuilds its AX tree; a read that
                    // finds it mid-update is retried (read-only) until the deadline.
                    // Every other failure still stops at once; the paste is never repeated.
                    let readback: AppendReadback
                    do {
                        readback = try chatTarget.verifyAppendLease(tx.lease, expectedFilename: tx.image.lastPathComponent)
                    } catch TargetFailure.treeUnavailable {
                        readback = .pending
                    }
                    if readback == .confirmed {
                        if !AppendConfirmationPolicy.acceptsConfirmed(isNewDraft: tx.lease.isNewDraft,
                                observing: self.appendInteraction.isObserving, intervened: self.appendInteraction.intervened) {
                            throw TossError.interactionInterrupted
                        }
                        self.appendInteractionNote = self.appendInteraction.note
                        confirmed = true
                        break
                    }
                    // A pending native attachment may be checked again; a
                    // changed target/draft or any error still stops immediately.
                    // Check once now instead of always delaying success 250 ms.
                    let remaining = confirmationDeadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { break }
                    try await Task.sleep(nanoseconds: min(pollDelay, UInt64(remaining * 1_000_000_000)))
                    pollDelay = ProcessInfo.processInfo.systemUptime < fastPollUntil ? 20_000_000 : 150_000_000
                }
                guard confirmed else {
                    // Keep the original bounded readback period even when a
                    // click/delete happens between reads. Another request must
                    // not replace a possibly unconsumed pasteboard prematurely.
                    if self.appendInteraction.intervened { throw TossError.interactionInterrupted }
                    throw TossError.unconfirmed
                }
                self.transaction?.appendConfirmed = true
                self.transaction?.pasteConsumptionConfirmed = true
                self.sighter.cancel()
                let prePasteTiles = self.prePaste?.tiles ?? []
                let chatCard = tx.kind == .chatGPT ? self.chatGPTTarget.latestConfirmedChatCard : nil
                let followsChatCard = chatCard != nil
                // Chat can shift the existing tile during the whole landing.
                // Other layouts keep the short, size-only growth probe.
                if let confirmedTile = chatTarget.latestConfirmedAttachmentFrame {
                    let id = tx.id, claude = tx.kind == .claude, app = claude ? "claude" : "codex"
                    let before = self.prePaste, first = self.firstTileRaw ?? confirmedTile
                    let source = followsChatCard ? "chat-card" : (self.slotMemory?.finalWidth == nil ? "observed" : "memory")
                    // Codex tiles never grow; a Claude card ends at its remembered size (unknown: no early release).
                    let expectedFinal: CGSize? = claude
                        ? AttachmentSighting.loadMemory(app).flatMap { m in m.finalWidth.flatMap { w in m.finalHeight.map { CGSize(width: w, height: $0) } } }
                        : confirmedTile.size
                    self.landingSettle.begin(id)
                    self.grower.follow(composer: tx.lease.composerElement, filename: tx.image.lastPathComponent,
                                       from: confirmedTile, duration: followsChatCard ? CaptureCardTiming.landingTotal + 0.1 : 0.6,
                                       expectedFinal: expectedFinal, trackingCard: chatCard) { rect in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if followsChatCard { self.captureAnimation.followConfirmedChatCard(requestID: id, frameAX: rect) }
                            else { self.captureAnimation.grow(requestID: id, toAX: self.landingFrame(rect, claude: claude, tiles: prePasteTiles)) }
                        }
                    } settled: {
                        DispatchQueue.main.async { [weak self] in self?.landingSettle.settle(id) }
                    } lost: {
                        DispatchQueue.main.async { [weak self] in
                            self?.captureAnimation.followConfirmedChatCard(requestID: id, frameAX: nil)
                        }
                    } done: { final, settledAt in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if !followsChatCard, let before, let learned = AttachmentSighting.learn(AttachmentSighting.loadMemory(app),
                                    composer: before.composer, tiles: before.tiles, confirmed: final, first: first) {
                                AttachmentSighting.saveMemory(learned, app: app)
                            }
                            let g = AttachmentSighting.growth(first: first, final: final)
                            self.growthNote = String(format: "sighted=%.0fx%.0f; final=%.0fx%.0f; anchor=%@; ms=%.0f; source=%@",
                                first.width, first.height, final.width, final.height,
                                g.map { String(format: "left%.2f/down%.2f", $0.left, $0.down) } ?? "none",
                                settledAt * 1000, source)
                            if followsChatCard {
                                self.growthNote += String(format: "; moved=%.0fx%.0f",
                                    abs(final.minX - confirmedTile.minX), abs(final.minY - confirmedTile.minY))
                            }
                        }
                    }
                }
                self.firstTileRaw = nil
                self.prePaste = nil
                // Result order (Ashley 2026-10-24 "好慢"): the sound first, at once; then the
                // toast; then the jelly, whose window setup (~20 ms) must not delay the sound.
                // Only an acknowledged native attachment earns this cue. Audio
                // failure must not change success or retry the paste. Use this
                // transaction's verified file size, even when later captures are ready.
                let soundTier = SuccessSound.forFileSize(tx.receipt?.byteCount)
                self.lastSuccessSound = soundTier
                self.lastSuccessSoundBytes = tx.receipt?.byteCount
                self.playResultCue(self.successSounds[soundTier] ?? self.successSounds[.small])
                self.onboarding?.tossed()
                // The ✓ toast shows only when "Show notifications" is on.
                let result = ToastContent.success(target: tx.kind)
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                self.captureAnimation.confirmed(requestID: tx.id,
                    destinationAXFrame: chatTarget.latestConfirmedAttachmentFrame.map {
                        followsChatCard ? $0 : self.landingFrame($0, claude: tx.kind == .claude, tiles: prePasteTiles)
                    },
                    targetPID: tx.lease.pid,
                    look: CaptureTileLook.forTarget(claude: tx.kind == .claude, darkAppearance: dark),
                    title: result.title,
                    toastHold: self.toastPreferences.enabled ? result.holdDuration : nil)
                self.core.appendFinished(requestID: tx.id)
                self.cleanup(cancelProcess: false)
                self.setStatus(L("Attachment confirmed. The message has not been sent.", "附件已确认。消息还没发送。"), code: "append_confirmed")
            } catch {
                // A cancelled old task must never clean up a newer transaction.
                guard self.transaction?.id == tx.id else { return }
                // The chat the shortcut was pressed for is gone or cannot take a paste (another chat
                // opened, text selected, a dialog): keep the screenshot on the clipboard instead of
                // dropping it, and say so. Never pasted anywhere else.
                if Self.leavesForManualPaste(error) || Self.isQuietInterruption(error) {
                    if self.preserveReceivedCapture(error: error) { return }
                }
                if Self.isQuietInterruption(error) {
                    if self.transaction?.pastePosted == true {
                        let consumed = chatTarget.latestPasteConsumptionConfirmed &&
                            chatTarget.latestPasteConsumptionFilename == tx.image.lastPathComponent
                        self.transaction?.pasteConsumptionConfirmed = consumed
                        if !consumed, let postedDeadline {
                            self.captureAnimation.cancel(requestID: tx.id)
                            self.failureCategory = "none"
                            self.setStatus(L("The draft changed. Finishing without retrying.", "草稿变了，结束，不重试。"), code: "input_interrupted")
                            let remaining = max(0, postedDeadline - ProcessInfo.processInfo.systemUptime)
                            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                            guard self.transaction?.id == tx.id else { return }
                        }
                    }
                    self.interruptTransaction(tx.id, error: error, cancelWorker: false)
                    return
                }
                // The card stays: failure() collapses it into the result (or dismisses it).
                let wasPosted = self.transaction?.pastePosted == true
                self.core.appendFinished(requestID: tx.id)
                self.cleanup(cancelProcess: false)
                if wasPosted {
                    self.failure(error, code: "append_unconfirmed", cue: true)
                } else { self.failure(error, code: "append_failed", cue: true) }
            }
        }
    }

    // When the chat was behind another app, its web view may still be rebuilding
    // the AX tree as focus and the pre-paste check run (2026-10-24: treeUnavailable
    // 40–80 ms into focusing). Before Cmd+V only, a read that finds the tree
    // mid-update is retried briefly within the paste lifetime, like
    // locateAfterActivation; every other failure still stops at once.
    private func retryingSettlingTree(_ tx: Transaction, _ body: () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do { return try await body() }
            catch TargetFailure.treeUnavailable where attempt < 5 {
                attempt += 1
                try validatePasteLifetime(tx)
                try await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    private func waitForReleasedKeys(_ tx: Transaction) async throws {
        while true {
            try Task.checkCancellation()
            guard enabled, transaction?.id == tx.id else { throw TossError.cancelled }
            try validatePasteLifetime(tx)
            if KeyMonitor.keys().allReleased { return }
            transaction?.waitedForKeys = true
            // Poll HID without blocking the main run loop or accepting a second
            // request. Every resume is followed by full target/draft validation.
            try await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private func validatePasteLifetime(_ tx: Transaction) throws {
        guard let receipt = transaction?.receipt else { throw TossError.invalidCapture }
        let now = ProcessInfo.processInfo.systemUptime
        guard core.pasteIsCurrent(requestID: tx.id, at: now), now < receipt.expiresAt else {
            if transaction?.waitedForKeys == true { throw TossError.keysStillPressed }
            throw TossError.invalidCapture
        }
    }

    private static func isQuietInterruption(_ error: Error) -> Bool {
        if let error = error as? TargetFailure {
            switch error {
            case .draftChanged, .selectedText: return true
            default: return false
            }
        }
        if let error = error as? TossError {
            switch error {
            case .keysStillPressed, .interactionInterrupted, .cancelled: return true
            default: return false
            }
        }
        return error is CancellationError
    }

    private func interruptTransaction(_ id: UInt64, error: Error, cancelWorker: Bool) {
        let posted = transaction?.id == id && transaction?.pastePosted == true
        captureAnimation.interrupt(requestID: id)
        cleanup(cancelProcess: cancelWorker)
        failureCategory = "none"
        setStatus(posted ? L("The draft changed. Attachment not confirmed; no retry was made.", "草稿变了，附件没能确认，没有重试。") :
            L("Keys or draft changed. Cancelled; release the keys before trying again.", "按键或草稿变了，已取消。松开按键再试。"), code: "input_interrupted")
    }

    // The user clicked, typed or scrolled since the last focus (Ashley 2026-10-28: never give
    // up, paste in the original place): bring the leased window back and put the keyboard in
    // the leased composer again. The lease check right before Cmd+V still refuses another chat.
    private func refocusIfUserMoved(_ tx: Transaction, _ chatTarget: ChatTarget) async throws {
        // She may click the other app again while Toss brings the chat back (2026-10-28 13:29): try a
        // few times, then give up to the manual-paste path; Cmd+V still needs the verified composer.
        for attempt in 1...QueuedDestinationPolicy.refocusAttempts {
            guard newDraftInteraction.intervened || NSWorkspace.shared.frontmostApplication?.processIdentifier != tx.lease.pid
            else { return }
            newDraftInteraction.start() // restarts the watch, clearing the flag
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != tx.lease.pid {
                _ = try await TargetActivator.bringForward(tx.kind)
            }
            do {
                try await retryingSettlingTree(tx) { try await chatTarget.focusLease(tx.lease) }
                return
            } catch let error as TargetFailure where attempt < QueuedDestinationPolicy.refocusAttempts
                        && (error == .focusFailed || error == .targetChanged)
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier != tx.lease.pid {
                try await Task.sleep(nanoseconds: 120_000_000) // another app took the front again
            }
        }
    }

    private func preserveReceivedCapture(error: Error) -> Bool {
        guard let tx = transaction,
              CapturedImageRecoveryPolicy.preserve(validated: tx.receipt != nil,
                pastePosted: tx.pastePosted,
                explicitlyCancelled: error is CancellationError || (error as? TossError) == .cancelled),
              leaveForManualPaste() else { return false }
        // Do not overwrite the manual-paste clipboard or discard other completed frames.
        // The user's next explicit shortcut resumes their delivery.
        manualDeliveryPaused = true
        core.appendFinished(requestID: tx.id)
        cleanup(cancelProcess: false)
        failure(error, code: "copied_for_manual_paste", cue: true)
        return true
    }

    private static func leavesForManualPaste(_ error: Error) -> Bool {
        if let error = error as? TargetFailure {
            switch error {
            case .targetChanged, .conversationChanged, .windowUnavailable, .windowsAmbiguous, .focusFailed,
                 .selectedText, .modalPresent, .draftChanged, .composerUnavailable, .webAreaUnavailable:
                return true
            default: return false
            }
        }
        if let error = error as? TossError { return error == .foregroundChanged || error == .keysStillPressed || error == .invalidCapture || error == .interactionInterrupted }
        return false
    }

    // Publishes the screenshot (if the paste had not got that far) and marks it to stay on the
    // clipboard. The user's own clipboard is carried to the next keypress, as for an
    // unconfirmed paste, and restored there.
    private func leaveForManualPaste() -> Bool {
        guard let tx = transaction else { return false }
        do {
            let clipboard: ClipboardTransaction
            if let existing = tx.clipboard { clipboard = existing } else {
                clipboard = try ClipboardTransaction.continuing(inheritedClipboard)
                inheritedClipboard = nil
                try clipboard.publish(file: tx.image)
                transaction?.clipboard = clipboard
            }
            try clipboard.validate()
            transaction?.leftForManualPaste = true
            return true
        } catch { return false }
    }

    // Only read the old lease. Never focus, navigate or post a second paste. Never blocks the
    // new keypress: a paste that is still unproven hands its saved clipboard to this one.
    private func settlePendingClipboard() {
        guard let pending = pendingClipboard else { return }
        pendingClipboard = nil
        let terminated = NSRunningApplication(processIdentifier: pending.lease.pid)?.isTerminated != false
        var consumed = pending.safeToRestore
        if pending.clipboard.isStillOwned && !terminated && !consumed {
            let target = targetFor(pending.kind)
            _ = try? target.verifyAppendLease(pending.lease, expectedFilename: pending.filename)
            consumed = target.latestPasteConsumptionConfirmed && target.latestPasteConsumptionFilename == pending.filename
        }
        if !pending.clipboard.finish(pastePosted: true, consumptionConfirmed: consumed,
                                     targetTerminated: terminated) {
            inheritedClipboard = pending.clipboard
        }
        if consumed || terminated { unconfirmedPasteAt = nil } // the old paste has landed or cannot
    }

    private func cleanup(cancelProcess: Bool) {
        guard !uninstalling else { return }
        sighter.cancel()
        predictedSlot = nil
        cancelActivation()
        earlyFocusTask?.task.cancel()
        earlyFocusTask = nil
        newDraftInteraction.stop()
        appendInteraction.stop()
        if cancelProcess && capturePipeline.delivering == nil {
            // Stopping the worker drops the queued press's in-flight screenshot without an
            // answer; forget it so that press captures afresh instead of waiting for it.
            if let prefetch = queuedPrefetch, prefetch.capture.result == nil {
                discardQueuedPrefetch()
            }
            captureWorker.stop()
            rewarmWorker(after: 0.5)
        }
        // Readback may prove consumption and then throw (e.g. draft text changed).
        // Preserve that receipt for every exit path, including cancellation.
        if let tx = transaction, let clipboard = tx.clipboard, tx.leftForManualPaste {
            inheritedClipboard = clipboard
        } else if let tx = transaction, let clipboard = tx.clipboard {
            let target = targetFor(tx.kind)
            let consumed = tx.pasteConsumptionConfirmed ||
                (target.latestPasteConsumptionConfirmed && target.latestPasteConsumptionFilename == tx.image.lastPathComponent)
            let terminated = NSRunningApplication(processIdentifier: tx.lease.pid)?.isTerminated != false
            if !clipboard.finish(pastePosted: tx.pastePosted, consumptionConfirmed: consumed,
                                 targetTerminated: terminated) {
                pendingClipboard = (clipboard, tx.lease, tx.kind, tx.image.lastPathComponent,
                                    !tx.pastePosted || consumed || terminated)
                if tx.pastePosted && !consumed && !terminated { unconfirmedPasteAt = lastPastePostedAt }
            }
        }
        if let tx = transaction, !tx.pastePosted, !tx.leftForManualPaste { try? fm.removeItem(at: tx.image) }
        // Posted images stay private for 24 hours: do not remove a file while the
        // native app may still read it. No recording or continuous capture occurs.
        transaction = nil
        earlyTargetFailure = nil
        slowCaptureID = nil
        ignoreKeyboardEventsThrough = ProcessInfo.processInfo.systemUptime
        _ = core.reset(keepQueue: true)
        if !capturePipeline.isBusy { burstLeases.removeAll() } // the burst is over
        // A fresh HID baseline can arm only if Options are actually released.
        // Held/busy chords still require their subsequent complete release.
        _ = core.observe(KeyMonitor.modifiers(), at: ignoreKeyboardEventsThrough, allowNewCapture: false)
        refreshMenuStatus()
        startQueuedPress()
    }

    // Reserve targeting as soon as a transfer starts; the worker callback joins
    // that reservation. The next transfer can overlap this press's paste/readback.
    private func startQueuedPress(waited: Double = 0) {
        if waited == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.startQueuedPress(waited: 1) }
            return
        }
        guard enabled, !manualDeliveryPaused, transaction == nil, activationTask == nil, !core.isBusy else { return }
        if let delivered = capturePipeline.delivering {
            queuedBindings.removeValue(forKey: delivered.at)
            pipelineCaptures.removeValue(forKey: delivered.id)
            if let uuid = deliveryCaptureID {
                slowPipelineIDs.remove(uuid); pipelineProgress.removeValue(forKey: uuid)
            }
            deliveryCaptureID = nil
            capturePipeline.deliveryFinished()
        }
        pumpCaptures()
        // Held keys only postpone Cmd+V, never activation or locating the chat.
        guard let press = capturePipeline.takeForTargeting(), let saved = pipelineCaptures.removeValue(forKey: press.id) else {
            if !capturePipeline.isBusy { burstLeases.removeAll() }
            updateTransferNotice()
            refreshMenuStatus()
            writeLastRun()
            return
        }
        deliveryCaptureID = saved.uuid
        deliveryBindingMissing = CapturePipeline.bindingMissing(queued: press.queued,
            hasBinding: queuedBindings[press.at] != nil)
        queuedPrefetch = (saved, press.at, saved.receivedAt)
        if captureAnimation.isLanding { captureAnimation.detachLanding() }
        captureAnimation.detachToast()
        startingQueuedPress = press.queued
        let actions = core.beginDelivery(chord: press.chord, pressedAt: press.at, at: ProcessInfo.processInfo.systemUptime)
        handle(actions)
        startingQueuedPress = false
    }

    private func prefetchQueuedScreenshot() { pumpCaptures() }

    private func selectionDeadline(pressedAt: Double) -> Double {
        max(deviceGesture.selectionDeadline(pressedAt: pressedAt), core.selectionDeadline(pressedAt: pressedAt))
    }

    private func selectCapture(_ chord: HotkeyChord, at: Double) {
        guard let primary = singlePressDevice else { return }
        switch deviceGesture.observe(chord, at: at, primary: primary, dual: pairedDeviceClasses.count == 2) {
        case .capture(let chord, let at, let deviceClass):
            deferredDeviceSelection = nil
            if !admitCapture(chord, at: at, deviceClass: deviceClass), pairedDeviceClasses.count == 2 {
                // A full lane must not prevent the second tap from selecting the
                // other device's independent lane. This is intent only, not a queue slot.
                let kind: TargetKind = chord == .options ? .chatGPT : .claude
                deferredDeviceSelection = (chord, at, try? targetFor(kind).locateLease())
            }
        case .retarget(let at): retargetPipelineCapture(at: at)
        case .consumed: break
        }
    }

    // A black screenshot means that device is off: hand the press to the other one, once, if it is connected.
    private func fallBackFromBlackFrame(_ press: DeviceCapturePipeline.Press, uuid: String, data: Data, exit: Int32) -> Bool {
        let other = press.deviceClass.other
        blackFramePresses = blackFramePresses.filter { press.at - $0 < 60 }
        guard pairedDeviceClasses.count == 2,
              captureFailureReason(data, exitCode: exit, requestID: uuid) == "black_frame_rejected",
              captureWorkers[other]?.connectionStatus.state == .ready,
              captureWorkers[other]?.deviceLocked != true,
              !(capturePipeline.delivering?.id == press.id && (transaction?.pastePosted == true || transaction?.clipboard != nil)),
              blackFramePresses.insert(press.at).inserted else { return false }
        pipelineProgress.removeValue(forKey: uuid); slowPipelineIDs.remove(uuid)
        retargetPipelineCapture(at: press.at, to: other)
        return true
    }

    // USB data dropped: wait out a brief re-attach, then ask the device over Wi-Fi whether it still has power.
    private func checkUSBDrop(_ kind: DeviceClass) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.uninstalling, !self.setupWizard.isRunning,
                  self.captureWorkers[kind]?.usbConnected == false,
                  !self.usbDropChecks.contains(kind),
                  let config = try? self.configuration(),
                  let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/usb_power_check.py").path else { return }
            self.usbDropChecks.insert(kind)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: config.python)
            process.arguments = ["-B", script, "--state-dir", config.state_dir, "--device-class", kind.rawValue]
            process.environment = CaptureWorkerProcess.backendEnvironment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            // The helper bounds itself and exits on its own watchdog; this is the outer limit.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var powered: Bool?
                if (try? process.run()) != nil {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if process.isRunning { process.terminate() } }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    powered = object?["external_connected"] as? Bool
                }
                let reading = powered
                DispatchQueue.main.async {
                    self?.usbDropChecks.remove(kind)
                    self?.finishUSBDropCheck(kind, powered: reading)
                }
            }
        }
    }

    private func finishUSBDropCheck(_ kind: DeviceClass, powered: Bool?) {
        guard !uninstalling, usbDropNotice.shouldShow(kind, externalConnected: powered,
            usbBack: captureWorkers[kind]?.usbConnected == true, at: ProcessInfo.processInfo.systemUptime) else { return }
        let name = kind.rawValue
        let title = L("\(name) USB dropped\nReplug; resume charging if paused", "\(name) 的 USB 断了\n重插一下；暂停充电的话先恢复")
        captureAnimation.showTransferNotice(title)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.updateTransferNotice() }
    }

    private func retargetPipelineCapture(at: Double, to device: DeviceClass? = nil) {
        guard let old = capturePipeline.press(at: at) else {
            if let selection = deferredDeviceSelection, selection.at == at {
                deferredDeviceSelection = nil
                admitCapture(selection.chord, at: at, deviceClass: doublePressDevice, binding: selection.lease, bindingCaptured: true)
            }
            return
        }
        let target = device ?? doublePressDevice
        guard old.deviceClass != target else { return }
        let wasDelivering = capturePipeline.delivering?.id == old.id
        if wasDelivering, transaction?.pastePosted == true || transaction?.clipboard != nil { return }
        if let saved = pipelineCaptures.removeValue(forKey: old.id) {
            try? fm.removeItem(at: saved.image)
            slowPipelineIDs.remove(saved.uuid); pipelineProgress.removeValue(forKey: saved.uuid)
        }
        _ = capturePipeline.remove(at: at)
        guard let next = capturePipeline.admit(old.chord, at: at, deviceClass: target, queued: old.queued) else {
            queuedBindings.removeValue(forKey: at)
            if wasDelivering {
                cancelActivation()
                if let tx = transaction { try? fm.removeItem(at: tx.image); captureAnimation.cancel(requestID: tx.id) }
                transaction = nil; prefetchRequest = nil; queuedPrefetch = nil; deliveryCaptureID = nil
                _ = core.reset(keepQueue: true)
            }
            captureAnimation.showTransferNotice(L("Busy — try again shortly", "忙着传图，请稍后再试"))
            startQueuedPress()
            return
        }
        if wasDelivering, capturePipeline.reserveForTargeting(next.id),
           let request = core.recaptureDelivery(at: ProcessInfo.processInfo.systemUptime) {
            // Keep the original lease/activation; only the screenshot UUID/device changes.
            let uuid = UUID().uuidString.lowercased()
            let image = cache.appendingPathComponent(next.deviceClass.captureFilename(uuid: uuid))
            let saved = EarlyCapture(id: next.id, uuid: uuid, image: image, deviceClass: next.deviceClass)
            pipelineCaptures[next.id] = saved
            deliveryCaptureID = uuid
            queuedPrefetch = (saved, at, nil)
            retargetCapture(request)
        }
        pumpCaptures()
        startQueuedPress(waited: 1)
        updateTransferNotice()
    }

    @discardableResult
    private func admitCapture(_ chord: HotkeyChord, at: Double, deviceClass: DeviceClass,
                              binding: (any ChatLease)? = nil, bindingCaptured: Bool = false) -> Bool {
        if manualDeliveryPaused { manualDeliveryPaused = false; startQueuedPress() }
        guard let press = capturePipeline.admit(chord, at: at, deviceClass: deviceClass) else {
            menuStatus?.nudge()
            captureAnimation.showTransferNotice(L("Busy — try again shortly", "忙着传图，请稍后再试"))
            return false
        }
        if capturePipeline.running.count + capturePipeline.waitingCount > 1 { busyRepeatsTotal += 1 }
        pumpCaptures()
        // A busy press binds at admission. The first press uses the ordinary
        // activate/locate path immediately, including when its app is in the back.
        if press.queued {
            let kind: TargetKind = chord == .options ? .chatGPT : .claude
            if bindingCaptured { queuedBindings[press.at] = binding }
            else if let lease = try? targetFor(kind).locateLease() { queuedBindings[press.at] = lease }
        }
        startQueuedPress(waited: 1)
        updateTransferNotice()
        return true
    }

    private func pumpCaptures() {
        guard enabled else { return }
        let busy = Set(captureWorkers.filter { $0.value.isBusy }.map { $0.key })
        for (_, press) in capturePipeline.startAvailable(excluding: busy) {
            let uuid = pipelineCaptures[press.id]?.uuid ?? UUID().uuidString.lowercased()
            let file = cache.appendingPathComponent(press.deviceClass.captureFilename(uuid: uuid))
            pipelineCaptures[press.id] = EarlyCapture(id: press.id, uuid: uuid, image: file, deviceClass: press.deviceClass)
            if capturePipeline.delivering?.id == press.id { pipelineCaptures.removeValue(forKey: press.id) }

            // A second tap can still change the device. For a known blocked
            // press, wait for that choice before trying to start a transfer.
            let delay = selectionDeadline(pressedAt: press.at) - ProcessInfo.processInfo.systemUptime
            if delay > 0, lockedAlternate(for: press.deviceClass) != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.capturePipeline.running[press.deviceClass]?.id == press.id else { return }
                    guard self.pipelineCaptures[press.id]?.uuid == uuid ||
                        (self.deliveryCaptureID == uuid && self.core.isBusy) else {
                        self.capturePipeline.remove(at: press.at)
                        self.pumpCaptures()
                        self.startQueuedPress()
                        return
                    }
                    self.startPipelineCapture(press, uuid: uuid, file: file)
                }
            } else {
                startPipelineCapture(press, uuid: uuid, file: file)
            }
        }
        updateTransferNotice()
    }

    private func startPipelineCapture(_ press: DeviceCapturePipeline.Press, uuid: String, file: URL) {
        let slot = press.deviceClass
        guard enabled, !uninstalling, capturePipeline.running[slot]?.id == press.id else { return }
        func finishWithoutTransfer(reason: String) {
            let data = (try? JSONSerialization.data(withJSONObject: ["schema_version": 1,
                "request_id": uuid, "ok": false, "reason": reason, "device_class": slot.rawValue])) ?? Data()
            _ = capturePipeline.completed(press.id, slot: slot)
            receivePipelineCapture(press, uuid: uuid, data: data, exit: 1)
            DispatchQueue.main.async { [weak self] in self?.pumpCaptures(); self?.startQueuedPress() }
        }
        // Re-read the connection and lock state after the selection window.
        if lockedAlternate(for: slot) != nil {
            finishWithoutTransfer(reason: "alternate_device_locked")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CaptureProgressPolicy.noticeDelay) { [weak self] in
            guard let self, self.pipelineCaptures[press.id]?.uuid == uuid ||
                (self.deliveryCaptureID == uuid && self.core.isBusy) else { return }
            self.slowPipelineIDs.insert(uuid)
            self.updateTransferNotice()
        }
        let worker = captureWorkers[slot]!
        do {
            let config = try configuration()
            try worker.capture(configuration: workerConfiguration(config, deviceClass: slot), requestID: uuid, file: file) {
                [weak self] data, exit in
                guard let self else { try? FileManager.default.removeItem(at: file); return }
                guard !self.uninstalling else { return }
                guard self.capturePipeline.completed(press.id, slot: slot) else {
                    try? FileManager.default.removeItem(at: file)
                    self.pipelineProgress.removeValue(forKey: uuid); self.slowPipelineIDs.remove(uuid)
                    self.pumpCaptures(); self.startQueuedPress()
                    return
                }
                if self.fallBackFromBlackFrame(press, uuid: uuid, data: data, exit: exit) {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                self.receivePipelineCapture(press, uuid: uuid, data: data, exit: exit)
                if exit == 0, let progress = self.pipelineProgress[uuid], progress.expected > 0 {
                    self.pipelineProgress[uuid] = (progress.expected, progress.expected)
                }
                if let reason = self.captureFailureReason(data, exitCode: exit, requestID: uuid),
                   CaptureQueueFailurePolicy.affectsQueuedPresses(reason),
                   worker.connectionStatus.state == .failed {
                    for dropped in self.capturePipeline.disconnected(deviceClass: slot) { self.queuedBindings.removeValue(forKey: dropped.at) }
                }
                self.pumpCaptures()
                self.startQueuedPress()
            }
        } catch {
            finishWithoutTransfer(reason: "worker_failed")
        }
    }

    private func receivePipelineCapture(_ press: DeviceCapturePipeline.Press, uuid: String, data: Data, exit: Int32) {
        guard !uninstalling else { return }
        let arrived = ProcessInfo.processInfo.systemUptime
        if deliveryCaptureID == uuid, let request = prefetchRequest {
            if transaction?.uuid == uuid {
                transaction?.receivedAt = arrived
                deliverCaptureResult(request, uuid: uuid, image: transaction!.image, data: data, exitCode: exit)
            } else if earlyCapture?.uuid == uuid {
                earlyCapture?.result = (data, exit)
                earlyCapture?.receivedAt = arrived
                if earlyTargetFailure != nil { finishTargetlessCapture() }
                else { deliverCaptureResult(request, uuid: uuid, image: earlyCapture!.image, data: data, exitCode: exit) }
            }
        } else {
            pipelineCaptures[press.id]?.result = (data, exit)
            pipelineCaptures[press.id]?.receivedAt = arrived
        }
    }

    private func cancelPendingCaptures() {
        manualDeliveryPaused = false
        capturePipeline.reset()
        for saved in pipelineCaptures.values { try? fm.removeItem(at: saved.image) }
        pipelineCaptures.removeAll(); pipelineProgress.removeAll(); slowPipelineIDs.removeAll()
        deliveryCaptureID = nil; queuedBindings.removeAll()
        stopWorkers()
        deviceGesture.reset()
        deferredDeviceSelection = nil
        blackFramePresses.removeAll()
        captureAnimation.hideTransferNotice()
    }

    private func updateTransferNotice() {
        let candidates = capturePipeline.running.values.sorted { $0.at < $1.at } + capturePipeline.ready
        let current = deliveryCaptureID.flatMap { core.isBusy && slowPipelineIDs.contains($0) ? $0 : nil }
        let waiting = candidates.compactMap { pipelineCaptures[$0.id]?.uuid }
            .first { slowPipelineIDs.contains($0) }
        guard let uuid = current ?? waiting else { captureAnimation.hideTransferNotice(); return }
        let progress = pipelineProgress[uuid]
        let title = TransferNotice.text(received: progress?.received ?? 0,
            expected: progress?.expected ?? 0, queued: capturePipeline.waitingCount)
        captureAnimation.showTransferNotice(title, requestID: uuid) { [weak self] in
            guard let self, self.slowPipelineIDs.contains(uuid),
                  self.deliveryCaptureID == uuid || self.pipelineCaptures.values.contains(where: { $0.uuid == uuid }) else { return }
            self.cancelCurrent()
        }
        if !core.isBusy { setStatus(title.replacingOccurrences(of: "\n", with: " · "), code: "capture_slow") }
    }

    // Only a complete, valid image survives a link-wide failure. A pending request is
    // retired, not turned into a new 4.5-second request when its turn arrives.
    private func endUncapturedQueuedPresses(after reason: String, reportingFailureAt: Double? = nil,
                                           deviceClass: DeviceClass? = nil) {
        guard CaptureQueueFailurePolicy.affectsQueuedPresses(reason) else { return }
        var capturedAt: Double?
        if let prefetch = queuedPrefetch, let result = prefetch.capture.result,
           (try? CaptureReceipt.validate(json: result.data, exitCode: result.exitCode,
                requestID: prefetch.capture.uuid, triggeredAt: prefetch.pressedAt,
                now: ProcessInfo.processInfo.systemUptime, file: prefetch.capture.image,
                deviceClass: prefetch.capture.deviceClass)) != nil {
            capturedAt = prefetch.pressedAt
        }
        core.discardUncapturedQueuedPresses(after: reason, capturedAt: capturedAt,
            reportingFailureAt: reportingFailureAt,
            secondaryDevice: pairedDeviceClasses.count == 2 && (deviceClass ?? activeDeviceClass) == .iPhone)
        if let prefetch = queuedPrefetch, !core.queue.contains(where: { $0.at == prefetch.pressedAt }) {
            discardQueuedPrefetch()
            releaseAbandonedCapture()
        }
    }

    private func discardQueuedPrefetch() {
        guard let prefetch = queuedPrefetch else { return }
        queuedPrefetch = nil
        if prefetch.capture.result != nil { try? fm.removeItem(at: prefetch.capture.image) }
        else { abandonedCaptureIDs[prefetch.capture.deviceClass] = prefetch.capture.uuid } // removed on arrival; worker released below
    }

    private func stop(reason: String) {
        guard !uninstalling else { return }
        enableGeneration &+= 1
        enableTask?.cancel(); enableTask = nil
        enabled = false
        cancelPendingCaptures()
        chordDetector = CaptureChordDetector()
        enableFailureReason = nil
        timer?.invalidate(); timer = nil
        monitor.stop()
        appendTask?.cancel(); appendTask = nil
        handle(core.reset())
        discardQueuedPrefetch()
        queuedBindings.removeAll()
        burstLeases.removeAll()
        cleanup(cancelProcess: true)
        stopWorkers()
        deviceWakers.values.forEach { $0.setKeepAlive(false) }
        // Quit/disable: put back what the user had copied. These snapshots exist only in memory.
        if let pending = pendingClipboard { pending.clipboard.restoreIfStillOwned(); pendingClipboard = nil }
        inheritedClipboard?.restoreIfStillOwned(); inheritedClipboard = nil
        unconfirmedPasteAt = nil
        captureAnimation.dismiss()
        let title = startup.desiredEnabled ? L("Disable Auto-Resume", "关闭自动恢复") : L("Enable Shortcuts", "打开快捷键")
        toggleItem?.title = title
        windowToggle?.title = SettingsStyle.shortToggle(title)
        setStatus(reason, code: "stopped")
    }

    @objc private func cancelCurrent() {
        guard !uninstalling else { return }
        if enableTask != nil { stop(reason: L("Enabling cancelled", "已取消打开")); return }
        cancelPendingCaptures()
        chordDetector = CaptureChordDetector()
        appendTask?.cancel()
        handle(core.reset())
        cleanup(cancelProcess: true)
        captureAnimation.dismiss()
        setStatus(L("Cancelled. If paste was already requested, check your draft. No retry will be made.", "已取消。如果已经粘贴了，请看看草稿。不会自动重试。"), code: "cancelled")
    }

    // Authenticate the wireless connection ahead of the next keypress so it is
    // not paid for after the press. Connection only: never a screenshot.
    private func rewarmWorker(after delay: TimeInterval) {
        guard enabled, !sleeping else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Pairing owns the iPad link while it runs.
            guard let self, self.enabled, !self.sleeping, self.enableTask == nil,
                  !self.hasActiveWork, !self.anyWorkerBusy, !self.setupWizard.isRunning,
                  let config = try? self.configuration() else { return }
            // No-op for each healthy device; one offline device cannot replace the other.
            try? self.prepareWorkers(config)
        }
    }

    @objc private func willSleep() {
        sleeping = true
        // Do not carry an in-flight keypress or old wireless transport across
        // sleep. No wake path requests a screenshot.
        if hasActiveWork || transaction != nil || enableTask != nil { cancelCurrent() }
        stopWorkers()
        handle(core.reset())
        ignoreKeyboardEventsThrough = ProcessInfo.processInfo.systemUptime
    }

    @objc private func didWake() {
        sleeping = false
        // Discard a partial chord held across sleep. An interrupted enable may
        // restore the saved intent, but the baseline never requests a capture.
        guard enabled else { restoreIfPossible(); return }
        ignoreKeyboardEventsThrough = ProcessInfo.processInfo.systemUptime
        _ = core.reset()
        _ = core.observe(KeyMonitor.modifiers(), at: ignoreKeyboardEventsThrough, allowNewCapture: false)
        // Give Wi-Fi a moment to rejoin; discovery itself waits up to 12 s more.
        rewarmWorker(after: 2)
    }

    @objc private func checkTarget() {
        guard !hasActiveWork, enableTask == nil else { return }
        let kinds = runningTargetKinds()
        guard !kinds.isEmpty else { failure(TargetFailure.appUnavailable, code: "target_check_failed"); return }
        var lines: [String] = []
        for kind in kinds {
            targetKind = kind
            let name = kind == .chatGPT ? "ChatGPT／Codex" : "Claude"
            do {
                _ = try targetFor(kind).locateLease()
                lines.append("\(name): Verified one chat and message composer")
            } catch {
                lines.append("\(name)：" + ((error as? LocalizedError)?.errorDescription ?? L("Failed", "失败")))
            }
        }
        showAlert(L("Target Check", "目标检查"), lines.joined(separator: "\n") + L("\n\nNo screenshot was requested and no focus or draft was changed.", "\n\n没有截图，也没有改动焦点或草稿。"))
    }

    @objc private func requestAccessibility() {
        guard !uninstalling else { return }
        lastPermissionStep = "accessibility"
        startPermissionWatch()
        guard !hasActiveWork, enableTask == nil else {
            permissionHint?.stringValue = L("Finish or cancel the capture first.", "先等这次截图完成或取消。")
            return
        }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        refreshPermissions()
        openPermissionSettings("Privacy_Accessibility", name: L("Accessibility", "辅助功能"))
    }
    @objc private func requestInput() {
        guard !uninstalling else { return }
        lastPermissionStep = "input"
        startPermissionWatch()
        guard !hasActiveWork, enableTask == nil else {
            permissionHint?.stringValue = L("Finish or cancel the capture first.", "先等这次截图完成或取消。")
            return
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        refreshPermissions()
        // RequestListenEventAccess is only potentially prompting. Opening the
        // settings page is navigation, not a grant or an assertion of success.
        openPermissionSettings("Privacy_ListenEvent", name: L("Input Monitoring", "输入监控"))
    }
    @objc private func refreshPermissions() {
        let accessibility = AXIsProcessTrusted() ? L("Granted", "已允许") : L("Not ready", "未就绪")
        let post = CGPreflightPostEventAccess() ? L("Granted", "已允许") : L("Not ready", "未就绪")
        permissionStatus?.stringValue = L("Accessibility: \(accessibility)   Keyboard events: \(post)\nInput Monitoring is not required.", "辅助功能：\(accessibility)   键盘事件：\(post)\n不需要输入监控。")
        refreshSettingsUI()
        if initialInterfaceShown { restoreIfPossible() }
    }
    private func openPermissionSettings(_ pane: String, name: String) {
        permissionHint?.stringValue = L("Turn on Toss in Privacy & Security → \(name).", "在 隐私与安全性 → \(name) 里打开 Toss。")
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane),
              NSWorkspace.shared.open(url) else {
            permissionHint?.stringValue = L("Open Privacy & Security → \(name) yourself.", "请手动打开 隐私与安全性 → \(name)。")
            return
        }
    }
    @objc private func showInstructions() {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("User Guide.txt") { NSWorkspace.shared.open(url) }
    }
    private func exportLogs() {
        guard !uninstalling, !exportingLogs else { return }
        let destination = base.appendingPathComponent(LogExporter.exportsFolderName)
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            logExportNotice.show(success: false)
            return
        }
        exportingLogs = true
        menuStatus?.setExportingLogs(true)
        let support = base
        var app = LogExporter.AppInfo.current
        app.pairedDeviceTypes = pairedDeviceClasses.map { $0.rawValue }
        logExportQueue.async { [weak self] in
            let result = Result { () throws -> URL in
                let archive = try LogExporter().export(support: support, destination: destination, app: app)
                LogExporter.prune(destination)
                return archive
            }
            DispatchQueue.main.async { self?.finishLogExport(result) }
        }
    }

    private func finishLogExport(_ result: Result<URL, Error>) {
        guard !uninstalling else { return }
        // Selecting in Finder changes focus. Let an active screenshot finish first.
        if core.isBusy || transaction != nil || (!manualDeliveryPaused && capturePipeline.isBusy) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.finishLogExport(result) }
            return
        }
        exportingLogs = false
        menuStatus?.setExportingLogs(false)
        switch result {
        case .success(let archive):
            NSWorkspace.shared.activateFileViewerSelecting([archive])
            // Also on the clipboard as a file, so it pastes straight into WeChat or Mail.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([archive as NSURL])
            logExportNotice.show(success: true)
        case .failure:
            logExportNotice.show(success: false)
        }
    }

    @objc private func copyDiagnostics() {
        guard !hasActiveWork else { return }
        if let data = diagnosticsData(), let text = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    private func diagnosticsData() -> Data? {
        let summary: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", "status_code": lastCode,
            "connection_status": currentConnection.state.rawValue, "ipad_keepalive": keepAliveState, "ipad_keepalive_sent": iPadWaker.keepAliveCount,
            "connection_reason": currentConnection.reason,
            "network_available": networkAvailable as Any? ?? NSNull(),
            "target_app": targetKind.rawValue, "setup_code": lastSetupCode, "paired": hasPairing,
            "device_class": pairedDeviceClass?.rawValue as Any? ?? NSNull(),
            "device_locked": Dictionary(uniqueKeysWithValues: DeviceClass.allCases.compactMap { kind in
                captureWorkers[kind]?.deviceLocked.map { (kind.rawValue, $0) }
            }),
            "device_connections": deviceConnectionRows.map { name, status in
                ["device_class": name, "state": status.state.rawValue,
                 "reason": status.reason, "transport": status.transport ?? "none"]
            },
            "runtime_quarantined": runtimeQuarantined,
            "claude_accessibility_preparation": claudeTarget.accessibilityPreparationSummary,
            "failure_category": failureCategory, "backend_reason": backendReason, "busy_repeats_total": busyRepeatsTotal,
            "accessibility_preparation": target.accessibilityPreparationSummary,
            "backend_timings_ms": backendTimings, "connection_reused": connectionReused as Any? ?? NSNull(),
            "success_sound_loaded": successSounds.count == SuccessSound.allCases.count,
            "success_sound_tiers_loaded": SuccessSound.allCases.filter { successSounds[$0] != nil }.map(\.rawValue),
            "last_success_sound_selected": lastSuccessSound.map { String(describing: $0) } as Any? ?? NSNull(),
            "last_success_sound_bytes": lastSuccessSoundBytes as Any? ?? NSNull(),
            "failure_sound_loaded": failureSound != nil,
            "arrival_animation": captureAnimation.lastArrivalStatus, "jelly_early": earlyLandingNote, "append_interaction": appendInteractionNote, "jelly_growth": growthNote, "jelly_confirm_offset_pt": captureAnimation.confirmedOffset.map { Double($0) } as Any? ?? NSNull(), "jelly_patch": captureAnimation.patchStatus,
            "attachment_geometry": target.latestAttachmentGeometryStatus,
            "selector": target.diagnosticSummary, "events": diagnosticEvents,
            "connection_events": connectionEvents,
            "accessibility": AXIsProcessTrusted(), "input_monitoring": CGPreflightListenEventAccess(),
            "post_events": CGPreflightPostEventAccess(), "enabled": enabled,
            "restore_enabled": startup.desiredEnabled,
            "login_status": String(describing: startup.loginStatus),
            "configuration_present": (try? configuration()) != nil,
            "native_integration_verified_by_developer": false]
        return try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    }
    @objc private func showDiagnostics() {
        // Shows only previously collected metrics and this helper's own permissions.
        // Never inspects another app, starts a capture, or touches the clipboard.
        if diagnosticWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L("Toss · Diagnostics · No Chat Content", "Toss · 诊断信息 · 不含聊天内容")
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            // Share the same window background in both appearances.
            text.backgroundColor = SettingsStyle.background
            text.drawsBackground = false
            scroll.drawsBackground = false
            text.textContainerInset = NSSize(width: 14, height: 14)
            scroll.documentView = text
            window.contentView!.addSubview(scroll)
            SettingsStyle.applyUnifiedWindowStyle(in: window)
            window.center()
            diagnosticWindow = window
            diagnosticText = text
        }
        diagnosticText?.string = diagnosticsData().flatMap { String(data: $0, encoding: .utf8) } ?? L("Diagnostics unavailable", "诊断信息不可用")
        diagnosticWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private static let diagnosticDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private func recordDiagnosticEvent() {
        // Speed (提速副本): ms since the hotkey, so last-run.json shows where
        // each keypress spends its time (locate, capture, focus, paste, confirm).
        var sinceHotkey: Any = NSNull()
        if let started = diagnosticRequestStartedAt {
            sinceHotkey = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
        }
        diagnosticEvents.append(["time": Self.diagnosticDateFormatter.string(from: Date()),
            "ms_since_hotkey": sinceHotkey,
            "stage": lastCode, "failure": failureCategory, "target_app": targetKind.rawValue,
            "accessibility_preparation": target.accessibilityPreparationSummary,
            "backend_timings_ms": backendTimings, "connection_reused": connectionReused as Any? ?? NSNull(),
            "arrival_animation": captureAnimation.lastArrivalStatus, "jelly_early": earlyLandingNote, "append_interaction": appendInteractionNote, "jelly_growth": growthNote, "jelly_confirm_offset_pt": captureAnimation.confirmedOffset.map { Double($0) } as Any? ?? NSNull(), "jelly_patch": captureAnimation.patchStatus,
            "attachment_geometry": target.latestAttachmentGeometryStatus,
            "backend": backendReason, "selector": target.diagnosticSummary])
        if diagnosticEvents.count > 20 { diagnosticEvents.removeFirst(diagnosticEvents.count - 20) }
        writeLastRun()
    }
    private func recordConnectionEvent(_ status: TossConnectionStatus, deviceClass: DeviceClass) {
        connectionEvents.append(["time": Self.diagnosticDateFormatter.string(from: Date()),
                                 "state": status.state.rawValue, "reason": status.reason, "device_class": deviceClass.rawValue])
        if connectionEvents.count > 10 { connectionEvents.removeFirst(connectionEvents.count - 10) }
        writeLastRun()
    }
    private func finishCaptureRecord(outcome: String) {
        guard !uninstalling else { return }
        guard var record = captureRecord else { return }
        captureRecord = nil
        lastCaptureResult = record.menuResult(outcome: outcome)
        updateDeviceCopy()
        record.timings = backendTimings
        if let device = transaction?.deviceClass { record.deviceClass = device.rawValue }
        record.connectionReused = connectionReused
        if targetKind == .claude, ["composerUnavailable", "composersAmbiguous"].contains(failureCategory) {
            record.composers = claudeTarget.lastComposerCount
        }
        if let line = record.line(outcome: outcome, failure: failureCategory, backend: backendReason,
                                  formatter: Self.diagnosticDateFormatter) {
            captureHistory.append(line)
        }
    }
    private func writeLastRun() {
        guard !uninstalling else { return }
        // Metadata only: no titles, draft text, IDs, URLs, image data, or key material.
        // Keep last-run diagnostics available after a user-triggered failure, without
        // requiring clipboard changes or another target inspection by the reader.
        // Speed (提速副本): write the file once a keypress has finished (or
        // between keypresses), not on every step of it on the main thread.
        guard !hasActiveWork, transaction == nil else { return }
        guard fm.fileExists(atPath: base.path), let data = diagnosticsData() else { return }
        let temporary = base.appendingPathComponent("diagnostic-" + UUID().uuidString + ".tmp")
        let destination = base.appendingPathComponent("last-run.json")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { try? fm.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            _ = rename(temporary.path, destination.path)
        } catch { try? handle.close() }
    }
    @objc private func quit() {
        guard !uninstalling else { return }
        stop(reason: L("Quit", "退出")); NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { stopUSBSetupObserver(); stop(reason: L("Quit", "退出")) }
    // Quitting is not dismissing: windows closed by a quit must not mark the onboarding as seen.
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if uninstalling && uninstaller?.result == nil { return .terminateCancel }
        terminating = true
        return .terminateNow
    }

    private func setStatus(_ text: String, code: String) {
        lastStatus = text; lastCode = code
        if captureRecord != nil, let started = diagnosticRequestStartedAt {
            captureRecord?.reach(code, ms: Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()))
            if CaptureRecord.isOutcome(code) { finishCaptureRecord(outcome: code) }
        }
        let silentOutcome = code.contains("failed") || code.contains("unconfirmed") ||
            code == "hotkey_rejected" || code == "input_interrupted"
        let displayText = silentOutcome ? (enabled ? L("Enabled; waiting for both Option or both Shift keys", "已打开，等两个 Option 或两个 Shift") : L("Disabled", "已关闭")) : text
        statusItem?.title = L("Status: ", "状态：") + displayText
        let phase: String
        switch code {
        case "preparing_accessibility": phase = L("Preparing chat access", "准备聊天窗口")
        case "activating_target": phase = L("Switching to the target window", "切换到目标窗口")
        case "locating_target", "capture_setup_failed": phase = L("Checking the window and chat", "检查窗口和聊天")
        case "target_located", "capturing": phase = L("Capturing a new \(deviceEN) screenshot", "截取 \(deviceZH) 屏幕")
        case "capture_slow": phase = L("Screenshot is taking longer; still waiting for your \(deviceEN)", "截图比平时慢，还在等 \(deviceZH)")
        case "revalidating_capture", "capture_result_failed", "captured": phase = L("Verifying the screenshot and chat", "确认截图和聊天")
        case "focusing_composer", "append_failed": phase = L("Focusing the composer and attaching the screenshot", "聚焦输入框并贴上截图")
        case "paste_posted", "append_unconfirmed", "append_confirmed": phase = L("Confirming the attachment", "确认附件")
        case "ready": phase = L("Waiting for both Option → ChatGPT, or both Shift → Claude", "等两个 Option → ChatGPT，或两个 Shift → Claude")
        default: phase = L("Preparing / stopped", "准备中 / 已停止")
        }
        diagnosticStatus?.stringValue = L("Step: ", "步骤：") + (silentOutcome ? L("Waiting for both Option → ChatGPT, or both Shift → Claude", "等两个 Option → ChatGPT，或两个 Shift → Claude") : phase)
        refreshMenuStatus()
        recordDiagnosticEvent()
    }
    // cue: a keypress ended without an attachment (not setup, enable or connection checks).
    private func failure(_ error: Error, code: String, cue: Bool = false) {
        // Use the attempted device for the error copy unless an unlock hint applies.
        let pressDevice = transaction?.deviceClass.rawValue ?? earlyCapture?.deviceClass.rawValue ??
            capturePipeline.delivering?.deviceClass.rawValue ?? captureRecord?.deviceClass
        let unlockDevice: DeviceClass?
        if code == "capture_result_failed", let pressDevice, let device = DeviceClass(rawValue: pressDevice) {
            switch backendReason {
            case "alternate_device_locked": unlockDevice = device.other
            case "timeout", "disconnected", "no_authenticated_remote_wifi_connection":
                unlockDevice = lockedAlternate(for: device)
            default: unlockDevice = nil
            }
        } else {
            unlockDevice = nil
        }
        if let pressDevice { DeviceCopy.deviceClass = pressDevice }
        defer { updateDeviceCopy() }
        if let unlockDevice { failureCategory = "unlock_\(unlockDevice.rawValue.lowercased())" }
        else if let known = error as? TargetFailure { failureCategory = String(describing: known) }
        else if let known = error as? TossError { failureCategory = String(describing: known) }
        else if error is CaptureContractError { failureCategory = "capture_receipt_invalid" }
        else { failureCategory = "internal_error" }
        let text: String
        if let unlockDevice { text = ToastCopy.unlock(unlockDevice.rawValue) }
        else if code == "append_unconfirmed" { text = TossError.unconfirmed.errorDescription! }
        else { text = (error as? LocalizedError)?.errorDescription ?? L("The operation failed. No automatic retry was made.", "操作失败，没有自动重试。") }
        setStatus(text, code: code)
        // setStatus can end the capture record, which restores the primary device's name.
        if let pressDevice { DeviceCopy.deviceClass = pressDevice }
        // Only a failed keypress gets cues; quiet interruptions stay silent. The sound
        // first, then the ✕ toast (if enabled); any other failure shows nothing.
        if cue { playResultCue(failureSound) }
        if let result = ToastContent.failure(reason: text, code: code, cue: cue, backend: backendReason,
                                             unlockDevice: unlockDevice?.rawValue) {
            captureAnimation.failCurrent(title: result.title, toastHold: toastPreferences.enabled ? result.holdDuration : nil)
        } else {
            captureAnimation.dismiss()
        }
        // A failed request discards its worker; have the next keypress find a
        // connection that is already authenticated instead of a cold start.
        rewarmWorker(after: 0.5)
    }
    private func playResultCue(_ cue: NSSound?) {
        guard let cue else { return }
        let sounds = Array(successSounds.values) + [failureSound].compactMap { $0 }
        cueQueue.async {
            // Stop the other sizes too: rapid results must never stack different cues.
            for sound in sounds { sound.stop() }
            cue.play()
        }
    }

    // Re-evaluates the iPad keepalive every 2 s on the main thread (cheap: one defaults read
    // and one input-idle query); the waker sends on its own queue.
    private func startKeepAliveCheck() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true; self?.updateKeepAlive() }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false; self?.updateKeepAlive() }
        }
        keepAliveCheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateKeepAlive() }
        }
        updateKeepAlive()
    }

    private func updateKeepAlive() {
        guard !uninstalling else { return }
        let defaults = UserDefaults.standard
        let anyInput = CGEventType(rawValue: ~0)!
        for kind in DeviceClass.allCases {
            let state = KeepAlivePolicy.state(
                switchOn: defaults.object(forKey: KeepAlivePolicy.switchKey) as? Bool ?? true,
                enabled: enabled && pairedDeviceClasses.contains(kind), connected: deviceConnections[kind]?.state == .ready,
                secondsSinceInput: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput),
                idleMinutes: defaults.object(forKey: KeepAlivePolicy.minutesKey) as? Double ?? KeepAlivePolicy.defaultIdleMinutes,
                screensAsleep: screensAsleep)
            if kind == activeDeviceClass { keepAliveState = state }
            deviceWakers[kind]?.setKeepAlive(state == "on")
        }
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = text
        alert.addButton(withTitle: L("OK", "好"))
        alert.runModal()
    }
    @objc private func confirmUninstall() {
        guard !uninstalling, uninstallSheet == nil, let window = settingsWindow else { return }
        // Pairing prompts can already occupy this sheet slot. Dismiss the prompt
        // only; Cancel below leaves the running setup and all settings intact.
        if let prompt = setupPrompt { window.endSheet(prompt.window); setupPrompt = nil }
        let sheet = UninstallSheet()
        uninstallSheet = sheet
        sheet.onDecision = { [weak self] confirmed in
            guard let self else { return }
            self.uninstallSheet = nil
            if confirmed { self.beginUninstall() }
        }
        window.beginSheet(sheet.window!)
    }

    private func beginUninstall() {
        #if TOSS_RENDER
        // Rendering/click tests can never enter any real uninstall adapter.
        RenderState.onUninstallConfirmed?()
        #else
        guard !uninstalling else { return }
        uninstalling = true
        terminating = true
        // Freeze the active language before clearing the saved preference.
        AppLanguage.forced = AppLanguage.current
        let remover = UninstallDataRemover(home: fm.homeDirectoryForCurrentUser)
        let controller = UninstallController(app: Bundle.main.bundleURL, actions: .init(
            stopCapture: { [self] in
                quiesceForUninstall()
                // The queue barrier waits for an already-running log export;
                // it must not recreate the support directory after deletion.
                let history = captureHistory
                await withCheckedContinuation { continuation in
                    logExportQueue.async { history.flush(); continuation.resume() }
                }
                // Stop both device workers even if one fails to exit.
                var firstError: Error?
                for worker in captureWorkers.values {
                    do { try await worker.stopForUninstall() }
                    catch { firstError = firstError ?? error }
                }
                if let firstError { throw firstError }
            },
            stopSetup: { [self] in try await setupWizard.stopForUninstall() },
            unregisterLogin: { [self] in
                // Serialize against an earlier click on the login switch.
                await startupChangeTask?.value
                try await startup.unregisterAndClearOwnedPreferences()
            },
            clearOwnedPreferences: {
                HelperStartupPreferences(domain: UninstallPolicy.domain).clearOwnedPreferences()
                Self.clearOnboardingPreferences()
            },
            removeData: { path in try await Task.detached(priority: .utility) { try remover.remove(path) }.value },
            clearDomain: { try UninstallSystem.clearDomain($0) },
            resetPermission: { try await UninstallSystem.resetPermission($0, domain: $1) },
            recycle: { try await UninstallSystem.recycle($0) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            showManualRemoval: { [self] message in showAlert("Toss", message) },
            terminate: { NSApp.terminate(nil) }))
        uninstaller = controller
        Task { await controller.run() }
        #endif
    }

    // Stop event sources without the normal capture cleanup's path-based file
    // removals. The allowlist remover owns ALL file deletion during uninstall.
    private func quiesceForUninstall() {
        stopUSBSetupObserver()
        enabled = false
        captureWorkers.values.forEach { $0.beginUninstall() }
        setupWizard.cancel()
        enableGeneration &+= 1
        enableTask?.cancel(); enableTask = nil
        pendingUserEnable = false
        for timer in [self.timer, permissionTimer, workerWatchdog, keepAliveCheck] { timer?.invalidate() }
        self.timer = nil; permissionTimer = nil; workerWatchdog = nil; keepAliveCheck = nil
        networkRewarm?.cancel(); networkRewarm = nil
        pathMonitor?.cancel(); pathMonitor = nil
        monitor.stop()
        deviceWakers.values.forEach { $0.stopForUninstall() }
        appendTask?.cancel(); appendTask = nil
        activationTask?.task.cancel(); activationTask = nil
        earlyFocusTask?.task.cancel(); earlyFocusTask = nil
        sighter.cancel(); grower.cancel()
        newDraftInteraction.stop(); appendInteraction.stop()
        transaction?.clipboard?.restoreIfStillOwned()
        pendingClipboard?.clipboard.restoreIfStillOwned()
        inheritedClipboard?.restoreIfStillOwned()
        transaction = nil; pendingClipboard = nil; inheritedClipboard = nil
        capturePipeline.reset(); _ = core.reset()
        deferredDeviceSelection = nil
        pipelineCaptures.removeAll(); pipelineProgress.removeAll(); slowPipelineIDs.removeAll()
        captureRecord = nil
        queuedBindings.removeAll(); burstLeases.removeAll()
        earlyCapture = nil; queuedPrefetch = nil; deliveryCaptureID = nil
        captureAnimation.dismiss()
        onboarding?.window.orderOut(nil)
        settingsWindow?.orderOut(nil)
        diagnosticWindow?.orderOut(nil)
        menuStatus?.closePanel()
        item?.button?.isEnabled = false
        // AppKit must not write the saved menu-bar position back after the
        // defaults domain has been removed.
        item?.autosaveName = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // Shared by the UI flow and the early --unregister-login-item entry. The
    // latter preserves its original fail-before-deletion script contract.
    static func clearOnboardingPreferences(in defaults: UninstallPreferenceClearing = UserDefaults.standard) {
        for key in [OnboardingPolicy.seenKey, OnboardingPolicy.wirelessKey, OnboardingPolicy.resumeAccessKey,
                    OnboardingPolicy.autoRelaunchKey, USBSetupDismissals.key, AppLanguage.key, reopenSettingsKey] {
            defaults.removeObject(forKey: key)
        }
        _ = defaults.synchronize()
    }
    private func purgeOldCaptures() {
        guard let files = try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let now = Date()
        for file in files {
            guard CaptureCache.recognizes(file) else { continue }
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               CaptureCache.shouldRemove(file, modifiedAt: date, now: now) { try? fm.removeItem(at: file) }
        }
    }
}

#if TOSS_RENDER
// Offscreen screenshots of every screen (scratch harness only; never part of the app build).
@MainActor
enum RenderState {
    static var paired: Bool?
    static var pairedDevices: PairedDevicesState?
    static var permissions: Bool?
    static var connection: TossConnectionStatus?
    static var pairing: Bool?
    static var onUninstallConfirmed: (() -> Void)?
    static var onOpenInterface: ((String) -> Void)?
}

extension TossDelegate {
    func renderInitialEntry(afterInstall: Bool = false) { presentInitialInterface(afterInstall: afterInstall) }
    func renderStatusEntry(item: NSStatusItem) -> TossStatusController { makeStatusController(item: item, menu: NSMenu()) }
    func renderSettingsWindow(enabled: Bool, enabling: Bool = false, setupCode: String = "not_run", setupText: String? = nil,
                              permissionHintText: String? = nil) -> NSWindow {
        toggleItem = NSMenuItem(); statusItem = NSMenuItem()
        settingsWindow = nil
        buildSettingsWindow()
        self.enabled = enabled
        lastSetupCode = setupCode
        if let setupText { setupStatus?.stringValue = setupText }
        if let permissionHintText { permissionHint?.stringValue = permissionHintText }
        startupStatus?.stringValue = "" // the harness has no login item; the app shows nothing here when it's fine
        windowToggle?.title = SettingsStyle.shortToggle(enabling ? "Cancel Enabling" : enabled ? "Disable Shortcuts" : "Enable Shortcuts")
        if RenderState.pairing == true { setupButtons.first?.title = L("Cancel Pairing", "取消配对") }
        refreshSettingsUI()
        return settingsWindow!
    }

    func renderPresentation(enabled: Bool, phase: TossTransferPhase, lastMessage: String = "", target: TossUploadTarget? = nil) -> TossStatusPresentation {
        self.enabled = enabled
        let summary = statusSummary
        return .init(connection: currentConnection, phase: phase, paired: hasPairing, enabled: enabled, canRecheck: true,
                     lastMessage: lastMessage, retryError: nil, uploadTarget: target, summary: summary.text, summaryTone: summary.tone)
    }

    func renderSettingsMoreMenu() -> NSMenu? { settingsMore }
    func renderUninstallSheet() -> UninstallSheet? { uninstallSheet }

    func renderDiagnosticsWindow() -> NSWindow? {
        showDiagnostics()
        return diagnosticWindow
    }
}
#endif

#if !TOSS_RENDER
@main
struct TossMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check-accessibility") {
            // A fresh process sees a new Accessibility grant that the running Toss may not (no UI).
            print("ax=\(AXIsProcessTrusted()) post=\(CGPreflightPostEventAccess())")
            exit(0)
        }
        if CommandLine.arguments.contains("--unregister-login-item") {
            // Uninstall is handled before any AppKit startup, target mode,
            // key monitor or network preparation can occur.
            Task { @MainActor in
                do {
                    try await StartupController.unregisterAndClear()
                    TossDelegate.clearOnboardingPreferences()
                    exit(0)
                }
                catch {
                    fputs("Could not unregister the login item. Keep Toss installed, check System Settings, and try again.\n", stderr)
                    exit(1)
                }
            }
            dispatchMain()
        }
        let application = NSApplication.shared
        let delegate = TossDelegate()
        application.delegate = delegate
        delegate.prepareInterface()
        DispatchQueue.main.async { delegate.showInitialInterface() }
        withExtendedLifetime(delegate) { application.run() }
    }
}
#endif
