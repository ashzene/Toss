import AppKit

// Step-by-step first setup (2026-10-29: one step at a time, not everything at once). One step per
// screen in the Settings look. Steps 3–7 follow Backend/setup_device.py `auto` codes unchanged; the
// pairing flow itself (cable, Trust, one Developer Mode restart) is the existing one. USB alone never
// counts as set up: the wireless step turns green only on the final "ready" code.

enum OnboardingStep: Int, CaseIterable {
    case welcome, access, menubar, cable, trust, devmode, prepare, wifi, tryIt, done
    var isSetup: Bool { (OnboardingStep.cable.rawValue...OnboardingStep.wifi.rawValue).contains(rawValue) }
}

enum OnboardingMark: Equatable { case none, wait, ok, fail }

// Whether Toss's menu-bar icon can be seen (2026-10-30). macOS 26 has no API to
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
    case chinese, english
    // Settings → Language (default: follow the system), like the rest of Toss.
    static func current() -> Self { AppLanguage.isChinese ? .chinese : .english }
    // Following the system: Chinese only when the first preferred language is Chinese.
    static func current(_ preferred: [String]) -> Self {
        AppLanguage.resolvesToChinese(choice: .system, preferred: preferred) ? .chinese : .english
    }
}

// Pure state of the onboarding; no AppKit, so the rules are tested on their own.
struct OnboardingFlow: Equatable {
    var step: OnboardingStep = .welcome
    var accessibility = false
    var code: String?            // latest setup_device.py code
    var final = false            // that code ended the run
    var ipados: String?
    var waitingForUSBSince: Double?
    var trustSince: Double?      // first trust_needed, for the replug hint after 30 s
    var tossed = false
    var menuIcon: MenuIconVisibility = .visible
    var includesMenuBar = false      // the menu-bar step is part of this run (sticky once shown)
    var menuBarRequested = false     // System Settings was opened at Menu Bar
    var standaloneMenuBar = false    // shown alone at a later launch, not as part of setup
    var relaunching = false     // step 2: granted, Toss is reopening itself
    var accessRequestedAt: Double? // when System Settings was opened for step 2
    static let chargeOnlyHintAfter = 20.0
    static let staleAccessHintAfter = 30.0

    // Fallback only: a running Toss may not see a new grant until it relaunches (2026-10-29). Toss
    // checks from a fresh process and relaunches by itself; this button covers the rare miss.
    // No manual remove/re-add instructions (they made people uninstall).
    func showsStaleAccessHint(at now: Double) -> Bool {
        guard step == .access, !accessibility, !relaunching, let since = accessRequestedAt else { return false }
        return now - since >= Self.staleAccessHintAfter
    }

    // The step a setup code belongs to.
    static func stage(for code: String) -> OnboardingStep? {
        switch code {
        case "no_usb_ipad", "multiple_usb_ipads", "unlock_needed", "unsupported_ipados": return .cable
        case "trust_needed": return .trust
        case "developer_mode_auto", "developer_mode_needed", "ipad_restarting", "developer_mode_confirm": return .devmode
        case "pairing_wireless", "preparing_image", "pairing_failed", "developer_image_failed": return .prepare
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
    var counted: Int { includesMenuBar ? 9 : 8 }
    // Step number on screen; the menu-bar step only counts when it is part of this run.
    var number: Int { step.rawValue + 1 - (!includesMenuBar && step.rawValue > OnboardingStep.menubar.rawValue ? 1 : 0) }

    mutating func receive(code: String, final: Bool, ipados: String?, at now: Double) {
        self.code = code
        self.final = final
        if let ipados { self.ipados = ipados }
        if code == "no_usb_ipad" { if waitingForUSBSince == nil { waitingForUSBSince = now } } else { waitingForUSBSince = nil }
        if code == "trust_needed" { if trustSince == nil { trustSince = now } } else { trustSince = nil }
    }

    // Once the Mac passed the current step (after its ✓ was shown), the screen moves forward to the
    // step the setup is on; never backward. The wireless step moves on only on wirelessReady (autoNext).
    var advancesBySetup: Bool {
        guard step.isSetup, step != .wifi, let stage = setupStage else { return false }
        return stage.rawValue > step.rawValue
    }
    // Every step the Mac can detect moves on by itself (2026-10-29);
    // only what macOS or the iPad makes the user do by hand waits for them.
    var autoNext: OnboardingStep? {
        if advancesBySetup { return setupStage }
        switch step {
        case .access where accessibility: return includesMenuBar && menuIcon != .visible ? .menubar : .cable
        case .menubar where menuIcon == .visible: return standaloneMenuBar ? nil : .cable
        case .wifi where wirelessReady: return .tryIt
        case .tryIt where tossed: return .done
        default: return nil
        }
    }
    mutating func advance() { if let next = autoNext { step = next } }
    // Arriving on the cable step starts pairing unless it is running or already done.
    var needsSetupStart: Bool { step == .cable && (setupStage == nil || (final && code != "ready")) }
    // The main button only where the user has to act: start, open System Settings, retry, finish.
    func showsPrimary(at now: Double) -> Bool {
        switch step {
        case .welcome, .done: return true
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
        case .tryIt: return tossed
        default: return mark(at: now) == .ok
        }
    }
    var showsBack: Bool { !standaloneMenuBar && [.access, .menubar, .cable, .tryIt, .done].contains(step) }
    var skippable: Bool { step == .tryIt && !tossed }
}

// When the onboarding opens by itself: on first run or while no iPad is paired, but only until it
// was closed once (finished, cable only, or dismissed); after that "Set Up iPad…" opens it.
enum OnboardingPolicy {
    static let seenKey = "Toss.onboardingSeen"
    static let wirelessKey = "Toss.wirelessSetUp" // false after a failed wireless step or "cable only"
    static let resumeAccessKey = "Toss.onboardingResumeAccess" // set just before a relaunch from step 2
    static let autoRelaunchKey = "Toss.accessAutoRelaunchAt" // last automatic relaunch for Accessibility
    static func opensAutomatically(paired: Bool, firstRun: Bool, seen: Bool) -> Bool { !seen && (!paired || firstRun) }
    // Closed on the welcome step before Start (2026-11-02: a stray close while working in another
    // app) is not "seen": the guide is offered again at the next launch. Any later step counts.
    static func closeMarksSeen(step: OnboardingStep) -> Bool { step != .welcome }
}

// Every visible string in both languages.
struct OnboardingCopy {
    let language: OnboardingLanguage
    private func t(_ zh: String, _ en: String) -> String { language == .chinese ? zh : en }

    var windowTitle: String { t("设置 Toss", "Set Up Toss") }
    func stepLine(_ flow: OnboardingFlow) -> String {
        if flow.standaloneMenuBar { return t("菜单栏图标", "Menu bar icon") }
        return flow.step == .done ? t("全部完成", "All set") :
            t("第 \(flow.number) 步，共 \(flow.counted) 步", "Step \(flow.number) of \(flow.counted)")
    }
    var back: String { t("返回", "Back") }
    var skip: String { t("跳过", "Skip") }
    var cableOnly: String { t("先只用数据线", "Use cable only for now") }
    var reopen: String { t("重新打开 Toss", "Reopen Toss") }
    var cableOnlyStatus: String { t("只能插线用，无线还没设好", "Cable only · wireless isn't set up yet") }
    func settingUpStatus(code: String) -> String {
        code == "wifi_waiting" ? t("USB 已连接，正在设置无线连接…", "USB connected · setting up wireless…") : t("正在设置 iPad…", "Setting up iPad…")
    }

    func title(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: return t("欢迎使用 Toss", "Welcome to Toss")
        case .access: return t("允许辅助功能", "Allow Accessibility")
        case .menubar: return t("在菜单栏显示 Toss", "Show Toss in the Menu Bar")
        case .cable: return t("用数据线连接 iPad", "Connect Your iPad with a Cable")
        case .trust: return t("在 iPad 上点「信任」", "Tap Trust on Your iPad")
        case .devmode: return t("打开开发者模式", "Turn On Developer Mode")
        case .prepare: return t("准备 iPad", "Preparing Your iPad")
        case .wifi: return t("设置无线连接", "Set Up the Wireless Connection")
        case .tryIt: return t("试一下", "Try It")
        case .done: return t("设置完成", "You're All Set")
        }
    }
    // One short grey line under each title (2026-10-30).
    func why(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: return t("按一下快捷键，iPad 屏幕就贴进 ChatGPT、Codex 或 Claude。",
                                "One shortcut puts your iPad screen into ChatGPT, Codex or Claude.")
        case .access: return t("Toss 靠它找到输入框替你粘贴，不会读取你的聊天。", "Toss uses it to paste for you. It never reads your chats.")
        case .menubar: return t("Toss 的状态和设置都在菜单栏的图标里。", "Toss keeps its status and settings in the menu bar.")
        case .cable: return t("第一次配对要用线，之后不插线也能用。", "The first pairing needs a cable. After that, no cable needed.")
        case .trust: return t("让这台 iPad 允许这台 Mac 连接它。", "This lets your iPad accept this Mac.")
        case .devmode: return t("截图需要它，只开一次。iPad 会重启一次，数据线别拔。", "Screenshots need it. Your iPad restarts once; keep the cable in.")
        case .prepare: return t("正在建立无线配对、装截图组件，需要联网，约 1 分钟。", "Setting up wireless and screenshots. Needs internet, about a minute.")
        case .wifi: return t("拔掉线也能用。Mac 和 iPad 要连同一个 Wi-Fi。", "Works without the cable. Mac and iPad need the same Wi-Fi.")
        case .tryIt: return t("打开一个聊天按快捷键，截图只进草稿，不会发送。", "Open a chat and press a shortcut. It only goes into the draft.")
        case .done: return t("以后直接按快捷键，点菜单栏的 Toss 图标看状态。", "Just press a shortcut. Click Toss in the menu bar for status.")
        }
    }

    // "Main line\nextra" shows the extra part as a smaller, muted second line, like a Settings row
    // and its note (2026-10-30). No parentheses in the UI text.
    static func split(_ text: String) -> (main: String, extra: String?) {
        guard let cut = text.firstIndex(of: "\n") else { return (text, nil) }
        let extra = String(text[text.index(after: cut)...])
        return (String(text[..<cut]), extra.isEmpty ? nil : extra)
    }

    func howto(_ step: OnboardingStep) -> [String] {
        switch step {
        case .welcome: return [t("一根能传数据的 USB 线\n只能充电的线不行", "A USB cable that carries data\nCharge-only cables won't work"),
                               t("iPad 解锁，放在手边", "Your iPad, unlocked and nearby"),
                               t("Mac 能上网\n第一次要下载一个 iPad 组件", "Internet on your Mac\nAn iPad component downloads once")]
        case .access: return [t("系统设置已经打开在「辅助功能」\nToss 就在列表里", "System Settings is open at Accessibility\nToss is already in the list"),
                              t("打开 Toss 的开关\n会要密码或指纹", "Turn on the switch for Toss\nTouch ID or your password"),
                              t("打开后 Toss 会自己继续", "Toss continues by itself once it's on")]
        case .menubar: return [t("系统设置已经打开在「菜单栏」\n往下找到「允许在菜单栏中显示」", "System Settings is open at Menu Bar\nScroll to Allow in the Menu Bar"),
                               t("打开 Toss 的开关\n打开后 Toss 会自己继续", "Switch Toss on\nToss continues by itself")]
        case .cable: return [t("用数据线把 iPad 连到这台 Mac", "Connect the iPad to this Mac with the cable"), t("解锁 iPad", "Unlock the iPad")]
        case .trust: return [t("iPad 上会弹出「要信任此电脑吗？」", "Your iPad asks \u{201C}Trust This Computer?\u{201D}"),
                             t("点「信任」，再输入 iPad 密码", "Tap Trust, then enter the iPad passcode")]
        case .devmode: return [t("打开「设置」，点「隐私与安全性」", "Open Settings, tap Privacy & Security"),
                               t("滑到最下面，点「开发者模式」\nToss 已经帮你把它显示出来了", "Scroll to the bottom, tap Developer Mode\nToss has already made it visible"),
                               t("打开开关，点「重新启动」", "Switch it on, tap Restart"),
                               t("重启后解锁，在弹窗里点「打开」\n再输入一次锁屏密码", "After the restart, unlock and tap Turn On\nThen enter your passcode once")]
        case .wifi: return [t("macOS 问「Toss 想要查找本地网络上的设备」时，点「允许」", "If macOS asks to find devices on your network, click Allow"),
                            t("iPad 保持解锁、连着 Wi-Fi", "Keep the iPad unlocked and on Wi-Fi")]
        case .prepare, .tryIt, .done: return []
        }
    }
    // Steps 8 and 9 reuse the Settings rows: title, grey note, keycaps or status on the right
    // (2026-10-30).
    var shortcutRows: [(title: String, note: String, key: String)] {
        [("ChatGPT / Codex", t("左右两个 Option 一起按", "Left and right Option together"), "⌥"),
         ("Claude", t("左右两个 Shift 一起按", "Left and right Shift together"), "⇧")]
    }
    var iPadRow: (title: String, note: String) { ("iPad", t("插着线走 USB，拔掉自动换 Wi-Fi", "USB when plugged in, Wi-Fi otherwise")) }
    func connected(_ transport: String?) -> String { t("已连接", "Connected") + (transport.map { " · " + $0 } ?? "") }

    func primary(_ flow: OnboardingFlow, at now: Double) -> String {
        let mark = flow.mark(at: now)
        switch flow.step {
        case .welcome: return t("开始", "Start")
        case .access: return flow.accessibility ? t("继续", "Continue") : t("打开系统设置", "Open System Settings")
        case .menubar: return flow.menuIcon == .hidden ? t("打开系统设置", "Open System Settings")
            : flow.standaloneMenuBar ? t("完成", "Done") : t("继续", "Continue")
        case .done: return t("完成", "Done")
        default: return mark == .fail ? t("再试一次", "Try Again") : t("继续", "Continue")
        }
    }

    // The live status line: (mark, text, secondary line).
    func status(_ flow: OnboardingFlow, at now: Double) -> (OnboardingMark, String, String?) {
        let mark = flow.mark(at: now)
        let code = flow.code ?? ""
        let device = flow.ipados.map { "iPad · iPadOS \($0)" } ?? "iPad"
        switch flow.step {
        case .welcome, .done: return (.none, "", nil)
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
        case .tryIt: return mark == .ok ? (.ok, t("截图已经贴进输入框 ✓", "The screenshot is in the message box ✓"), nil)
                                        : (.wait, t("正在等你按快捷键…", "Waiting for a shortcut…"), nil)
        default: break
        }
        if mark == .ok {
            switch flow.step {
            case .cable: return (.ok, t("已找到 \(device) ✓", "Found \(device) ✓"), nil)
            case .trust: return (.ok, t("iPad 已信任这台 Mac ✓", "The iPad trusts this Mac ✓"), nil)
            case .devmode: return (.ok, t("开发者模式已打开 ✓", "Developer Mode is on ✓"), nil)
            case .prepare: return (.ok, t("iPad 已准备好 ✓", "Your iPad is ready ✓"), nil)
            default: return (.ok, t("无线已就绪 ✓", "Wireless is ready ✓"),
                             t("现在可以拔掉数据线了，插着线时走 USB。", "You can unplug now. Plugged in, it uses USB."))
            }
        }
        if mark == .fail {
            switch code {
            case "no_usb_ipad": return (.fail, t("线已经插上，但 Mac 没有认出 iPad？", "Cable plugged in, but the Mac doesn't see the iPad?"),
                                        t("可能是只能充电的线，换一根，或先解锁 iPad。", "Maybe a charge-only cable. Try another, or unlock the iPad."))
            case "unsupported_ipados": return (.fail, t("这台 iPad 的系统太旧了。", "This iPad's system is too old."),
                                               t("需要 iPadOS 17 或更新。", "iPadOS 17 or later is required."))
            case "trust_needed": return (.fail, t("iPad 上没有点「信任」。", "Trust wasn't tapped on the iPad."),
                                         t("拔下数据线再插上，iPad 会再问一次。", "Unplug the cable and plug it in again; the iPad asks again."))
            case "pairing_failed": return (.fail, t("无线配对没有成功。", "Wireless pairing didn't finish."),
                                           t("保持 iPad 解锁、数据线连着，再试一次。", "Keep the iPad unlocked and connected, then try again."))
            case "developer_image_failed": return (.fail, t("截图组件没有装好。", "The screenshot component didn't install."),
                                                   t("Mac 要能上网，iPad 保持解锁，再试一次。", "Needs internet and an unlocked iPad. Try again."))
            case "wifi_unreachable": return (.fail, t("在网络上找不到这台 iPad。", "Can't find the iPad on the network."),
                                             t("两台设备连同一个 Wi-Fi 再试。插着线时 Toss 已经能用。",
                                               "Use the same Wi-Fi on both and try again. It already works plugged in."))
            case "setup_timeout": return (.fail, t("等太久了，设置停下了。", "Setup took too long and stopped."), t("再试一次，之前做过的步骤不用重做。", "Try again; finished steps are kept."))
            case "cancelled": return (.fail, t("配对已取消。", "Pairing was cancelled."), nil)
            default: return (.fail, t("这一步没有完成。", "This step didn't finish."),
                             t("再试一次；还不行就复制诊断信息发给我们。", "Try again, or copy Diagnostics and send it to us."))
            }
        }
        switch code {
        case "unlock_needed": return (.wait, t("请解锁 iPad…", "Unlock your iPad…"), nil)
        // The cable came out after the first step: say so instead of a generic wait.
        case "no_usb_ipad": return (.wait, t("没有连着 iPad，请插上数据线并解锁…", "No iPad connected. Plug in the cable and unlock it…"), nil)
        case "multiple_usb_ipads": return (.wait, t("连着不止一台 iPad，只保留要用的那台。", "More than one iPad is connected. Keep only the one you want."), nil)
        case "trust_needed":
            let long = flow.trustSince.map { now - $0 >= 30 } ?? false
            return (.wait, t("正在等你在 iPad 上点「信任」…", "Waiting for you to tap Trust on the iPad…"),
                    long ? t("没看到提示？拔下数据线再插上。", "No prompt? Unplug the cable, plug it back in.") : nil)
        case "developer_mode_auto": return (.wait, t("Toss 正在打开开发者模式，iPad 会自动重启一次…", "Toss is turning on Developer Mode; your iPad restarts once…"), nil)
        case "developer_mode_needed": return (.wait, t("正在等你在 iPad 上打开开关…", "Waiting for you to switch it on on your iPad…"),
                                            t("点完 iPad 会自己重启，重启后会弹出提示。", "Your iPad then restarts and shows a prompt."))
        case "ipad_restarting": return (.wait, t("iPad 正在重启，数据线别拔…", "Your iPad is restarting; keep the cable in…"),
                                        t("重启后解锁 iPad，会弹出「打开开发者模式？」。", "After the restart, unlock it; the Turn On Developer Mode prompt appears."))
        case "developer_mode_confirm": return (.wait, t("在 iPad 的弹窗里点「打开」，输入锁屏密码", "On your iPad, tap Turn On and enter your passcode"),
                                                   t("输完 Toss 会自动继续。", "Toss continues by itself."))
        case "pairing_wireless": return (.wait, t("正在建立无线配对…", "Setting up wireless pairing…"), nil)
        case "preparing_image": return (.wait, t("正在安装截图组件…\n第一次要联网，约 1 分钟", "Installing the screenshot component…\nNeeds internet the first time, about a minute"), nil)
        case "wifi_waiting": return (.wait, t("USB 已连接，正在设置无线连接…", "USB is connected; setting up wireless…"),
                                     t("插着线已经能截图，但这一步要等无线好了才算完成。", "USB already works, but this step needs wireless."))
        default: return (.wait, t("正在等待 iPad…", "Waiting for the iPad…"), nil)
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
    var onFinish: () -> Void = {}
    var onClose: () -> Void = {}

    private(set) var flow = OnboardingFlow()
    let copy: OnboardingCopy
    let window: NSWindow
    private let stack = NSStackView()
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
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
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
    func setupCode(_ code: String, final: Bool, ipados: String?) {
        flow.receive(code: code, final: final, ipados: ipados, at: now()); render(); scheduleAdvance()
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
        case .done: onFinish(); window.close(); return
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
    @objc private func back() {
        let target: OnboardingStep = flow.step == .tryIt ? .wifi : OnboardingStep(rawValue: max(0, flow.step.rawValue - 1)) ?? .welcome
        flow.step = flow.step == .cable ? (flow.includesMenuBar ? .menubar : .access) : target
        render()
    }
    @objc private func skip() { flow.step = .done; render() }
    @objc private func cableOnly() { onCableOnly(); window.close() }
    // macOS may only re-read Accessibility when Toss starts; the relaunch comes back to this step.
    @objc private func reopen() { onReopen() }

    func windowWillClose(_ notification: Notification) {
        tick?.invalidate(); tick = nil
        advanceTimer?.invalidate(); advanceTimer = nil
        onClose()
    }

    // MARK: drawing
    private func label(_ text: String, _ font: NSFont, _ color: NSColor, width: CGFloat? = nil) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = font; l.textColor = color; l.isSelectable = false
        // A little air between wrapped lines (2026-10-30).
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

    func render() {
        let t = now()
        // Rebuild only when something visible changed, so the pulsing dot and the activity bar keep running.
        let (mark, text, sub) = copy.status(flow, at: t)
        let signature = "\(flow.step) \(mark) \(text) \(sub ?? "") \(copy.primary(flow, at: t)) \(flow.showsPrimary(at: t)) \(flow.skippable) \(transport ?? "")"
        guard signature != shown else { return }
        shown = signature
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
        let why = copy.why(flow.step)
        if !why.isEmpty { stack.addArrangedSubview(gap(10)); stack.addArrangedSubview(label(why, SettingsStyle.sans(14), SettingsStyle.muted, width: inner)) }
        let steps = copy.howto(flow.step)
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
        if flow.step == .prepare && flow.mark(at: t) == .wait {
            let bar = SettingsActivityBar(); bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: inner).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 2).isActive = true
            stack.addArrangedSubview(gap(18)); stack.addArrangedSubview(bar); bar.animating = true
        }
        if flow.step == .tryIt || flow.step == .done {
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
        let backButton = SettingsPill(copy.back, kind: .quiet, target: self, action: #selector(back))
        backButton.isHidden = !flow.showsBack
        var right: [NSView] = []
        if flow.skippable { right.append(SettingsPill(copy.skip, kind: .quiet, target: self, action: #selector(skip))) }
        if flow.showsStaleAccessHint(at: t) {
            right.append(SettingsPill(copy.reopen, kind: .quiet, target: self, action: #selector(reopen)))
        }
        if flow.step == .wifi && flow.mark(at: t) == .fail {
            right.append(SettingsPill(copy.cableOnly, kind: .quiet, target: self, action: #selector(cableOnly)))
        }
        if flow.showsPrimary(at: t) {
            let main = SettingsPill(copy.primary(flow, at: t), kind: .filled, compact: false, target: self, action: #selector(primary))
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
    // Sizes of the ink lines in the list and the status (2026-10-30: kept at 14 / 13.5
    // after a size comparison).
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
