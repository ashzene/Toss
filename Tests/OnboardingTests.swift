import AppKit
import CoreText

@main
struct OnboardingTests {
    @MainActor static func main() {
        var count = 0
        func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("line \(line)") }; count += 1 }

        // Every setup_device.py code shown on its step.
        let stages: [String: OnboardingStep] = [
            "no_usb_ipad": .cable, "multiple_usb_ipads": .cable, "unlock_needed": .cable, "unsupported_ipados": .cable,
            "trust_needed": .trust, "developer_mode_auto": .devmode, "developer_mode_needed": .devmode,
            "ipad_restarting": .devmode, "developer_mode_confirm": .devmode, "pairing_wireless": .prepare,
            "preparing_image": .prepare, "pairing_failed": .prepare, "developer_image_failed": .prepare,
            "wifi_waiting": .wifi, "wifi_unreachable": .wifi, "ready": .wifi]
        for (code, step) in stages { check(OnboardingFlow.stage(for: code) == step) }
        for code in ["cancelled", "setup_timeout", "setup_failed", "setup_unavailable"] { check(OnboardingFlow.stage(for: code) == nil) }
        check(OnboardingFlow().counted == 8 && OnboardingStep.done.rawValue == 9)

        // A whole first pairing: each step turns green, then moves on; never backward.
        var flow = OnboardingFlow()
        check(flow.mark(at: 0) == .none && flow.canContinue(at: 0))
        flow.step = .access
        check(flow.mark(at: 0) == .wait && !flow.canContinue(at: 0))
        flow.accessibility = true
        check(flow.mark(at: 0) == .ok && flow.canContinue(at: 0))
        flow.step = .cable
        flow.receive(code: "no_usb_ipad", final: false, ipados: nil, at: 10)
        check(flow.mark(at: 15) == .wait && !flow.advancesBySetup)
        check(flow.mark(at: 30) == .fail) // charge-only cable hint after 20 s
        flow.receive(code: "trust_needed", final: false, ipados: "18.1", at: 31)
        check(flow.mark(at: 31) == .ok && flow.advancesBySetup && flow.waitingForUSBSince == nil)
        flow.advance(); check(flow.step == .trust && flow.mark(at: 31) == .wait)
        flow.receive(code: "developer_mode_needed", final: false, ipados: nil, at: 40)
        flow.advance(); check(flow.step == .devmode && flow.ipados == "18.1")
        flow.receive(code: "ipad_restarting", final: false, ipados: nil, at: 50)
        check(flow.mark(at: 50) == .wait && !flow.advancesBySetup)
        flow.receive(code: "preparing_image", final: false, ipados: nil, at: 60)
        flow.advance(); check(flow.step == .prepare)
        flow.receive(code: "trust_needed", final: false, ipados: nil, at: 61)
        flow.advance(); check(flow.step == .prepare) // never backward

        // USB alone never counts: wifi_waiting stays grey; only the final "ready" is green.
        flow.receive(code: "wifi_waiting", final: false, ipados: nil, at: 70)
        flow.advance(); check(flow.step == .wifi && flow.mark(at: 70) == .wait && !flow.canContinue(at: 70))
        check(!flow.advancesBySetup)
        let zh = OnboardingCopy(language: .chinese), en = OnboardingCopy(language: .english)
        check(zh.status(flow, at: 70).1 == "USB 已连接，正在设置无线连接…")
        check(zh.settingUpStatus(code: "wifi_waiting") == "USB 已连接，正在设置无线连接…")
        flow.receive(code: "ready", final: false, ipados: nil, at: 71)
        check(flow.mark(at: 71) == .wait) // non-final "ready" is not proof
        flow.receive(code: "wifi_unreachable", final: true, ipados: nil, at: 80)
        check(flow.mark(at: 80) == .fail && zh.primary(flow, at: 80) == "再试一次")
        check(zh.status(flow, at: 80).1 == "在网络上找不到这台 iPad。")
        flow.final = false
        flow.receive(code: "ready", final: true, ipados: nil, at: 90)
        check(flow.wirelessReady && flow.mark(at: 90) == .ok && flow.canContinue(at: 90))
        check(zh.status(flow, at: 90).1 == "无线已就绪 ✓" && en.status(flow, at: 90).1 == "Wireless is ready ✓")
        check(!flow.advancesBySetup) // the wireless step waits for Continue

        // Try it is skippable; turns green on a confirmed toss.
        flow.step = .tryIt
        check(flow.skippable && !flow.canContinue(at: 0))
        flow.tossed = true
        check(!flow.skippable && flow.canContinue(at: 0) && flow.mark(at: 0) == .ok)

        // Failures with no step of their own fail the current step; unsupported iPadOS fails the cable step.
        var cancelled = OnboardingFlow(); cancelled.step = .devmode
        cancelled.receive(code: "cancelled", final: true, ipados: nil, at: 0)
        check(cancelled.mark(at: 0) == .fail && !cancelled.advancesBySetup)
        var old = OnboardingFlow(); old.step = .cable
        old.receive(code: "unsupported_ipados", final: true, ipados: "16.7", at: 0)
        check(old.mark(at: 0) == .fail && en.status(old, at: 0).1 == "This iPad's system is too old.")
        // Already paired: cable step jumps straight to the wireless one.
        var paired = OnboardingFlow(); paired.step = .cable
        paired.receive(code: "ready", final: true, ipados: nil, at: 0)
        check(paired.mark(at: 0) == .ok); paired.advance(); check(paired.step == .wifi && paired.mark(at: 0) == .ok)
        // Codes before the setup steps never move the welcome / access screens.
        var early = OnboardingFlow(); early.step = .access
        early.receive(code: "trust_needed", final: false, ipados: nil, at: 0)
        check(!early.advancesBySetup); early.advance(); check(early.step == .access)

        // Buttons.
        var b = OnboardingFlow()
        check(!b.showsBack); b.step = .access; check(b.showsBack); b.step = .wifi; check(!b.showsBack)
        b.step = .done; check(zh.primary(b, at: 0) == "完成" && en.primary(b, at: 0) == "Done")
        check(zh.cableOnly == "先只用数据线" && en.cableOnly == "Use cable only for now")
        check(zh.cableOnlyStatus == "只能插线用，无线还没设好")

        // Language follows the system; anything not Chinese is English.
        check(OnboardingLanguage.current(["zh-Hans-CN", "en-US"]) == .chinese)
        check(OnboardingLanguage.current(["zh-Hant-TW"]) == .chinese)
        check(OnboardingLanguage.current(["en-GB", "zh-Hans"]) == .english)
        check(OnboardingLanguage.current(["ja-JP"]) == .english && OnboardingLanguage.current([]) == .english)
        var line = OnboardingFlow(); line.step = .cable
        check(zh.stepLine(line) == "第 3 步，共 8 步" && en.stepLine(line) == "Step 3 of 8")
        line.step = .access; line.setMenuIcon(.hidden); line.step = .cable
        check(zh.stepLine(line) == "第 4 步，共 9 步")

        // Both languages have every string; Chinese copy has no English left over and vice versa.
        for step in OnboardingStep.allCases {
            check(!zh.title(step).isEmpty && !en.title(step).isEmpty && zh.title(step) != en.title(step))
            check(zh.howto(step).count == en.howto(step).count)
            check(step == .done || (!zh.why(step).isEmpty && !en.why(step).isEmpty))
        }
        for code in Array(stages.keys) + ["cancelled", "setup_timeout", "setup_failed"] {
            for final in [false, true] {
                for step in [OnboardingStep.cable, .trust, .devmode, .prepare, .wifi] {
                    var f = OnboardingFlow(); f.step = step
                    f.receive(code: code, final: final, ipados: "18.1", at: 0)
                    let (mz, tz, _) = zh.status(f, at: 0), (me, te, _) = en.status(f, at: 0)
                    check(mz == me && !tz.isEmpty && !te.isEmpty && tz != te)
                    check(te.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) == nil)
                }
            }
        }

        // Step 2: a switch that is on but not detected gets a hint after 10 s; never before the click.
        var acc = OnboardingFlow(); acc.step = .access
        check(!acc.showsStaleAccessHint(at: 100) && zh.status(acc, at: 100).2 == nil)
        acc.accessRequestedAt = 30
        check(!acc.showsStaleAccessHint(at: 59) && acc.showsStaleAccessHint(at: 60))
        check(zh.reopen == "重新打开 Toss" && en.reopen == "Reopen Toss" && zh.status(acc, at: 60).2?.contains("重新打开 Toss") == true)
        check(zh.status(acc, at: 60).2?.contains("删掉") == false && en.status(acc, at: 60).2?.contains("Reopen Toss") == true)
        acc.accessibility = true
        check(!acc.showsStaleAccessHint(at: 60) && zh.status(acc, at: 60).2 == nil)

        // Fully automatic: every detectable step moves on by itself; buttons only where the user acts.
        var auto = OnboardingFlow()
        check(auto.showsPrimary(at: 0) && auto.autoNext == nil)               // welcome: Start
        auto.step = .access
        check(auto.showsPrimary(at: 0) && auto.autoNext == nil)               // Open System Settings
        auto.accessibility = true
        check(!auto.showsPrimary(at: 0) && auto.autoNext == .cable)
        auto.advance(); check(auto.step == .cable && auto.needsSetupStart)
        auto.receive(code: "trust_needed", final: false, ipados: nil, at: 0)
        check(!auto.needsSetupStart && !auto.showsPrimary(at: 0) && auto.autoNext == .trust)
        auto.advance(); check(!auto.showsPrimary(at: 0) && auto.autoNext == nil) // waits for Trust on the iPad
        auto.receive(code: "wifi_waiting", final: false, ipados: nil, at: 0)
        auto.advance(); check(auto.step == .wifi && auto.autoNext == nil && !auto.showsPrimary(at: 0)) // USB only: no move
        auto.receive(code: "wifi_unreachable", final: true, ipados: nil, at: 0)
        check(auto.showsPrimary(at: 0) && auto.autoNext == nil)               // Try Again (+ cable only)
        auto.final = false
        auto.receive(code: "ready", final: true, ipados: nil, at: 0)
        check(auto.autoNext == .tryIt && !auto.showsPrimary(at: 0))
        auto.advance(); check(auto.step == .tryIt && auto.autoNext == nil && auto.skippable)
        auto.tossed = true; check(auto.autoNext == .done); auto.advance(); check(auto.step == .done && auto.showsPrimary(at: 0))
        // Arriving on the cable step: start pairing unless it already ran to "ready" or is running.
        var start = OnboardingFlow(); start.step = .cable
        check(start.needsSetupStart)
        start.receive(code: "ready", final: true, ipados: nil, at: 0); check(!start.needsSetupStart)
        start.receive(code: "setup_timeout", final: true, ipados: nil, at: 0); check(start.needsSetupStart)
        start.receive(code: "no_usb_ipad", final: false, ipados: nil, at: 0); check(!start.needsSetupStart)
        // Relaunching: step 2 says so and drops the fallback.
        var rel = OnboardingFlow(); rel.step = .access; rel.accessRequestedAt = 0; rel.relaunching = true
        check(!rel.showsStaleAccessHint(at: 100) && zh.status(rel, at: 100).1 == "已允许，正在重新打开 Toss…"
              && en.status(rel, at: 100).1 == "Allowed, reopening Toss…")
        // No remove-and-re-add instructions anywhere (2026-10-29).
        var anyText = ""
        for copy in [zh, en] {
            for step in OnboardingStep.allCases { anyText += copy.title(step) + copy.why(step) + copy.howto(step).joined() }
            var a2 = OnboardingFlow(); a2.step = .access; a2.accessRequestedAt = 0
            anyText += (copy.status(a2, at: 100).2 ?? "")
        }
        for banned in ["−", "\u{2212}", "删掉", "加回来", "remove it", "add it back", "add Toss back"] { check(!anyText.contains(banned)) }

        // Out-of-order, repeated and skipped codes: never backward, never stuck.
        var o = OnboardingFlow(); o.step = .cable
        for c in ["no_usb_ipad", "no_usb_ipad", "unlock_needed", "no_usb_ipad"] { o.receive(code: c, final: false, ipados: nil, at: 0) }
        check(o.mark(at: 5) == .wait && o.step == .cable)
        o.receive(code: "preparing_image", final: false, ipados: nil, at: 6) // trust and Developer Mode were already done
        check(o.advancesBySetup); o.advance(); check(o.step == .prepare)
        o.receive(code: "no_usb_ipad", final: false, ipados: nil, at: 7) // cable pulled mid-way
        o.advance(); check(o.step == .prepare && o.mark(at: 60) == .wait) // no charge-only failure outside the cable step
        check(zh.status(o, at: 60).1.contains("插上数据线") && en.status(o, at: 60).1.contains("Plug in"))
        o.receive(code: "preparing_image", final: false, ipados: nil, at: 8)
        o.receive(code: "preparing_image", final: false, ipados: nil, at: 9)
        check(o.step == .prepare && o.mark(at: 9) == .wait)
        o.receive(code: "ready", final: true, ipados: nil, at: 10)
        o.advance(); check(o.step == .wifi && o.mark(at: 10) == .ok)
        // A failure with no step code (startSetup refused, timeout) fails whichever step is showing.
        for step in [OnboardingStep.cable, .trust, .devmode, .prepare, .wifi] {
            var f = OnboardingFlow(); f.step = step
            f.receive(code: "setup_unavailable", final: true, ipados: nil, at: 0)
            check(f.mark(at: 0) == .fail && zh.primary(f, at: 0) == "再试一次" && !f.advancesBySetup)
        }
        // Try Again clears the failure; the old code no longer counts as final.
        var again = OnboardingFlow(); again.step = .wifi
        again.receive(code: "wifi_unreachable", final: true, ipados: nil, at: 0)
        again.final = false
        check(again.mark(at: 0) == .wait && !again.wirelessReady)
        // Only a final "ready" while on the wireless step is green; "ready" seen earlier is a pass, not wireless.
        var w = OnboardingFlow(); w.step = .wifi
        w.receive(code: "wifi_waiting", final: true, ipados: nil, at: 0)
        check(w.mark(at: 0) == .fail && !w.wirelessReady)

        check(zh.howto(.access)[1] == "打开 Toss 的开关\n会要密码或指纹")

        // "Main\nextra" shows the extra part as a smaller second line; no parentheses in UI text.
        check(OnboardingCopy.split("一根能传数据的 USB 线\n只能充电的线不行") == ("一根能传数据的 USB 线", "只能充电的线不行"))
        check(OnboardingCopy.split("iPad 解锁，放在手边") == ("iPad 解锁，放在手边", nil))
        func noParens(_ text: String) -> Bool { text.range(of: "[()（）]", options: .regularExpression) == nil }
        for copy in [zh, en] {
            for step in OnboardingStep.allCases {
                check(noParens(copy.title(step) + copy.why(step) + copy.howto(step).joined()))
            }
            for code in Array(stages.keys) + ["cancelled", "setup_timeout", "setup_failed", "setup_unavailable"] {
                for final in [false, true] {
                    for step in OnboardingStep.allCases {
                        var f = OnboardingFlow(); f.step = step; f.accessRequestedAt = 0
                        f.receive(code: code, final: final, ipados: "18.1", at: 0)
                        let (_, text, sub) = copy.status(f, at: 100)
                        check(noParens(text + (sub ?? "")))
                    }
                }
            }
        }
        let dir = CommandLine.arguments.count > 1 ? (CommandLine.arguments[1] as NSString).deletingLastPathComponent : ""
        // Every grey line fits on one line, measured with the real font at the width where it's shown.
        let fontsDir = CommandLine.arguments.count > 1 ? ((CommandLine.arguments[1] as NSString).deletingLastPathComponent as NSString).appendingPathComponent("../Assets/Fonts") : ""
        for file in (try? FileManager.default.contentsOfDirectory(atPath: fontsDir)) ?? [] where file.hasSuffix(".ttf") {
            CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: fontsDir).appendingPathComponent(file) as CFURL, .process, nil)
        }
        func fits(_ text: String, _ size: CGFloat, _ width: CGFloat) -> Bool {
            let w = NSAttributedString(string: text, attributes: [.font: SettingsStyle.sans(size)]).size().width
            if w > width { fputs("too wide (\(Int(w)) > \(Int(width))): \(text)\n", stderr) }
            return w <= width && !text.contains("\n")
        }
        let inner = SettingsStyle.width - 2 * SettingsStyle.margin
        check(NSFont(name: "HankenGrotesk-Regular", size: 12) != nil) // measured with the real font
        check(NSAttributedString(string: String(repeating: "宽", count: 30), attributes: [.font: SettingsStyle.sans(12.5)]).size().width > 278)
        for copy in [zh, en] {
            for step in OnboardingStep.allCases { check(fits(copy.why(step), 14, inner)) }
            for row in copy.shortcutRows { check(fits(row.note, 12.5, inner - 120)) }
            check(fits(copy.iPadRow.note, 12.5, inner - 160))
            for step in OnboardingStep.allCases { for item in copy.howto(step) { if let extra = OnboardingCopy.split(item).extra { check(fits(extra, 12.5, inner - 28)) } } }
            for step in OnboardingStep.allCases { for item in copy.howto(step) { check(fits(OnboardingCopy.split(item).main, OnboardingController.mainSize, inner - 28)) } }
            for code in Array(stages.keys) + ["cancelled", "setup_timeout", "setup_failed", "setup_unavailable"] {
                for final in [false, true] {
                    for step in OnboardingStep.allCases {
                        var f = OnboardingFlow(); f.step = step; f.accessRequestedAt = 0
                        f.receive(code: code, final: final, ipados: "18.1", at: 0)
                        for at in [0.0, 100.0] {
                            let (_, text, sub) = copy.status(f, at: at)
                            if let extra = OnboardingCopy.split(text).extra { check(fits(extra, 12.5, inner - 22)) }
                            check(fits(OnboardingCopy.split(text).main, OnboardingController.statusSize, inner - 22))
                            if let sub { check(fits(sub, 12.5, inner - 22)) }
                        }
                    }
                }
            }
        }
        // Notes in Settings (278 pt) and the menu-bar panel (300 pt): every message these files can show.
        if !dir.isEmpty {
            let pair = try! NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)"\)"#)
            for (file, width) in [("SetupWizard.swift", 278.0), ("ConnectionStatus.swift", 278.0), ("StartupController.swift", 278.0),
                                  ("TossError.swift", 300.0), ("StrictTarget.swift", 300.0), ("CaptureWorker.swift", 300.0)] {
                let source = (try? String(contentsOfFile: dir + "/" + file, encoding: .utf8)) ?? ""
                for m in pair.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    for i in [1, 2] {
                        let text = String(source[Range(m.range(at: i), in: source)!])
                        check(fits(text, 12.5, CGFloat(width)))
                    }
                }
            }
        }
        // The grey line under each title stays one line wide (468 pt column, 14 pt text).
        for copy in [zh, en] {
            for step in OnboardingStep.allCases where step != .done {
                let why = copy.why(step)
                check(!why.isEmpty && !why.contains("\n"))
                let width = NSAttributedString(string: why, attributes: [.font: NSFont.systemFont(ofSize: 14)]).size().width
                if width > 450 { fputs("too wide: \(why) \(width)\n", stderr) }
                check(width <= 450)
            }
        }

        // Chinese in headings uses Songti SC Bold; Latin stays Source Serif 4; body Chinese stays PingFang.
        func cjkFamily(_ font: NSFont) -> String {
            let run = CTFontCreateForString(font as CTFont, "欢迎" as CFString, CFRange(location: 0, length: 2))
            return CTFontCopyFamilyName(run) as String
        }
        if NSFont(name: "STSongti-SC-Bold", size: 12) != nil {
            check(cjkFamily(SettingsStyle.serif(26)).contains("Songti"))
            check(!cjkFamily(SettingsStyle.sans(14)).contains("Songti"))
        }

        // Menu-bar icon: detection and the extra step (macOS 26 can hide it, or the notch can).
        let notch = CGRect(x: 700, y: 1080, width: 200, height: 37)
        check(MenuIconPolicy.classify(frame: CGRect(x: 1300, y: 1090, width: 24, height: 24), onScreen: true, notches: [notch]) == .visible)
        check(MenuIconPolicy.classify(frame: CGRect(x: 760, y: 1090, width: 24, height: 24), onScreen: true, notches: [notch]) == .notch)
        check(MenuIconPolicy.classify(frame: CGRect(x: 1300, y: 1090, width: 24, height: 24), onScreen: false, notches: []) == .hidden)
        check(MenuIconPolicy.classify(frame: nil, onScreen: true, notches: []) == .hidden)
        var mb = OnboardingFlow(); mb.step = .welcome; mb.setMenuIcon(.hidden)
        check(!mb.includesMenuBar)                       // not decided before the Accessibility step
        mb.step = .access; mb.accessibility = true; mb.setMenuIcon(.hidden)
        check(mb.includesMenuBar && mb.autoNext == .menubar)
        mb.advance(); check(mb.step == .menubar && mb.mark(at: 0) == .wait && mb.showsPrimary(at: 0) && mb.autoNext == nil)
        mb.setMenuIcon(.visible); check(mb.mark(at: 0) == .ok && mb.autoNext == .cable)
        mb.advance(); check(mb.step == .cable && mb.needsSetupStart && mb.number == 4 && mb.counted == 9)
        var shown = OnboardingFlow(); shown.step = .access; shown.accessibility = true
        check(shown.autoNext == .cable && shown.counted == 8)  // visible icon: no extra step
        var alone = OnboardingFlow(); alone.standaloneMenuBar = true; alone.includesMenuBar = true; alone.step = .menubar; alone.menuIcon = .notch
        check(alone.autoNext == nil && !alone.showsBack && zh.stepLine(alone) == "菜单栏图标")
        check(zh.status(alone, at: 0).1 == "Toss 已经打开，但图标被刘海挡住了" && zh.primary(alone, at: 0) == "完成")

        // Opens by itself on first run or while unpaired, only until it was closed once.
        check(OnboardingPolicy.opensAutomatically(paired: false, firstRun: false, seen: false))
        check(OnboardingPolicy.opensAutomatically(paired: true, firstRun: true, seen: false))
        check(!OnboardingPolicy.opensAutomatically(paired: true, firstRun: false, seen: false))
        // A close on the welcome step (before Start) is not "seen"; any later step is.
        check(!OnboardingPolicy.closeMarksSeen(step: .welcome))
        for step in OnboardingStep.allCases where step != .welcome { check(OnboardingPolicy.closeMarksSeen(step: step)) }
        check(!OnboardingPolicy.opensAutomatically(paired: false, firstRun: true, seen: true))

        // TossApp wiring: alerts stay off while the onboarding shows; USB-only pairing still turns shortcuts on.
        let app = (try? String(contentsOfFile: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "", encoding: .utf8)) ?? ""
        if !app.isEmpty {
            check(app.contains("let result = onboarding?.isVisible == true ? nil : result"))
            check(app.contains("result.code == \"ready\" || (result.code == \"wifi_unreachable\" && hasPairing)"))
            check(app.contains("onboarding?.setupCode(result.code, final: true"))
            check(app.contains("self.onboarding?.tossed()"))
            check(app.contains("if !hasPairing { showOnboarding(); return }"))
            check(app.contains("guard onboarding?.isVisible != true else { return }")) // no auto pairing/permission prompt behind it
            check(app.contains("if onboarding?.isVisible == true { showOnboarding(); return true }"))
            check(app.contains("self.onboarding?.setupCode(\"setup_unavailable\", final: true"))
            check(app.contains("if setupWizard.isRunning, permissionsReady, controller.flow.step"))
            check(app.contains("else if onboarding?.isVisible != true { lastPermissionStep"))
            check(app.contains("currentConnection.transport != \"wifi\""))
            check(app.contains("for key in [OnboardingPolicy.seenKey, OnboardingPolicy.wirelessKey, OnboardingPolicy.resumeAccessKey,"))
            check(app.contains("guard output == \"ax=true post=true\", onboarding?.isVisible == true, !permissionsReady"))
            check(app.contains("guard Date().timeIntervalSince1970 - last > 120 else { return }"))
            check(app.range(of: "--check-accessibility")!.lowerBound < app.range(of: "let application = NSApplication.shared")!.lowerBound)
            check(app.contains("UserDefaults.standard.set(true, forKey: OnboardingPolicy.resumeAccessKey)") && app.contains("self?.relaunch()"))
            check(app.contains("onboarding?.showRelaunching()"))
            check(app.contains("if controller.flow.step == .welcome { controller.jump(to: .access) }"))
            check(app.contains("if !self.terminating, OnboardingPolicy.closeMarksSeen(step: controller?.flow.step ?? .done) {"))
            check(app.contains("terminating = true\n        return .terminateNow"))
            // Closing never cancels the pairing: onClose must not call setupWizard.cancel().
            if let close = app.range(of: "controller.onClose = {"), let end = app.range(of: "onboarding = controller", range: close.upperBound..<app.endIndex) {
                check(!app[close.upperBound..<end.lowerBound].contains("cancel"))
            } else { check(false) }
        }
        // The window: closing it reports once, stops its timers and the controller is released.
        weak var released: OnboardingController?
        var closes = 0
        autoreleasepool {
            let c = OnboardingController(language: .english)
            c.onClose = { closes += 1 }
            c.jump(to: .cable)
            c.setupCode("trust_needed", final: false, ipados: nil) // schedules the ✓-then-advance timer
            check(c.flow.step == .cable && c.flow.mark(at: 0) == .ok)
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            released = c
        }
        check(closes == 1 && released == nil)
        do {
            let c = OnboardingController(language: .chinese)
            check(c.window.title == "设置 Toss" && !c.isVisible && !c.window.isReleasedWhenClosed)
            c.jump(to: .tryIt); c.tossed(); check(c.flow.tossed)
            c.jump(to: .access); c.setAccessibility(true); check(c.flow.mark(at: 0) == .ok)
            let d = OnboardingController(language: .english); d.jump(to: .access); d.tossed(); check(!d.flow.tossed)
        }

        // Every L("English", "中文") pair in the app has both languages (Settings → Language).
        if !dir.isEmpty, let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            let pair = try! NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)"\)"#)
            var pairs = 0
            for file in files where file.hasSuffix(".swift") {
                let source = (try? String(contentsOfFile: dir + "/" + file, encoding: .utf8)) ?? ""
                for m in pair.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    let en = String(source[Range(m.range(at: 1), in: source)!]), zh = String(source[Range(m.range(at: 2), in: source)!])
                    pairs += 1
                    check(!en.isEmpty && !zh.isEmpty && en != zh)
                    check(en.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) == nil)
                    check(zh.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil || zh == "简体中文")
                    // No parentheses in UI text (string interpolation \(…) aside).
                    for text in [en, zh] {
                        let plain = text.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "", options: .regularExpression)
                        check(plain.range(of: "[()（）]", options: .regularExpression) == nil)
                    }
                }
            }
            check(pairs > 200)
        }
        check(AppLanguage.resolvesToChinese(choice: .system, preferred: ["zh-Hans-CN"]))
        check(!AppLanguage.resolvesToChinese(choice: .system, preferred: ["en-US", "zh-Hans"]))
        check(AppLanguage.resolvesToChinese(choice: .chinese, preferred: ["en-US"]))
        check(!AppLanguage.resolvesToChinese(choice: .english, preferred: ["zh-Hans"]))
        check(!AppLanguage.isChinese) // tests are not the app: always English unless overridden
        AppLanguage.override = true; check(L("Check", "检查") == "检查"); AppLanguage.override = nil

        // The uninstaller keeps Accessibility so a reinstall passes step 2 at once.
        if !dir.isEmpty {
            for name in ["Uninstall.command"] {
                let script = (try? String(contentsOfFile: dir + "/../" + name, encoding: .utf8)) ?? ""
                check(!script.isEmpty && !script.contains("tccutil") && script.contains("--unregister-login-item"))
            }
        }
        print("Onboarding: \(count) pure assertions passed; windows built but never shown; no device or setup process.")
    }
}
