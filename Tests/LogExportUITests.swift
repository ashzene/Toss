import AppKit
import CoreText

// Native, offscreen layout tests only. Never construct TossDelegate or start a capture.
@main
@MainActor
struct LogExportUITests {
    static func main() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        for font in try fm.contentsOfDirectory(at: URL(fileURLWithPath: "Assets/Fonts"), includingPropertiesForKeys: nil)
            where font.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
        let output = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
        if let output { try fm.createDirectory(at: output, withIntermediateDirectories: true) }
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func render(_ view: NSView, name: String) throws {
            guard let output, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        for chinese in [false, true] {
            AppLanguage.override = chinese
            for dark in [false, true] {
                for paired in [false, true] {
                    let panel = TossStatusPanel()
                    panel.loadViewIfNeeded()
                    panel.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    panel.update(.init(connection: .init(state: .ready, reason: "ready"), phase: .idle,
                                       paired: paired, enabled: true))
                    panel.view.frame.size = panel.preferredContentSize
                    panel.view.layoutSubtreeIfNeeded()
                    let buttons = descendants(panel.view).compactMap { $0 as? SettingsPill }
                    let export = buttons.first { $0.title == L("Export Logs", "导出日志") }!
                    let diagnostics = buttons.first { $0.title == L("Diagnostics", "诊断信息") }!
                    check(export.kind == .quiet && diagnostics.kind == .quiet, "same existing quiet style")
                    check(export.image == nil, "no added icon")
                    check(abs(diagnostics.frame.minX - export.frame.maxX - 8) < 0.5, "same eight-point gap")
                    for button in buttons where !button.isHidden {
                        let frame = button.convert(button.bounds, to: panel.view)
                        check(frame.minX >= 19.5 && frame.maxX <= panel.view.bounds.maxX - 19.5,
                              "localized controls stay inside margins")
                        check(button.frame.width >= button.intrinsicContentSize.width - 0.5, "no clipped button text")
                    }
                    var clicked = 0
                    panel.onExportLogs = { clicked += 1 }
                    export.performClick(nil)
                    check(clicked == 1, "export callback connected")
                    panel.exportingLogs = true
                    export.performClick(nil)
                    check(!export.isEnabled && clicked == 1 && diagnostics.isEnabled, "only export disabled while busy")
                    panel.exportingLogs = false
                    check(export.isEnabled, "export can retry")
                    let name = "menu-\(chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(paired ? "paired" : "unpaired")"
                    try render(panel.view, name: name)
                    print("\(name): \(Int(panel.view.bounds.width)) × \(Int(panel.view.bounds.height))")
                }
                for success in [true, false] {
                    let view = LogExportNotice.makeView(success: success)
                    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let text = view.accessibilityLabel()!
                    let width = (text as NSString).size(withAttributes: [.font: SettingsStyle.sans(13, .medium)]).width
                    check(width <= view.bounds.width - 2 * CaptureCardLayout.shadowMargin - 58, "complete notice fits")
                    if success {
                        check(text == L("Logs are ready and copied. Just paste to send them to us.", "日志已准备好，已复制，直接粘贴发给我们就行"), "localized success copy")
                    } else {
                        check(text == L("Couldn't export logs. Try again.", "导出没成功，再试一次"), "localized failure copy")
                    }
                    try render(view, name: "notice-\(chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(success ? "success" : "failure")")
                }
            }
        }
        AppLanguage.override = nil
        print("Log export UI: \(count) assertions passed; no app, capture or notification launched.")
    }
}
