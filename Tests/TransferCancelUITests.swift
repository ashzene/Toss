import AppKit
import CoreText

// Native controls and lifecycle only. No capture, clipboard, chat or pairing access.
@main
@MainActor
enum TransferCancelUITests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for font in try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "Assets/Fonts"),
                                                                 includingPropertiesForKeys: nil)
            where font.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        for chinese in [false, true] {
            AppLanguage.override = chinese
            for dark in [false, true] {
                let view = CaptureFeedbackView(frame: NSRect(origin: .zero, size: CaptureCardLayout.panelSize), scale: 2)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let button = view.subviews.compactMap { $0 as? NSButton }.first!
                let point = NSPoint(x: button.frame.midX, y: button.frame.midY)
                let m = CaptureCardLayout.shadowMargin
                var cancelled = 0
                view.showProgress(title: chinese ? "图片正在传过来… 94%\n还有 2 张" : "Image on its way… 94%\n2 more") {
                    cancelled += 1
                }
                check(!button.isHidden && button.isEnabled, "active transfer exposes cancel")
                check(view.bounds.contains(button.frame), "cross remains inside the visible panel")
                check(button.frame.midX < m + 20 && button.frame.midY > m + CaptureCardLayout.height - 20,
                      "cross sits at the top-left corner")
                check(view.hitTest(point) === button, "cross receives the click")
                check(button.acceptsFirstMouse(for: nil), "first click works while chat has focus")
                check(!button.acceptsFirstResponder && !button.needsPanelToBecomeKey, "cancel never needs keyboard focus")
                check(button.accessibilityLabel() == L("Cancel Capture", "取消截图"), "cancel is labeled for accessibility")
                button.performClick(nil)
                button.performClick(nil)
                check(cancelled == 1 && button.isHidden, "double click cannot cancel twice")
                view.showProgress(title: "99%") { cancelled += 1 }
                view.clear()
                button.performClick(nil)
                check(cancelled == 1 && view.hitTest(point) == nil, "retired progress cannot cancel a later transfer")
                view.showProgress(title: "99%") { cancelled += 1 }
                view.show(success: true, title: "Tossed", reduceMotion: true)
                button.performClick(nil)
                check(cancelled == 1 && button.isHidden, "success removes the old cancellation action")
                view.showProgress(title: "USB dropped")
                check(button.isHidden && view.hitTest(point) == nil, "informational notices do not cancel captures")
            }
        }
        AppLanguage.override = nil
        print("Transfer cancel UI: \(checks) assertions passed; no devices or chat accessed.")
        fflush(stdout)
        if CommandLine.arguments.contains("--preview") {
            let animation = CaptureAnimation()
            animation.showTransferNotice("图片正在传过来… 94%\n还有 2 张", requestID: "ui-preview") {
                animation.hideTransferNotice()
                print("PREVIEW_CANCELLED: production panel closed by its cross.")
                fflush(stdout)
                app.terminate(nil)
            }
            for window in app.windows where window.isVisible { window.title = "Toss Transfer Preview" }
            print("PREVIEW_READY")
            fflush(stdout)
            withExtendedLifetime(animation) { app.run() }
        }
    }
}
