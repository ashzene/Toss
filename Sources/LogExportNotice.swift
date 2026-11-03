import AppKit

// Uses the existing corner toast's palette, geometry, mark and timing. The longer
// export copy gets enough width, without changing the screenshot animation file.
@MainActor
final class LogExportNotice {
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    func show(success: Bool) {
        dismissal?.cancel()
        panel?.orderOut(nil)
        guard let screen = NSScreen.main else { return }
        let view = Self.makeView(success: success)
        let margin = CaptureCardLayout.shadowMargin
        let size = view.frame.size
        let width = size.width - margin * 2
        let frame = NSRect(x: screen.visibleFrame.maxX - CaptureCardLayout.edgeInset - width - margin,
                           y: screen.visibleFrame.minY + CaptureCardLayout.edgeInset - margin,
                           width: size.width, height: size.height)
        let panel = NoticePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.sharingType = .none
        panel.animationBehavior = .none
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CaptureCardTiming.appear
            panel.animator().alphaValue = 1
        }
        let dismissal = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = CaptureCardTiming.fadeOut
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                DispatchQueue.main.async {
                    panel?.orderOut(nil)
                    if self?.panel === panel { self?.panel = nil }
                }
            }
        }
        self.dismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: dismissal)
    }

    static func makeView(success: Bool) -> NSView {
        let title = success
            ? L("Logs are ready and copied. Just paste to send them to us.", "日志已准备好，已复制，直接粘贴发给我们就行")
            : L("Couldn't export logs. Try again.", "导出没成功，再试一次")
        let font = SettingsStyle.sans(13, .medium)
        let width = max(CaptureCardLayout.width, ceil((title as NSString).size(withAttributes: [.font: font]).width) + 58)
        let size = NSSize(width: width + CaptureCardLayout.shadowMargin * 2, height: CaptureCardLayout.panelSize.height)
        return NoticeView(frame: NSRect(origin: .zero, size: size), title: title, success: success)
    }

    private final class NoticePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class NoticeView: NSView {
        let title: String
        let success: Bool
        init(frame: NSRect, title: String, success: Bool) {
            self.title = title
            self.success = success
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(title)
        }
        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            let margin = CaptureCardLayout.shadowMargin
            let rect = bounds.insetBy(dx: margin, dy: margin)
            let card = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.set()
            SettingsStyle.background.setFill()
            card.fill()
            NSGraphicsContext.restoreGraphicsState()
            SettingsStyle.line.setStroke()
            card.lineWidth = 1
            card.stroke()
            (title as NSString).draw(at: NSPoint(x: rect.minX + 42, y: rect.minY + 19),
                withAttributes: [.font: SettingsStyle.sans(13, .medium), .foregroundColor: SettingsStyle.ink])
            let box = CaptureCardLayout.markFrame.offsetBy(dx: margin, dy: margin).insetBy(dx: 5, dy: 5)
            let mark = NSBezierPath()
            if success {
                mark.move(to: NSPoint(x: box.minX, y: box.minY + 4.5))
                mark.line(to: NSPoint(x: box.minX + 3.6, y: box.minY + 0.5))
                mark.line(to: NSPoint(x: box.maxX, y: box.maxY - 0.5))
            } else {
                let cross = box.insetBy(dx: 1, dy: 1)
                mark.move(to: NSPoint(x: cross.minX, y: cross.minY)); mark.line(to: NSPoint(x: cross.maxX, y: cross.maxY))
                mark.move(to: NSPoint(x: cross.maxX, y: cross.minY)); mark.line(to: NSPoint(x: cross.minX, y: cross.maxY))
            }
            (success ? SettingsStyle.ok : SettingsStyle.danger).setStroke()
            mark.lineWidth = 1.6
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.stroke()
        }
    }
}
