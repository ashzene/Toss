import AppKit

// Step-by-step first setup (Ashley 2026-10-29: 「应该是一步步引导而不是全部一起显示」). One step per
// screen in the Settings look. Steps 3–7 follow Backend/setup_device.py `auto` codes unchanged; the
// pairing flow itself (cable, Trust, one Developer Mode restart) is the existing one. USB alone never
// counts as set up: the wireless step turns green only on the final "ready" code.

enum OnboardingStep: Int, CaseIterable {
    case welcome, access, menubar, cable, trust, devmode, prepare, wifi, iPhoneBackTap, tryIt, done
    var isSetup: Bool { (OnboardingStep.cable.rawValue...OnboardingStep.wifi.rawValue).contains(rawValue) }
}

enum OnboardingMark: Equatable { case none, wait, ok, fail }

enum OnboardingTryItReadiness: Equatable {
    case preparing, waitingForChat, shortcutsOff, unavailable, deviceUnavailable, ready
}

// Whether Toss's menu-bar icon can be seen (Ashley 2026-10-30: 「顶上没有 toss」). macOS 26 has no API to
// turn on an app's own "Allow in the Menu Bar" switch, so Toss detects it and walks the user to it.
enum MenuIconVisibility: Equatable { case visible, hidden, notch }
enum MenuIconPolicy {
    static let positionKey = "NSStatusItem Preferred Position TossStatus"
    static let defaultPosition: CGFloat = 320 // points from the right edge: clear of the notch on crowded bars
    // An item under the camera notch is "visible" to AppKit, so the notch is checked first.
    static func classify(frame: CGRect?, onScreen: Bool, notches: [CGRect]) -> MenuIconVisibility {
        guard let frame, onScreen, frame.width > 0 else { return .hidden }
        if notches.contains(where: { $0.intersects(frame) }) { return .notch }
        return .visible
    }
}

enum OnboardingLanguage: Equatable {
    case chinese, english, other(AppLanguage)
    init(_ language: AppLanguage) {
        switch language {
        case .chinese: self = .chinese
        case .english, .system: self = .english
        default: self = .other(language)
        }
    }
    // Settings → Language (default: follow the system), like the rest of Toss.
    static func current() -> Self { Self(AppLanguage.current) }
    // Following the system: its first language, or English when Toss doesn't have it.
    static func current(_ preferred: [String]) -> Self { Self(AppLanguage.resolve(choice: .system, preferred: preferred)) }
}

// Pure state of the onboarding; no AppKit, so the rules are tested on their own.
struct OnboardingFlow: Equatable {
    var step: OnboardingStep = .welcome {
        didSet { if step != oldValue { developerModeNeededSince = nil } }
    }
    var accessibility = false
    var code: String?            // latest setup_device.py code
    var final = false            // that code ended the run
    var ipados: String?
    var deviceClass: DeviceClass?
    var osVersion: String?
    private(set) var downloadPercent: Int?
    var waitingForUSBSince: Double?
    var developerModeNeededSince: Double?
    var trustSince: Double?      // first trust_needed, for the replug hint after 30 s
    var tossed = false
    var includesIPhoneBackTap = false
    var iPhoneShortcutPaired = false
    var tryItReadiness: OnboardingTryItReadiness = .preparing
    var showsShortcutRows: Bool { step == .done || (step == .tryIt && tryItReadiness == .ready) }
    var menuIcon: MenuIconVisibility = .visible
    var includesMenuBar = false      // the menu-bar step is part of this run (sticky once shown)
    var menuBarRequested = false     // System Settings was opened at Menu Bar
    var standaloneMenuBar = false    // shown alone at a later launch, not as part of setup
    var relaunching = false     // step 2: granted, Toss is reopening itself
    var accessRequestedAt: Double? // when System Settings was opened for step 2
    static let developerModeHintAfter = 15.0
    mutating func updateTime(at now: Double) {
        if step == .devmode && code == "developer_mode_needed" && !final {
            if developerModeNeededSince == nil { developerModeNeededSince = now }
        } else { developerModeNeededSince = nil }
    }
    func showsDeveloperModeHint(at now: Double) -> Bool {
        guard step == .devmode, code == "developer_mode_needed", !final,
              let since = developerModeNeededSince else { return false }
        return now - since >= Self.developerModeHintAfter
    }
    static let chargeOnlyHintAfter = 20.0
    static let staleAccessHintAfter = 30.0

    // Fallback only: a running Toss may not see a new grant until it relaunches (2026-10-29). Toss
    // checks from a fresh process and relaunches by itself; this button covers the rare miss.
    // No manual remove/re-add instructions (Ashley: 「我看到这个以后我直接就卸载了」).
    func showsStaleAccessHint(at now: Double) -> Bool {
        guard step == .access, !accessibility, !relaunching, let since = accessRequestedAt else { return false }
        return now - since >= Self.staleAccessHintAfter
    }

    // The step a setup code belongs to.
    static func stage(for code: String) -> OnboardingStep? {
        switch code {
        case "no_usb_ipad", "multiple_usb_ipads", "unlock_needed", "unsupported_ipados": return .cable
        case "unsupported_device", "mixed_usb_devices": return .cable
        case "trust_needed": return .trust
        case "developer_mode_auto", "developer_mode_needed", "ipad_restarting", "developer_mode_confirm": return .devmode
        case "pairing_wireless", "downloading_image", "preparing_image",
             "pairing_failed", "developer_image_failed", "developer_image_download_failed": return .prepare
        case "wifi_waiting", "wifi_unreachable", "ready": return .wifi
        default: return nil
        }
    }

    var setupStage: OnboardingStep? { code.flatMap(Self.stage(for:)) }
    var wirelessReady: Bool { final && code == "ready" }

    mutating func setMenuIcon(_ value: MenuIconVisibility) {
        menuIcon = value
        // Decided on the Accessibility step, so a slow first draw at launch doesn't add the step.
        if value != .visible && (step == .access || step == .menubar) { includesMenuBar = true }
    }
    var counted: Int { (includesMenuBar ? 9 : 8) + (includesIPhoneBackTap ? 1 : 0) }
    var number: Int {
        var number = step.rawValue + 1
        if !includesMenuBar && step.rawValue > OnboardingStep.menubar.rawValue { number -= 1 }
        if !includesIPhoneBackTap && step.rawValue > OnboardingStep.iPhoneBackTap.rawValue { number -= 1 }
        return number
    }

    mutating func setDeviceClass(_ value: DeviceClass?) {
        if value == nil || deviceClass != value { ipados = nil; osVersion = nil }
        deviceClass = value
    }

    mutating func receive(code: String, final: Bool, ipados: String?,
                          deviceClass: DeviceClass? = nil, osVersion: String? = nil,
                          downloadPercent: Int? = nil, at now: Double) {
        if self.code != code || self.final != final { developerModeNeededSince = nil }
        self.code = code
        self.final = final
        self.downloadPercent = code == "downloading_image" && !final ? downloadPercent : nil
        updateTime(at: now)
        if ["no_usb_ipad", "multiple_usb_ipads", "mixed_usb_devices", "unsupported_device", "not_paired"].contains(code) {
            self.deviceClass = nil; self.ipados = nil; self.osVersion = nil
        } else {
            if let deviceClass { setDeviceClass(deviceClass) }
            if let ipados { self.ipados = ipados }
            if let version = osVersion ?? ipados { self.osVersion = version }
        }
        if code == "no_usb_ipad" { if waitingForUSBSince == nil { waitingForUSBSince = now } } else { waitingForUSBSince = nil }
        if code == "trust_needed" { if trustSince == nil { trustSince = now } } else { trustSince = nil }
    }

    // Once the Mac passed the current step (after its ✓ was shown), the screen moves forward to the
    // step the setup is on; never backward. The wireless step moves on only on wirelessReady (autoNext).
    var advancesBySetup: Bool {
        guard step.isSetup, step != .wifi, let stage = setupStage else { return false }
        return stage.rawValue > step.rawValue
    }
    // Every step the Mac can detect moves on by itself (Ashley 2026-10-29: 「最好都是全自动的」);
    // only what macOS or the iPad makes the user do by hand waits for them.
    var autoNext: OnboardingStep? {
        if advancesBySetup { return setupStage }
        switch step {
        case .access where accessibility: return includesMenuBar && menuIcon != .visible ? .menubar : .cable
        case .menubar where menuIcon == .visible: return standaloneMenuBar ? nil : .cable
        case .wifi where wirelessReady: return includesIPhoneBackTap ? .iPhoneBackTap : .tryIt
        case .tryIt where tossed: return .done
        default: return nil
        }
    }
    mutating func advance() { if let next = autoNext { step = next } }
    var previousStep: OnboardingStep {
        switch step {
        case .cable: return includesMenuBar ? .menubar : .access
        case .iPhoneBackTap: return wirelessReady ? .wifi : .welcome
        case .tryIt: return includesIPhoneBackTap ? .iPhoneBackTap : .wifi
        default: return OnboardingStep(rawValue: max(0, step.rawValue - 1)) ?? .welcome
        }
    }
    mutating func skip() {
        guard skippable else { return }
        step = step == .iPhoneBackTap ? .tryIt : .done
    }
    // Arriving on the cable step starts pairing unless it is running or already done.
    var needsSetupStart: Bool { step == .cable && (setupStage == nil || (final && code != "ready")) }
    // The main button only where the user has to act: start, open System Settings, retry, finish.
    func showsPrimary(at now: Double) -> Bool {
        switch step {
        case .welcome, .iPhoneBackTap, .done: return true
        case .access: return !accessibility
        case .menubar: return menuIcon != .visible || standaloneMenuBar
        default: return mark(at: now) == .fail
        }
    }

    func mark(at now: Double) -> OnboardingMark {
        switch step {
        case .welcome, .done: return .none
        case .access: return accessibility ? .ok : .wait
        case .menubar: return menuIcon == .visible ? .ok : .wait
        case .iPhoneBackTap: return iPhoneShortcutPaired ? .ok : .none
        case .tryIt: return tossed ? .ok : .wait
        default:
            if let stage = setupStage, stage.rawValue > step.rawValue { return .ok }
            if step == .wifi && wirelessReady { return .ok }
            if final { return .fail } // this step's failure, or cancelled / timeout / unavailable
            if step == .cable, let since = waitingForUSBSince, now - since >= Self.chargeOnlyHintAfter { return .fail }
            return .wait
        }
    }

    // The main button may advance only once the Mac detected the step (or it needs no detection).
    func canContinue(at now: Double) -> Bool {
        switch step {
        case .welcome, .done: return true
        case .iPhoneBackTap: return iPhoneShortcutPaired
        case .tryIt: return tossed
        default: return mark(at: now) == .ok
        }
    }
    var showsBack: Bool { !standaloneMenuBar && [.access, .menubar, .cable, .iPhoneBackTap, .tryIt, .done].contains(step) }
    var skippable: Bool { (step == .tryIt && !tossed) || step == .iPhoneBackTap }
    // A waiting pairing step has no other button, so it can always be stopped.
    func showsCancel(setupRunning: Bool, at now: Double) -> Bool { setupRunning && step.isSetup && mark(at: now) == .wait }
}

// Launch-time policy. USBSetupPolicy separately offers each newly inserted,
// trusted, unpaired device once per insertion; manual setup remains available.
enum OnboardingPolicy {
    static let seenKey = "Toss.onboardingSeen"
    static let wirelessKey = "Toss.wirelessSetUp" // false after a failed wireless step or "cable only"
    static let resumeAccessKey = "Toss.onboardingResumeAccess" // set just before a relaunch from step 2
    static let autoRelaunchKey = "Toss.accessAutoRelaunchAt" // last automatic relaunch for Accessibility
    static let skippedIPhoneBackTapKey = "Toss.skippedIPhoneBackTapForDevice"
    static func opensAutomatically(paired: Bool, firstRun: Bool, seen: Bool) -> Bool { !paired || (firstRun && !seen) }
    static func opensFromIcon(paired: Bool, guideVisible: Bool) -> Bool { !paired || guideVisible }
    // Closed on the welcome step before Start (2026-11-02: a stray close while Ashley worked in another
    // app) is not "seen": the guide is offered again at the next launch. Any later step counts.
    static func closeMarksSeen(step: OnboardingStep) -> Bool { step != .welcome }
}

// Every visible string in both languages.
struct OnboardingCopy {
    let language: OnboardingLanguage
    private func t(_ zh: String, _ en: String) -> String {
        switch language {
        case .chinese: return zh
        case .english: return en
        case .other(let code): return Translations.text(en, language: code)
        }
    }

    var windowTitle: String { t("设置 Toss", "Set Up Toss") }
    func stepLine(_ flow: OnboardingFlow) -> String {
        if flow.standaloneMenuBar { return t("菜单栏图标", "Menu bar icon") }
        return flow.step == .done ? t("全部完成", "All set") :
            t("第 \(flow.number) 步，共 \(flow.counted) 步", "Step \(flow.number) of \(flow.counted)")
    }
    var back: String { t("返回", "Back") }
    var skip: String { t("跳过", "Skip") }
    var cancel: String { t("取消", "Cancel") }
    var tryAgain: String { t("再试一次", "Try Again") }
    func backTapSteps(shortcutName: String?) -> [String] {
        let path = t("在 iPhone 打开「设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下」。",
                     "On iPhone, go to Settings → Accessibility → Touch → Back Tap → Double Tap.")
        let select = t("选中下方的捷径，然后点返回生效。", "Select the shortcut below, then go back to apply.")
        let fallback = t("如果 iPhone 没有自动跳转", "If Settings doesn't open")
        return [select + (shortcutName.map { "\n" + $0 } ?? ""), fallback + "\n" + path]
    }
    var cableOnly: String { t("先只用数据线", "Use cable only for now") }
    var developerModeHint: String { t("没看到「开发者模式」？把 \(deviceZH) 上的「设置」从后台划掉再打开。", "Don't see Developer Mode? Swipe Settings away and open it again.") }
    var reopen: String { t("重新打开 Toss", "Reopen Toss") }
    var cableOnlyStatus: String { t("只能插线用，无线还没设好", "Cable only · wireless isn't set up yet") }
    func settingUpStatus(code: String) -> String {
        code == "wifi_waiting" ? t("USB 已连接，正在设置无线连接…", "USB connected · setting up wireless…") : t("正在设置 \(deviceZH)…", "Setting up \(deviceEN)…")
    }

    func title(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: return t("欢迎使用 Toss", "Welcome to Toss")
        case .access: return t("允许辅助功能", "Allow Accessibility")
        case .menubar: return t("在菜单栏显示 Toss", "Show Toss in the Menu Bar")
        case .cable: return t("用数据线连接 \(deviceZH)", "Connect Your \(deviceEN) with a Cable")
        case .trust: return t("在 \(deviceZH) 上点「信任」", "Tap Trust on Your \(deviceEN)")
        case .devmode: return t("打开开发者模式", "Turn On Developer Mode")
        case .prepare: return t("准备 \(deviceZH)", "Preparing Your \(deviceEN)")
        case .wifi: return t("设置无线连接", "Set Up the Wireless Connection")
        case .iPhoneBackTap: return t("iPhone 轻点背面", "iPhone Back Tap")
        case .tryIt: return t("试一下", "Try It")
        case .done: return t("设置完成", "You're All Set")
        }
    }
    // One short grey line under each title (Ashley 2026-10-30: 「所有这种灰色的字还是一行吧」).
    // English welcome line by device, each within the one-line width (iPad: unchanged wording).
    private var welcomeEN: String {
        switch DeviceCopy.deviceClass {
        case "iPad"?: return "One shortcut puts your iPad screen into ChatGPT, Codex or Claude."
        case "iPhone"?: return "One shortcut puts your iPhone screen in ChatGPT, Codex or Claude."
        default: return "One shortcut puts your screen into ChatGPT, Codex or Claude."
        }
    }
    func why(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: return t("按一下快捷键，\(DeviceCopy.label) 屏幕就贴进 ChatGPT、Codex 或 Claude。",
                                welcomeEN)
        case .access: return t("Toss 靠它找到输入框替你粘贴，不会读取你的聊天。", "Toss uses it to paste for you. It never reads your chats.")
        case .menubar: return t("Toss 的状态和设置都在菜单栏的图标里。", "Toss keeps its status and settings in the menu bar.")
        case .cable: return t("第一次配对要用线，之后不插线也能用。", "The first pairing needs a cable. After that, no cable needed.")
        case .trust: return t("让这台 \(deviceZH) 允许这台 Mac 连接它。", "This lets your \(deviceEN) accept this Mac.")
        case .devmode: return t("截图需要它，只开一次。\(deviceZH) 会重启一次，数据线别拔。", "Screenshots need it. Your \(deviceShortEN) restarts once; keep the cable in.")
        case .prepare: return t("正在建立无线配对、下载截图组件，可能要几分钟。", "Setting up wireless and screenshots. Can take a few minutes.")
        case .wifi: return t("拔掉线也能用。Mac 和 \(deviceZH) 要连同一个 Wi-Fi。", "Works without the cable. Mac and \(DeviceCopy.deviceClass ?? "your device") need the same Wi-Fi.")
        case .iPhoneBackTap:
            return t("也可以稍后在 Toss 设置里开启。", "Set this up later in Toss settings.")
        case .tryIt:
            if DeviceCopy.bothPaired {
                return t("打开一个聊天：按一下发 iPad，快速按两下发 iPhone。", "Open a chat: press once for iPad, twice quickly for iPhone.")
            }
            return t("打开一个聊天按快捷键，截图只进草稿，不会发送。", "Open a chat and press a shortcut. It only goes into the draft.")
        case .done:
            if DeviceCopy.bothPaired {
                return t("按一下发 iPad，快速按两下发 iPhone，状态在菜单栏。", "Once for iPad, twice quickly for iPhone. Status is in the menu bar.")
            }
            return t("以后直接按快捷键，点菜单栏的 Toss 图标看状态。", "Just press a shortcut. Click Toss in the menu bar for status.")
        }
    }

    // "Main line\nextra" shows the extra part as a smaller, muted second line, like a Settings row
    // and its note (Ashley 2026-10-30, p1/p2). No parentheses in the UI text.
    static func split(_ text: String) -> (main: String, extra: String?) {
        guard let cut = text.firstIndex(of: "\n") else { return (text, nil) }
        let extra = String(text[text.index(after: cut)...])
        return (String(text[..<cut]), extra.isEmpty ? nil : extra)
    }

    func howto(_ step: OnboardingStep) -> [String] {
        switch step {
        case .welcome: return [t("一根能传数据的 USB 线\n只能充电的线不行", "A USB cable that carries data\nCharge-only cables won't work"),
                               t("\(deviceZH) 解锁，放在手边", "Your \(deviceEN), unlocked and nearby"),
                               t("Mac 能上网\n第一次要下载一个截图组件", "Internet on your Mac\nA screenshot component downloads once")]
        case .access: return [t("系统设置已经打开在「辅助功能」\nToss 就在列表里", "System Settings is open at Accessibility\nToss is already in the list"),
                              t("打开 Toss 的开关\n会要密码或指纹", "Turn on the switch for Toss\nTouch ID or your password"),
                              t("打开后 Toss 会自己继续", "Toss continues by itself once it's on")]
        case .menubar: return [t("系统设置已经打开在「菜单栏」\n往下找到「允许在菜单栏中显示」", "System Settings is open at Menu Bar\nScroll to Allow in the Menu Bar"),
                               t("打开 Toss 的开关\n打开后 Toss 会自己继续", "Switch Toss on\nToss continues by itself")]
        case .cable: return [t("解锁 \(deviceZH)", "Unlock the \(deviceEN)"),
                             t("用数据线把 \(deviceZH) 连到这台 Mac", "Connect the \(deviceEN) to this Mac with the cable")]
        case .trust: return [t("\(deviceZH) 上会弹出「要信任此电脑吗？」", "Your \(deviceEN) asks \u{201C}Trust This Computer?\u{201D}"),
                             t("点「信任」，再输入 \(deviceZH) 密码", "Tap Trust, then enter the \(deviceEN) passcode")]
        case .devmode: return [t("把「设置」从后台划掉，再重新打开\n「设置」重开后才会显示开关", "Swipe Settings away, then open it again\nSettings shows the switch only after a reopen"),
                               t("点「隐私与安全性」，滑到最下面\n点「开发者模式」", "Tap Privacy & Security, scroll to the bottom\nThen tap Developer Mode"),
                               t("打开开关，点「重新启动」", "Switch it on, tap Restart"),
                               t("重启后解锁，在弹窗里点「打开」\n再输入一次锁屏密码", "After the restart, unlock and tap Turn On\nThen enter your passcode once")]
        case .wifi: return [t("macOS 问「Toss 想要查找本地网络上的设备」时，点「允许」", "If macOS asks to find devices on your network, click Allow"),
                            t("\(deviceZH) 保持解锁、连着 Wi-Fi", "Keep the \(deviceEN) unlocked and on Wi-Fi")]
        case .iPhoneBackTap:
            return [t("先添加捷径，再按顺序完成配对和授权。", "Add the shortcut, then follow the pairing and permission steps.")]
        case .prepare, .tryIt, .done: return []
        }
    }
    // Steps 8 and 9 reuse the Settings rows: title, grey note, keycaps or status on the right
    // (Ashley 2026-10-30: 「这两个太奇怪了」).
    var shortcutRows: [(title: String, note: String, key: String)] {
        [("ChatGPT / Codex", t("左右两个 Option 一起按", "Left and right Option together"), "⌥"),
         ("Claude", t("左右两个 Shift 一起按", "Left and right Shift together"), "⇧")]
    }
    var iPadRow: (title: String, note: String) { (DeviceCopy.label, t("插着线走 USB，拔掉自动换 Wi-Fi", "USB when plugged in, Wi-Fi otherwise")) }
    func connected(_ transport: String?) -> String { t("已连接", "Connected") + (transport.map { " · " + $0 } ?? "") }

    func primary(_ flow: OnboardingFlow, at now: Double) -> String {
        let mark = flow.mark(at: now)
        switch flow.step {
        case .welcome: return t("开始", "Start")
        case .access: return flow.accessibility ? t("继续", "Continue") : t("打开系统设置", "Open System Settings")
        case .menubar: return flow.menuIcon == .hidden ? t("打开系统设置", "Open System Settings")
            : flow.standaloneMenuBar ? t("完成", "Done") : t("继续", "Continue")
        case .done: return t("完成", "Done")
        case .iPhoneBackTap: return flow.iPhoneShortcutPaired ? t("已选好，继续", "Selected · Continue") : t("在 iPhone 上设置…", "Set Up on iPhone…")
        default: return mark == .fail ? tryAgain : t("继续", "Continue")
        }
    }

    // The live status line: (mark, text, secondary line).
    func status(_ flow: OnboardingFlow, at now: Double) -> (OnboardingMark, String, String?) {
        let mark = flow.mark(at: now)
        let code = flow.code ?? ""
        let device = flow.ipados.map { "\(DeviceCopy.label) · \(osEN) \($0)" } ?? DeviceCopy.label
        switch flow.step {
        case .welcome, .done: return (.none, "", nil)
        case .iPhoneBackTap:
            if flow.iPhoneShortcutPaired { return (.ok, t("捷径已配对。请在 iPhone 上选择。", "Shortcut paired. Select it on your iPhone."), nil) }
            return (.none, "", nil)
        case .access:
            if mark == .ok { return (.ok, t("辅助功能已打开 ✓", "Accessibility is on ✓"), nil) }
            if flow.relaunching { return (.ok, t("已允许，正在重新打开 Toss…", "Allowed, reopening Toss…"), nil) }
            return (.wait, t("正在等你打开辅助功能…", "Waiting for you to turn on Accessibility…"),
                    flow.showsStaleAccessHint(at: now)
                        ? t("已经打开了，但这里没反应？点「重新打开 Toss」。", "Switched on but nothing happens? Click Reopen Toss.")
                        : nil)
        case .menubar:
            switch flow.menuIcon {
            case .visible: return (.ok, t("Toss 已经在菜单栏里了 ✓", "Toss is in the menu bar ✓"), nil)
            case .notch: return (.wait, t("Toss 已经打开，但图标被刘海挡住了", "Toss is on, but the notch hides its icon"),
                                 t("菜单栏图标太多，放不下了。", "The menu bar is too full to show it."))
            case .hidden: return (.wait, t("正在等你打开 Toss 的开关…", "Waiting for you to switch Toss on…"), nil)
            }
        case .tryIt:
            if mark == .ok { return (.ok, t("截图已经贴进输入框 ✓", "The screenshot is in the message box ✓"), nil) }
            switch flow.tryItReadiness {
            case .preparing: return (.wait, t("正在准备 Toss…", "Turning on…"), nil)
            case .waitingForChat: return (.wait, t("等 ChatGPT / Codex 或 Claude 打开。", "Waiting for ChatGPT / Codex or Claude to open."), nil)
            case .shortcutsOff: return (.wait, t("已关闭 · 快捷键暂停", "Off · Shortcuts are paused"), nil)
            case .unavailable:
                return (.fail, t("还没准备好", "Not ready"),
                        t("自动恢复没准备好。在设置里检查配对和权限。", "Auto-resume is not ready. Check pairing and permissions in Settings."))
            case .deviceUnavailable: return (.wait, t("截图还没准备好，Toss 会重试。", "Not ready for screenshots. Toss will retry."), nil)
            case .ready: return (.wait, t("正在等你按快捷键…", "Waiting for a shortcut…"), nil)
            }
        default: break
        }
        if mark == .ok {
            switch flow.step {
            case .cable: return (.ok, t("已找到 \(device) ✓", "Found \(device) ✓"), nil)
            case .trust: return (.ok, t("\(deviceZH) 已信任这台 Mac ✓", "The \(deviceEN) trusts this Mac ✓"), nil)
            case .devmode: return (.ok, t("开发者模式已打开 ✓", "Developer Mode is on ✓"), nil)
            case .prepare: return (.ok, t("\(deviceZH) 已准备好 ✓", "Your \(deviceEN) is ready ✓"), nil)
            default: return (.ok, t("无线已就绪 ✓", "Wireless is ready ✓"),
                             t("现在可以拔掉数据线了，插着线时走 USB。", "You can unplug now. Plugged in, it uses USB."))
            }
        }
        if mark == .fail {
            switch code {
            case "no_usb_ipad": return (.fail, t("线已经插上，但 Mac 没有认出 \(deviceZH)？", "Cable plugged in, but the Mac doesn't see the \(deviceEN)?"),
                                        t("可能是只能充电的线，换一根，或先解锁 \(deviceZH)。", "Maybe a charge-only cable. Try another, or unlock the \(deviceEN)."))
            case "unsupported_ipados": return (.fail, t("这台 \(deviceZH) 的系统太旧了。", "This \(deviceEN)'s system is too old."),
                                               t("需要 \(osZH) 17 或更新。", "\(osEN) 17 or later is required."))
            case "unsupported_device": return (.fail, t("Toss 不支持这台设备。", "Toss doesn't support this device."),
                                               t("请连接 iPad 或 iPhone，系统 17 或更新。", "Connect an iPad or iPhone on version 17 or later."))
            case "trust_needed": return (.fail, t("\(deviceZH) 上没有点「信任」。", "Trust wasn't tapped on the \(deviceEN)."),
                                         t("拔下数据线再插上，\(deviceZH) 会再问一次。", "Unplug the cable and plug it in again; the \(deviceEN) asks again."))
            case "pairing_failed": return (.fail, t("无线配对没有成功。", "Wireless pairing didn't finish."),
                                           t("保持 \(deviceZH) 解锁、数据线连着，再试一次。", "Keep the \(deviceEN) unlocked and connected, then try again."))
            case "developer_image_download_failed": return (.fail, t("截图组件下载失败。", "The screenshot component couldn't download."),
                                                            t("请检查网络连接，然后重试。", "Check your internet connection and try again."))
            case "developer_image_failed": return (.fail, t("截图组件没有装好。", "The screenshot component didn't install."),
                                                   t("Mac 要能上网，\(deviceZH) 保持解锁，再试一次。", "Needs internet and an unlocked \(deviceEN). Try again."))
            case "wifi_unreachable": return (.fail, t("在网络上找不到这台 \(deviceZH)。", "Can't find the \(deviceEN) on the network."),
                                             t("两台设备连同一个 Wi-Fi 再试。插着线时 Toss 已经能用。",
                                               "Use the same Wi-Fi on both and try again. It already works plugged in."))
            case "setup_timeout": return (.fail, t("等太久了，设置停下了。", "Setup took too long and stopped."), t("再试一次，之前做过的步骤不用重做。", "Try again; finished steps are kept."))
            case "cancelled": return (.fail, t("配对已取消。", "Pairing was cancelled."), nil)
            default: return (.fail, t("这一步没有完成。", "This step didn't finish."),
                             t("再试一次；还不行就复制诊断信息发给我们。", "Try again, or copy Diagnostics and send it to us."))
            }
        }
        switch code {
        case "unlock_needed": return (.wait, t("请解锁 \(deviceZH)…", "Unlock your \(deviceEN)…"), nil)
        // The cable came out after the first step: say so instead of a generic wait.
        case "no_usb_ipad": return (.wait, t("没有连着 \(deviceZH)，请插上数据线并解锁…", "No \(deviceEN) connected. Plug in the cable and unlock it…"), nil)
        case "multiple_usb_ipads": return (.wait, t("连着不止一台 \(deviceZH)，只保留要用的那台。", "More than one \(deviceEN) is connected. Keep only the one you want."), nil)
        case "mixed_usb_devices": return (.wait, t("同时连着 iPad 和 iPhone，只保留要用的那台。", "Both an iPad and an iPhone are connected. Keep only the one you want."), nil)
        case "trust_needed":
            let long = flow.trustSince.map { now - $0 >= 30 } ?? false
            return (.wait, t("正在等你在 \(deviceZH) 上点「信任」…", "Waiting for you to tap Trust on the \(deviceEN)…"),
                    long ? t("没看到提示？拔下数据线再插上。", "No prompt? Unplug the cable, plug it back in.") : nil)
        case "developer_mode_auto": return (.wait, t("Toss 正在打开开发者模式，\(deviceZH) 会自动重启一次…", "Toss is turning on Developer Mode; your \(deviceEN) restarts once…"), nil)
        case "developer_mode_needed": return (.wait, t("正在等你在 \(deviceZH) 上打开开关…", "Waiting for you to switch it on on your \(deviceEN)…"),
                                            t("点完 \(deviceZH) 会自己重启，重启后会弹出提示。", "Your \(deviceEN) then restarts and shows a prompt."))
        case "ipad_restarting": return (.wait, t("\(deviceZH) 正在重启，数据线别拔…", "Your \(deviceEN) is restarting; keep the cable in…"),
                                        t("重启后解锁 \(deviceZH)，会弹出「打开开发者模式？」。", "After the restart, unlock it; the Turn On Developer Mode prompt appears."))
        case "developer_mode_confirm": return (.wait, t("在 \(deviceZH) 的弹窗里点「打开」，输入锁屏密码", "On your \(deviceEN), tap Turn On and enter your passcode"),
                                                   t("输完 Toss 会自动继续。", "Toss continues by itself."))
        case "pairing_wireless": return (.wait, t("正在建立无线配对…", "Setting up wireless pairing…"), nil)
        case "downloading_image": return (.wait, t("正在下载截图组件…", "Downloading the screenshot component…"), nil)
        case "preparing_image": return (.wait, t("正在安装截图组件…", "Installing the screenshot component…"), nil)
        case "wifi_waiting": return (.wait, t("USB 已连接，正在设置无线连接…", "USB is connected; setting up wireless…"),
                                     t("插着线已经能截图，但这一步要等无线好了才算完成。", "USB already works, but this step needs wireless."))
        default: return (.wait, t("正在等待 \(deviceZH)…", "Waiting for the \(deviceEN)…"), nil)
        }
    }
}

// The window. The delegate owns the pairing process; this view only shows the flow and reports clicks.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    var onRequestAccessibility: () -> Void = {}
    var onStartSetup: () -> Void = {}
    var onCableOnly: () -> Void = {}
    var onReopen: () -> Void = {}
    var onOpenMenuBarSettings: () -> Void = {}
    var menuIconProbe: (() -> MenuIconVisibility)?
    var setupRunningProbe: (() -> Bool)?
    var onCancelSetup: () -> Void = {}
    var onSetUpIPhoneBackTap: () -> Void = {}
    var onSkipIPhoneBackTap: () -> Void = {}
    var onLeaveIPhoneBackTap: () -> Void = {}
    var onClose: () -> Void = {}

    private(set) var flow = OnboardingFlow()
    private var verifiedIPhoneShortcutName: String?
    let copy: OnboardingCopy
    let window: NSWindow
    private let stack = NSStackView()
    private let iPhonePairingSlot = NSStackView()
    private var enteredIPhoneBackTap = false
    private var iPhonePairingError: String?
    private var tick: Timer?
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime }

    init(language: OnboardingLanguage = .current()) {
        copy = OnboardingCopy(language: language)
        _ = SettingsStyle.fontsRegistered
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsStyle.width, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = copy.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = SettingsStyle.background
        window.delegate = self
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        iPhonePairingSlot.orientation = .vertical
        iPhonePairingSlot.alignment = .leading
        iPhonePairingSlot.widthAnchor.constraint(equalToConstant: SettingsStyle.width - 2 * SettingsStyle.margin).isActive = true
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsStyle.margin),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -SettingsStyle.margin),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: SettingsStyle.top),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -SettingsStyle.footerBottom)
        ])
        window.center()
        render()
        SettingsStyle.applyUnifiedWindowStyle(in: window)
    }

    func resetForDeviceSetup() {
        advanceTimer?.invalidate(); advanceTimer = nil
        flow = OnboardingFlow()
        transport = nil
        verifiedIPhoneShortcutName = nil
        shown = nil
        render()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        render()
        tick?.invalidate()
        // Re-evaluates time-based hints (charge-only cable) once a second.
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let probe = self.menuIconProbe { self.setMenuIcon(probe()) }
                self.render()
            }
        }
        if let probe = menuIconProbe { setMenuIcon(probe()) }
    }
    var isVisible: Bool { window.isVisible }

    // MARK: inputs from the delegate
    func setAccessibility(_ granted: Bool) {
        guard flow.accessibility != granted else { return }
        flow.accessibility = granted; render(); scheduleAdvance()
    }
    func setupCode(_ code: String, final: Bool, ipados: String?,
                   deviceClass: DeviceClass? = nil, osVersion: String? = nil, downloadPercent: Int? = nil) {
        flow.receive(code: code, final: final, ipados: ipados,
                     deviceClass: deviceClass, osVersion: osVersion,
                     downloadPercent: downloadPercent, at: now())
        render()
        scheduleAdvance()
    }
    func setDeviceClass(_ value: DeviceClass?) { flow.setDeviceClass(value); render() }
    func setIncludesIPhoneBackTap(_ value: Bool) {
        guard flow.includesIPhoneBackTap != value else { return }
        flow.includesIPhoneBackTap = value; shown = nil; render()
    }
    func setIPhonePairingContent(_ view: NSView?) {
        guard enteredIPhoneBackTap, flow.step == .iPhoneBackTap, !flow.iPhoneShortcutPaired else { return }
        if iPhonePairingSlot.arrangedSubviews.first !== view {
            removeIPhonePairingContent()
            if let view {
                iPhonePairingError = nil
                iPhonePairingSlot.addArrangedSubview(view)
            }
            render()
        }
        fitWindow()
    }
    func setIPhonePairingError(_ message: String) {
        guard enteredIPhoneBackTap, flow.step == .iPhoneBackTap, !flow.iPhoneShortcutPaired else { return }
        iPhonePairingError = message
        removeIPhonePairingContent()
        render()
    }
    func markIPhoneShortcutPaired(shortcutName: String? = nil) {
        guard flow.step == .iPhoneBackTap else { return }
        // Later requests may arrive without the name of the imported shortcut.
        if let shortcutName { verifiedIPhoneShortcutName = shortcutName }
        flow.iPhoneShortcutPaired = true
        iPhonePairingError = nil
        removeIPhonePairingContent()
        render()
    }
    private func removeIPhonePairingContent() {
        guard let view = iPhonePairingSlot.arrangedSubviews.first else { return }
        iPhonePairingSlot.removeArrangedSubview(view)
        view.removeFromSuperview()
    }
    private func leaveIPhoneBackTap() {
        guard enteredIPhoneBackTap else { return }
        enteredIPhoneBackTap = false
        iPhonePairingError = nil
        removeIPhonePairingContent()
        onLeaveIPhoneBackTap()
    }
    func setTryItReadiness(_ value: OnboardingTryItReadiness) {
        guard flow.tryItReadiness != value else { return }
        flow.tryItReadiness = value
        if flow.step == .tryIt { render() }
    }
    // "USB" or "Wi-Fi" for the done step's iPad row, from the live connection.
    private(set) var transport: String?
    func setTransport(_ label: String?) { guard transport != label else { return }; transport = label; shown = nil; render() }
    func setMenuIcon(_ value: MenuIconVisibility) {
        guard flow.menuIcon != value else { return }
        flow.setMenuIcon(value); render(); scheduleAdvance()
    }
    // Shown alone at a later launch when the icon is hidden; closes itself once the icon is back.
    func showMenuBarOnly() {
        flow.standaloneMenuBar = true; flow.includesMenuBar = true; flow.step = .menubar
        if !flow.menuBarRequested { flow.menuBarRequested = true; onOpenMenuBarSettings() }
        render()
    }
    func tossed() { guard flow.step == .tryIt else { return }; flow.tossed = true; render(); scheduleAdvance() }
    func jump(to step: OnboardingStep) { flow.step = step; render(); scheduleAdvance() }
    #if TOSS_RENDER
    func jumpAccessRequested(_ t: Double) { flow.accessRequestedAt = t; render() }
    #endif
    // Step 2 seen granted by a fresh process: say so while Toss relaunches itself.
    func showRelaunching() { flow.relaunching = true; render() }

    // Show the green ✓ of the passed step briefly, then move on (and keep going while steps are met).
    private var advanceTimer: Timer?
    private func scheduleAdvance() {
        let standaloneDone = flow.standaloneMenuBar && flow.step == .menubar && flow.menuIcon == .visible
        guard flow.autoNext != nil || standaloneDone, advanceTimer == nil else { return }
        // "Wireless is ready, you can unplug" stays long enough to read.
        let hold = flow.step == .wifi ? 2.5 : flow.step == .tryIt ? 1.5 : 0.8
        advanceTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.advanceTimer = nil
                if self.flow.standaloneMenuBar && self.flow.step == .menubar && self.flow.menuIcon == .visible {
                    self.window.close(); return
                }
                self.flow.advance()
                if self.flow.step == .menubar && !self.flow.menuBarRequested {
                    self.flow.menuBarRequested = true; self.onOpenMenuBarSettings()
                }
                if self.flow.needsSetupStart { self.onStartSetup() }
                self.render()
                self.scheduleAdvance()
            }
        }
    }

    // MARK: actions
    @objc private func primary() {
        let t = now()
        switch flow.step {
        case .welcome:
            flow.step = .access
            // Open Accessibility by itself, once, with Toss already in the list (the AX prompt adds it).
            if !flow.accessibility && flow.accessRequestedAt == nil { flow.accessRequestedAt = t; onRequestAccessibility() }
            scheduleAdvance()
        case .access:
            if !flow.accessibility {
                if flow.accessRequestedAt == nil { flow.accessRequestedAt = t }
                onRequestAccessibility(); render(); return
            }
            if flow.includesMenuBar && flow.menuIcon != .visible {
                flow.step = .menubar
                if !flow.menuBarRequested { flow.menuBarRequested = true; onOpenMenuBarSettings() }
            } else {
                flow.step = .cable
                if flow.needsSetupStart { onStartSetup() }
            }
        case .iPhoneBackTap:
            guard flow.iPhoneShortcutPaired else {
                iPhonePairingError = nil
                onSetUpIPhoneBackTap()
                render()
                return
            }
            flow.step = .tryIt
        case .done: window.close(); return
        case .menubar:
            if flow.menuIcon == .hidden { flow.menuBarRequested = true; onOpenMenuBarSettings(); render(); return }
            // Under the notch the switch is already on; nothing more to do here.
            if flow.standaloneMenuBar { window.close(); return }
            flow.step = .cable
            if flow.needsSetupStart { onStartSetup() }
        default:
            if flow.mark(at: t) == .fail { flow.final = false; flow.waitingForUSBSince = nil; onStartSetup() }
        }
        render()
    }
    @objc private func cancelSetup() { onCancelSetup() }
    @objc private func back() {
        advanceTimer?.invalidate(); advanceTimer = nil
        flow.step = flow.previousStep
        render(); scheduleAdvance()
    }
    @objc private func skip() {
        if flow.step == .iPhoneBackTap { onSkipIPhoneBackTap() }
        flow.skip(); render()
    }
    @objc private func cableOnly() { onCableOnly(); window.close() }
    // macOS may only re-read Accessibility when Toss starts; the relaunch comes back to this step.
    @objc private func reopen() { onReopen() }

    func windowWillClose(_ notification: Notification) {
        tick?.invalidate(); tick = nil
        advanceTimer?.invalidate(); advanceTimer = nil
        leaveIPhoneBackTap()
        onClose()
    }

    // MARK: drawing
    private func label(_ text: String, _ font: NSFont, _ color: NSColor, width: CGFloat? = nil) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = font; l.textColor = color; l.isSelectable = false
        // A little air between wrapped lines (Ashley 2026-10-30: 「太紧凑了」).
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        l.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        if let width { l.preferredMaxLayoutWidth = width; l.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return l
    }
    private func hairline(_ width: CGFloat) -> NSView {
        let v = OnboardingRule(); v.wantsLayer = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }
    // A Settings window row: title and grey note on the left, a control or status on the right.
    private func settingsRow(_ title: String, _ note: String, _ trailing: NSView, _ inner: CGFloat) -> NSView {
        let labels = NSStackView(views: [label(title, SettingsStyle.sans(Self.mainSize), SettingsStyle.ink),
                                         label(note, SettingsStyle.sans(12.5), SettingsStyle.muted)])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = SettingsStyle.noteGap
        labels.setContentCompressionResistancePriority(.required, for: .vertical)
        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [labels, spacer, trailing]); row.alignment = .centerY; row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: SettingsStyle.rowPad, left: 0, bottom: SettingsStyle.rowPad, right: 0)
        row.widthAnchor.constraint(equalToConstant: inner).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualTo: labels.heightAnchor, constant: 2 * SettingsStyle.rowPad).isActive = true
        return row
    }

    private func gap(_ h: CGFloat) -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true; return v
    }

    private var shown: String?
    private var downloadReadout: (bar: OnboardingDownloadProgress, label: NSTextField)?

    func render() {
        let shortcutStep = flow.step == .iPhoneBackTap
        if shortcutStep && !enteredIPhoneBackTap {
            enteredIPhoneBackTap = true
            if !flow.iPhoneShortcutPaired { onSetUpIPhoneBackTap() }
        } else if !shortcutStep {
            leaveIPhoneBackTap()
        }
        let hasEmbeddedPairing = shortcutStep && !iPhonePairingSlot.arrangedSubviews.isEmpty
        let t = now()
        flow.updateTime(at: t)
        // Rebuild only when something visible changed, so the pulsing dot and the activity bar keep running.
        let (stageMark, stageText, sub) = copy.status(flow, at: t)
        let pairingError = shortcutStep ? iPhonePairingError : nil
        let mark: OnboardingMark = pairingError == nil ? stageMark : .fail
        let text = pairingError ?? stageText
        let primaryTitle = pairingError == nil ? copy.primary(flow, at: t) : copy.tryAgain
        let why = hasEmbeddedPairing || (flow.step == .tryIt && !flow.showsShortcutRows) ? "" : copy.why(flow.step)
        let developerHint = flow.showsDeveloperModeHint(at: t) ? copy.developerModeHint : ""
        let cancellable = flow.showsCancel(setupRunning: setupRunningProbe?() == true, at: t)
        let prepareActivity = mark == .wait &&
            (flow.step == .prepare || (flow.step == .wifi &&
                                       (flow.code == "downloading_image" || flow.code == "preparing_image")))
        let downloadPercent = prepareActivity ? flow.downloadPercent : nil
        let signature = "\(developerHint) \(flow.step) \(why) \(mark) \(text) \(sub ?? "") \(primaryTitle) \(flow.showsPrimary(at: t)) \(flow.skippable) \(cancellable) \(transport ?? "") \(downloadPercent != nil) \(verifiedIPhoneShortcutName ?? "") \(hasEmbeddedPairing)"
        if signature == shown {
            if let downloadPercent, let readout = downloadReadout, readout.bar.percent != downloadPercent {
                readout.bar.percent = downloadPercent
                readout.label.stringValue = (Double(downloadPercent) / 100).formatted(.percent)
            }
            return
        }
        shown = signature
        downloadReadout = nil
        let inner = SettingsStyle.width - 2 * SettingsStyle.margin
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        stack.addArrangedSubview(label(copy.stepLine(flow), SettingsStyle.sans(12), SettingsStyle.muted))
        stack.addArrangedSubview(gap(9))
        let segments = OnboardingSegments(total: flow.counted, filled: flow.step == .done || flow.standaloneMenuBar ? flow.counted : flow.number)
        segments.translatesAutoresizingMaskIntoConstraints = false
        segments.widthAnchor.constraint(equalToConstant: inner).isActive = true
        segments.heightAnchor.constraint(equalToConstant: 2).isActive = true
        stack.addArrangedSubview(segments)
        stack.addArrangedSubview(gap(26))
        stack.addArrangedSubview(label(copy.title(flow.step), SettingsStyle.serif(26), SettingsStyle.ink, width: inner))
        if !why.isEmpty { stack.addArrangedSubview(gap(10)); stack.addArrangedSubview(label(why, SettingsStyle.sans(14), SettingsStyle.muted, width: inner)) }
        if hasEmbeddedPairing {
            stack.addArrangedSubview(gap(16))
            stack.addArrangedSubview(iPhonePairingSlot)
        }
        let steps = hasEmbeddedPairing || pairingError != nil ? [] : shortcutStep && flow.iPhoneShortcutPaired
            ? copy.backTapSteps(shortcutName: verifiedIPhoneShortcutName) : copy.howto(flow.step)
        if !steps.isEmpty {
            stack.addArrangedSubview(gap(22)); stack.addArrangedSubview(hairline(inner))
            for (i, s) in steps.enumerated() {
                let parts = OnboardingCopy.split(s)
                let texts = NSStackView(views: [label(parts.main, SettingsStyle.sans(Self.mainSize), SettingsStyle.ink, width: inner - 28)])
                texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = SettingsStyle.noteGap
                if let extra = parts.extra { texts.addArrangedSubview(label(extra, SettingsStyle.sans(12.5), SettingsStyle.muted, width: inner - 28)) }
                let row = NSStackView(views: [label("\(i + 1)", SettingsStyle.sans(13), SettingsStyle.muted), texts])
                row.spacing = 12; row.alignment = .firstBaseline
                row.edgeInsets = NSEdgeInsets(top: SettingsStyle.rowPad, left: 0, bottom: SettingsStyle.rowPad, right: 0)
                // The grey note never sits on the divider: the row always keeps its padding.
                texts.setContentCompressionResistancePriority(.required, for: .vertical)
                row.heightAnchor.constraint(greaterThanOrEqualTo: texts.heightAnchor, constant: 2 * SettingsStyle.rowPad).isActive = true
                stack.addArrangedSubview(row); stack.addArrangedSubview(hairline(inner))
            }
        }
        if prepareActivity {
            let bar = OnboardingDownloadProgress(percent: downloadPercent, label: text)
            stack.addArrangedSubview(gap(18))
            if let downloadPercent {
                let percent = label((Double(downloadPercent) / 100).formatted(.percent),
                                    SettingsStyle.sans(12.5), SettingsStyle.ink)
                percent.setContentHuggingPriority(.required, for: .horizontal)
                percent.setContentCompressionResistancePriority(.required, for: .horizontal)
                let row = NSStackView(views: [bar, percent])
                row.alignment = .centerY
                row.spacing = 10
                row.widthAnchor.constraint(equalToConstant: inner).isActive = true
                stack.addArrangedSubview(row)
                downloadReadout = (bar, percent)
            } else {
                bar.widthAnchor.constraint(equalToConstant: inner).isActive = true
                stack.addArrangedSubview(bar)
            }
        }
        if flow.showsShortcutRows {
            stack.addArrangedSubview(gap(22)); stack.addArrangedSubview(hairline(inner))
            func keys(_ symbol: String) -> NSView {
                let plus = label("+", SettingsStyle.sans(12), SettingsStyle.muted)
                let view = NSStackView(views: [SettingsKeycap(symbol), plus, SettingsKeycap(symbol)]); view.spacing = 7; view.alignment = .centerY
                return view
            }
            if flow.step == .done {
                let status = SettingsStatus()
                status.show(copy.connected(transport), dot: SettingsStyle.ok)
                stack.addArrangedSubview(settingsRow(copy.iPadRow.title, copy.iPadRow.note, status, inner))
                stack.addArrangedSubview(hairline(inner))
            }
            for row in copy.shortcutRows {
                stack.addArrangedSubview(settingsRow(row.title, row.note, keys(row.key), inner))
                stack.addArrangedSubview(hairline(inner))
            }
        }
        let filler = NSView(); filler.setContentHuggingPriority(.defaultLow, for: .vertical)
        filler.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        filler.translatesAutoresizingMaskIntoConstraints = false
        filler.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsStyle.statusRoom).isActive = true
        stack.addArrangedSubview(filler)

        if mark != .none {
            let markView: NSView
            if mark == .fail { markView = label("✕", SettingsStyle.sans(13, .semibold), SettingsStyle.danger) }
            else { markView = OnboardingDot(color: mark == .ok ? SettingsStyle.ok : SettingsStyle.muted, pulses: mark == .wait) }
            let parts = OnboardingCopy.split(text)
            let texts = NSStackView(views: [label(parts.main, SettingsStyle.sans(Self.statusSize), SettingsStyle.ink, width: inner - 22)])
            texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = SettingsStyle.noteGap
            for extra in [parts.extra, sub].compactMap({ $0 }) {
                texts.addArrangedSubview(label(extra, SettingsStyle.sans(12.5), SettingsStyle.muted, width: inner - 22))
            }
            let row = NSStackView(views: [markView, texts]); row.spacing = 10; row.alignment = .top
            row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: SettingsStyle.statusRoom, right: 0)
            texts.setContentCompressionResistancePriority(.required, for: .vertical)
            row.heightAnchor.constraint(greaterThanOrEqualTo: texts.heightAnchor, constant: SettingsStyle.statusRoom).isActive = true
            stack.addArrangedSubview(row)
        }
        stack.addArrangedSubview(hairline(inner))
        stack.addArrangedSubview(gap(SettingsStyle.footerGap))
        // Fixed footer slot: revealing the hint cannot move the steps or resize the window.
        if flow.step == .devmode {
            let hint = label(developerHint.isEmpty ? " " : developerHint, SettingsStyle.sans(12.5), SettingsStyle.muted, width: inner)
            hint.heightAnchor.constraint(equalToConstant: 20).isActive = true
            stack.addArrangedSubview(hint)
        }
        let backButton = SettingsPill(copy.back, kind: .quiet, monochrome: shortcutStep, target: self, action: #selector(back))
        backButton.isHidden = !flow.showsBack
        var right: [NSView] = []
        if cancellable { right.append(SettingsPill(copy.cancel, kind: .quiet, target: self, action: #selector(cancelSetup))) }
        if flow.skippable {
            right.append(SettingsPill(copy.skip, kind: .quiet, monochrome: shortcutStep, target: self, action: #selector(skip)))
        }
        if flow.showsStaleAccessHint(at: t) {
            right.append(SettingsPill(copy.reopen, kind: .quiet, target: self, action: #selector(reopen)))
        }
        if flow.step == .wifi && mark == .fail && flow.code != "developer_image_download_failed" {
            right.append(SettingsPill(copy.cableOnly, kind: .quiet, target: self, action: #selector(cableOnly)))
        }
        if !hasEmbeddedPairing && flow.showsPrimary(at: t) {
            let main = SettingsPill(primaryTitle, kind: .filled, compact: false,
                                    monochrome: shortcutStep, target: self, action: #selector(primary))
            main.keyEquivalent = "\r"
            right.append(main)
        }
        let rightStack = NSStackView(views: right); rightStack.spacing = 14; rightStack.alignment = .centerY
        let bar = NSStackView(views: [backButton, NSView(), rightStack])
        bar.distribution = .fill; bar.alignment = .centerY
        bar.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(bar)
        fitWindow()
    }

    // Every step has the same height unless its text needs more; the top edge stays in place.
    private func fitWindow() {
        guard let content = window.contentView else { return }
        stack.layoutSubtreeIfNeeded()
        let wanted = max(Self.minimumHeight, stack.fittingSize.height + SettingsStyle.top + SettingsStyle.footerBottom)
        let delta = wanted - content.frame.height
        guard abs(delta) > 0.5 else { return }
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true)
    }
    static var minimumHeight: CGFloat { SettingsStyle.guideHeight }
    // Sizes of the ink lines in the list and the status (Ashley 2026-10-30 kept the 14 / 13.5 she
    // saw in 字号对比: 「就用这个吧不改了」).
    static let mainSize: CGFloat = 14
    static let statusSize: CGFloat = 13.5
}

// Hairline in the Settings line colour; resolves per appearance.
private final class OnboardingRule: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { effectiveAppearance.performAsCurrentDrawingAppearance { self.layer?.backgroundColor = SettingsStyle.line.cgColor } }
}

// "Step N of 8" as eight thin segments, filled ones in ink.
private final class OnboardingSegments: NSView {
    let total: Int, filled: Int
    init(total: Int, filled: Int) { self.total = total; self.filled = filled; super.init(frame: .zero) }
    required init?(coder: NSCoder) { return nil }
    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 4
        let w = (bounds.width - gap * CGFloat(total - 1)) / CGFloat(total)
        for i in 0..<total {
            (i < filled ? SettingsStyle.ink : SettingsStyle.line).setFill()
            NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height), xRadius: 1, yRadius: 1).fill()
        }
    }
}

private final class OnboardingDownloadProgress: NSView {
    private let fill = CALayer()
    private var animatedWidth: CGFloat = 0
    var percent: Int? {
        didSet {
            needsLayout = true
            setAccessibilityValue(percent)
        }
    }

    init(percent: Int?, label: String) {
        self.percent = percent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 4).isActive = true
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(fill)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(label)
        if let percent {
            setAccessibilityMinValue(0)
            setAccessibilityMaxValue(100)
            setAccessibilityValue(percent)
        } else {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(updateMotion),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
    }

    required init?(coder: NSCoder) { return nil }

    @objc private func updateMotion() { needsLayout = true }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsStyle.line.cgColor
            fill.backgroundColor = SettingsStyle.ink.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let trackWidth = bounds.width
        let radius = bounds.height / 2
        let width = percent.map { trackWidth * CGFloat($0) / 100 } ?? trackWidth * 0.24
        let x = percent == nil ? (trackWidth - width) / 2 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = radius
        fill.cornerRadius = min(radius, width / 2)
        fill.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
        CATransaction.commit()

        guard percent == nil, trackWidth > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            fill.removeAnimation(forKey: "slide")
            return
        }
        if animatedWidth != trackWidth || fill.animation(forKey: "slide") == nil {
            animatedWidth = trackWidth
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = width / 2
            slide.toValue = trackWidth - width / 2
            slide.duration = 1.2
            slide.autoreverses = true
            slide.repeatCount = .infinity
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fill.add(slide, forKey: "slide")
        }
    }
}

// Status dot: green when the Mac detected the step, grey (gently pulsing) while waiting.
private final class OnboardingDot: NSView {
    let color: NSColor
    init(color: NSColor, pulses: Bool) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        if pulses && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.35; pulse.duration = 0.8; pulse.autoreverses = true; pulse.repeatCount = .infinity
            layer?.add(pulse, forKey: "pulse")
        }
    }
    required init?(coder: NSCoder) { return nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: 0, y: (bounds.height - 8) / 2, width: 8, height: 8)).fill()
    }
}

#if TOSS_RENDER
extension OnboardingController {
    // Screenshot harness: step 2 as if System Settings was opened at time t.
    func markAccessRequested(at t: Double) { jumpAccessRequested(t) }
}
#endif
