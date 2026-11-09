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
                // Keep a completed receipt readable after the app returns to idle,
                // disconnects, or starts the next shortcut; no stale success on a new job.
                let receiptPanel = TossStatusPanel()
                receiptPanel.loadViewIfNeeded()
                receiptPanel.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for outcome in [TossCaptureResult.Outcome.confirmed, .unconfirmed, .manualPaste, .failed, .cancelled] {
                    let receipt = TossCaptureResult(target: "claude", outcome: outcome,
                        byteCount: 3_200_000, elapsedMilliseconds: 1400, transport: "wifi")
                    var presentation = TossStatusPresentation(connection: .init(state: .ready, reason: "ready", transport: "usb"),
                        phase: .idle, paired: true, enabled: true, summary: L("Ready", "已就绪"), lastCaptureResult: receipt)
                    receiptPanel.update(presentation)
                    receiptPanel.view.frame.size = receiptPanel.preferredContentSize
                    receiptPanel.view.layoutSubtreeIfNeeded()
                    let fields = descendants(receiptPanel.view).compactMap { $0 as? NSTextField }
                    let summary = fields.first { $0.accessibilityIdentifier() == "Toss.lastCapture.summary" }!
                    let detail = fields.first { $0.accessibilityIdentifier() == "Toss.lastCapture.detail" }
                    check(summary.stringValue == receipt.summary && !summary.isHiddenOrHasHiddenAncestor, "last receipt visible at idle")
                    check(summary.stringValue.hasSuffix("Wi-Fi"), "live USB connection cannot rewrite screenshot route")
                    check((detail?.stringValue ?? "") == receipt.detail &&
                          (detail?.isHiddenOrHasHiddenAncestor ?? true) == receipt.detail.isEmpty, "only unsuccessful outcomes have an explanation")
                    check(fields.contains { $0.stringValue == receipt.status }, "distinct receipt outcome")
                    for field in [summary, detail].compactMap({ $0 }) where !field.isHiddenOrHasHiddenAncestor {
                        let frame = field.superview!.convert(field.alignmentRect(forFrame: field.frame), to: receiptPanel.view)
                        check(frame.minX >= 19.5 && frame.maxX <= receiptPanel.view.bounds.maxX - 19.5, "receipt inside horizontal margins: \(frame), panel \(receiptPanel.view.bounds), text \(field.stringValue)")
                        check(frame.minY >= 0 && frame.maxY <= receiptPanel.view.bounds.maxY, "receipt inside vertical bounds")
                        check(field.frame.height >= field.fittingSize.height - 0.5, "wrapped receipt text is not clipped")
                    }
                    try render(receiptPanel.view, name: "receipt-\(chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(outcome)")
                    presentation.connection = .init(state: .disconnected, reason: "network_unavailable")
                    presentation.phase = .failed
                    receiptPanel.update(presentation)
                    check(summary.stringValue == receipt.summary, "disconnect does not erase last receipt")
                    presentation.captureInProgress = true
                    presentation.phase = .preparing
                    receiptPanel.update(presentation)
                    check(summary.isHiddenOrHasHiddenAncestor, "new shortcut never borrows previous metadata")
                    check(fields.contains { $0.stringValue == L("Current screenshot", "当前截图") }, "current and last screenshot are distinct")
                    presentation.captureInProgress = false
                    presentation.phase = .idle
                    receiptPanel.update(presentation)
                    check(!summary.isHiddenOrHasHiddenAncestor && summary.stringValue == receipt.summary, "receipt returns after unrelated idle status")
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
