import AppKit
import CoreText

@MainActor
private final class RenderPreferences: StartupPreferenceStoring {
    var desiredEnabled = false
    var loginChoiceMade = false
    func clearOwnedPreferences() { preconditionFailure("Rendering must not clear preferences") }
}
@MainActor
private final class RenderLogin: StartupLoginManaging {
    var status: StartupLoginStatus { .notRegistered }
    func register() throws { preconditionFailure("Rendering must not register") }
    func unregister() async throws { preconditionFailure("Rendering must not unregister") }
}
@MainActor
private final class RenderDefaults: UninstallPreferenceClearing {
    var removed: [String] = []
    var synchronized = false
    func removeObject(forKey key: String) { removed.append(key) }
    func removePersistentDomain(forName domainName: String) { preconditionFailure("Not an onboarding key operation") }
    func synchronize() -> Bool { synchronized = true; return true }
}

// Compile the actual settings view with TOSS_RENDER, without TossMain. Do not
// set the NSApp delegate, prepareInterface, open windows or start its run loop.
@main
@MainActor
struct UninstallUITests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func checkLayout(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        for control in descendants(view) where !control.isHiddenOrHasHiddenAncestor {
            guard control is NSTextField || control is NSButton else { continue }
            let rect = control.convert(control.bounds, to: view)
            check(rect.minX >= -0.5 && rect.maxX <= view.bounds.maxX + 0.5 &&
                  rect.minY >= -0.5 && rect.maxY <= view.bounds.maxY + 0.5,
                  "Control inside window: \(control)")
            if let button = control as? SettingsPill {
                check(button.bounds.width >= button.intrinsicContentSize.width - 0.5 &&
                      button.bounds.height >= button.intrinsicContentSize.height - 0.5, "Complete pill copy: \(button.title)")
            }
            if let label = control as? NSTextField, !label.stringValue.isEmpty, let cell = label.cell {
                let required = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10_000))
                check(required.height <= label.bounds.height + 1, "Text height: \(label.stringValue)")
                if !cell.wraps { check(required.width <= label.bounds.width + 1, "Text width: \(label.stringValue)") }
            }
        }
    }

    static func render(_ window: NSWindow, name: String, output: URL?) throws {
        guard let output, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fatalError("No bitmap") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        // Offscreen content snapshots omit NSWindow's background. Composite the
        // actual window background beneath the snapshot, at the same pixel scale.
        let image = NSImage(size: content.bounds.size)
        image.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.backgroundColor.setFill()
            content.bounds.fill()
            let foreground = NSImage(size: content.bounds.size)
            foreground.addRepresentation(bitmap)
            foreground.draw(in: content.bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent(name + ".png"))
        print("\(name): \(Int(content.bounds.width)) × \(Int(content.bounds.height)) points")
    }

    static func main() throws {
        _ = NSApplication.shared
        let defaults = RenderDefaults()
        TossDelegate.clearOnboardingPreferences(in: defaults)
        check(defaults.removed == [OnboardingPolicy.seenKey, OnboardingPolicy.wirelessKey, OnboardingPolicy.resumeAccessKey,
                                  OnboardingPolicy.autoRelaunchKey, USBSetupDismissals.key, AppLanguage.key, TossDelegate.reopenSettingsKey] &&
              defaults.synchronized, "CLI and UI share complete owned onboarding/language cleanup")
        let fm = FileManager.default
        for url in try fm.contentsOfDirectory(at: URL(fileURLWithPath: "Assets/Fonts"), includingPropertiesForKeys: nil)
            where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let output = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
        if let output { try fm.createDirectory(at: output, withIntermediateDirectories: true) }
        for chinese in [false, true] {
            AppLanguage.override = chinese
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let suffix = "\(chinese ? "zh" : "en")-\(dark ? "dark" : "light")"
                for paired in [true, false] {
                    RenderState.paired = paired
                    RenderState.permissions = paired
                    RenderState.pairing = false
                    RenderState.connection = paired ? .init(state: .ready, reason: "ready", transport: "wifi") : .notChecked
                    let startup = StartupController(preferences: RenderPreferences(), service: RenderLogin())
                    let delegate = TossDelegate(startup: startup)
                    let window = delegate.renderSettingsWindow(enabled: paired)
                    window.appearance = appearance
                    let view = window.contentView!
                    checkLayout(view)
                    let pills = descendants(view).compactMap { $0 as? SettingsPill }
                    let link = pills.first { $0.title == UninstallCopy.link }!
                    check(link.kind == .quiet && link.image == nil, "Uninstall uses the existing quiet link")
                    let others = pills.filter { $0 !== link }
                    let linkRect = link.convert(link.bounds, to: view)
                    check(others.allSatisfy { $0.convert($0.bounds, to: view).minY > linkRect.maxY }, "Uninstall is the final settings row")
                    check(linkRect.minY >= SettingsStyle.settingsBottom - 0.5, "Bottom breathing room")
                    try render(window, name: "settings-\(suffix)-\(paired ? "paired" : "unpaired")", output: output)

                    // Real settings target/action -> sheet -> injected confirmation.
                    var confirmed = 0
                    RenderState.onUninstallConfirmed = { confirmed += 1 }
                    link.performClick(nil)
                    let firstSheet = delegate.renderUninstallSheet()!
                    check(confirmed == 0, "Opening confirmation performs no cleanup")
                    firstSheet.cancelButton.performClick(nil)
                    check(confirmed == 0 && delegate.renderUninstallSheet() == nil, "Cancel dismisses without cleanup")
                    link.performClick(nil)
                    let secondSheet = delegate.renderUninstallSheet()!
                    secondSheet.uninstallButton.performClick(nil)
                    secondSheet.uninstallButton.performClick(nil)
                    check(confirmed == 1, "Confirm invokes cleanup only once")
                    window.orderOut(nil)
                }

                let sheet = UninstallSheet()
                let window = sheet.window!
                window.appearance = appearance
                checkLayout(window.contentView!)
                check(sheet.titleLabel.stringValue == (chinese ? "卸载 Toss？" : "Uninstall Toss?"), "Exact title")
                check(sheet.bodyLabel.stringValue == (chinese ? "配对和设置都会删掉，iPad 上不用动。" :
                      "Pairing and settings will be removed. Nothing to do on your iPad."), "Exact body")
                check(sheet.cancelButton.title == (chinese ? "取消" : "Cancel") &&
                      sheet.uninstallButton.title == (chinese ? "卸载" : "Uninstall"), "Exact buttons")
                check(sheet.cancelButton.frame.minX < sheet.uninstallButton.frame.minX, "Cancel before Uninstall")
                check(sheet.cancelButton.kind == .ghost && sheet.uninstallButton.kind == .filled, "Existing neutral pills")
                check(sheet.cancelButton.keyEquivalent == "\u{1b}" && sheet.uninstallButton.keyEquivalent.isEmpty,
                      "Escape cancels; Return never accidentally confirms")
                let titleCascade = sheet.titleLabel.font!.fontDescriptor.object(forKey: .cascadeList) as! [NSFontDescriptor]
                let bodyCascade = sheet.bodyLabel.font!.fontDescriptor.object(forKey: .cascadeList) as! [NSFontDescriptor]
                check(titleCascade.contains { $0.postscriptName == "STSongti-SC-Bold" }, "Songti title fallback")
                check(bodyCascade.contains { $0.postscriptName?.contains("HiraginoSansGB") == true }, "Hiragino body fallback")
                check(window.backgroundColor == SettingsStyle.background, "Existing paper/dark palette")
                // The sheet paints the Settings background itself, so no lighter sheet material shows through.
                if let paper = window.contentView?.subviews.first(where: { $0 is UninstallSheetBackground }) {
                    paper.layoutSubtreeIfNeeded(); paper.updateLayer()
                    var expected: NSColor?
                    paper.effectiveAppearance.performAsCurrentDrawingAppearance { expected = SettingsStyle.background.usingColorSpace(.sRGB) }
                    let actual = paper.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
                    check(actual != nil && expected != nil &&
                          abs(actual!.redComponent - expected!.redComponent) < 0.002 &&
                          abs(actual!.greenComponent - expected!.greenComponent) < 0.002 &&
                          abs(actual!.blueComponent - expected!.blueComponent) < 0.002 && actual!.alphaComponent == 1,
                          "Sheet background equals the Settings window background")
                    check(paper.frame.size == window.contentView!.bounds.size, "Background covers the whole sheet")
                } else { check(false, "Sheet background view present") }
                check(window.isOpaque, "Opaque sheet")
                try render(window, name: "uninstall-confirm-\(suffix)", output: output)
            }
        }
        AppLanguage.override = nil
        RenderState.onUninstallConfirmed = nil
        print("Uninstall UI: \(assertions) assertions passed; 12 offscreen views; injected login service; no app startup or uninstall effects.")
    }
}
