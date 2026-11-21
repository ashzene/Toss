import AppKit
import CoreImage

@MainActor
final class IPhoneShortcutPairingPanel: NSObject, NSWindowDelegate, NSSharingServiceDelegate {
    static var bundledFile: URL? { Bundle.main.url(forResource: "Toss iPhone Phone Setup", withExtension: "shortcut") }
    private var panel: NSPanel?
    private weak var embeddedWindow: NSWindow?
    private var prepareEmbeddedPairing: (() -> Bool)?
    private var showEmbeddedContent: ((NSView?) -> Void)?
    private weak var embeddedContent: NSStackView?
    private var onPair: (() -> Void)?
    private var enrollment: IPhoneShortcutEnrollment?
    var shortcutName: String? { enrollment?.shortcutName }
    private weak var deliveryStatus: NSTextField?
    private var stagedDirectory: URL?
    private var sharingService: NSSharingService?

    func showMismatch(onPair: @escaping () -> Void) {
        guard panel == nil, showEmbeddedContent == nil else { return }
        self.onPair = onPair
        present([
            label(L("Pair the iPhone shortcut again", "重新配对 iPhone 快捷指令"), heading: true),
            label(L("A shortcut reached this Mac with a different pairing code. If you just tried Toss on your iPhone, pair it again here.",
                    "这台 Mac 收到了一份配对码不匹配的快捷指令请求。如果你刚在 iPhone 上用了 Toss，可以在这里重新配对。")),
            button(L("Pair iPhone…", "配对 iPhone…"), #selector(beginPairing))
        ], userInitiated: false)
    }

    @objc private func beginPairing() { onPair?() }

    func showPairing(address: String, secret: String, parent: NSWindow? = nil) {
        if let panel, let enrollment, enrollment.address == address, enrollment.secret == secret, panel.parent === parent {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard sharingService == nil else { return }
        if showEmbeddedContent != nil { dismiss() }
        let enrollment = startEnrollment(address: address, secret: secret)
        showPairingCode(enrollment, parent: parent)
    }

    func embedPairing(address: String, secret: String, in window: NSWindow,
                      prepare: @escaping () -> Bool,
                      showContent: @escaping (NSView?) -> Void) {
        if embeddedWindow === window, enrollment?.address == address, enrollment?.secret == secret { return }
        dismiss()
        embeddedWindow = window
        prepareEmbeddedPairing = prepare
        showEmbeddedContent = showContent
        let enrollment = startEnrollment(address: address, secret: secret)
        showPairingCode(enrollment, parent: nil)
    }

    private func startEnrollment(address: String, secret: String) -> IPhoneShortcutEnrollment {
        clearEnrollment()
        let enrollment = IPhoneShortcutEnrollment(address: address, secret: secret)
        self.enrollment = enrollment
        return enrollment
    }

    private func showPairingCode(_ enrollment: IPhoneShortcutEnrollment, parent: NSWindow?) {
        let status = label("")
        status.isHidden = true
        deliveryStatus = status
        let add = label(L("1. Add the shortcut", "1. 添加捷径"))
        add.font = SettingsStyle.sans(14, .semibold)
        let scan = label(L("2. Scan to pair", "2. 扫码配对"))
        scan.font = SettingsStyle.sans(14, .semibold)
        let name = NSTextField(labelWithString: enrollment.shortcutName)
        name.font = SettingsStyle.sans(13)
        name.textColor = SettingsStyle.muted
        let delivery = NSStackView(views: [button(L("Send via AirDrop…", "隔空投送…"), #selector(sendTemplate)), name])
        delivery.alignment = .centerY
        delivery.spacing = 8
        let permission = label(L("If asked to connect, choose Always Allow on iPhone or Allow on Mac.",
                                 "如有连接提示，iPhone 点「始终允许」，Mac 点「允许」。"),
                               width: showEmbeddedContent == nil ? 360 : SettingsStyle.width - 2 * SettingsStyle.margin)
        permission.textColor = SettingsStyle.muted
        var views: [NSView] = []
        if showEmbeddedContent == nil {
            views.append(label(L("Pair Toss Tap on your iPhone", "在 iPhone 上配对 Toss Tap"), heading: true))
        }
        views += [
            add,
            label(L("Accept it on your iPhone and tap Add Shortcut.", "在 iPhone 上接收，点「添加快捷指令」。")),
            delivery,
            scan,
            label(L("Use your iPhone Camera to scan on the same Wi-Fi.", "两台设备连同一个 Wi-Fi，用 iPhone 相机扫码。")),
            enrollment.link.map { qrCode($0) } ?? qrFailure(),
            permission,
            status
        ]
        present(views, userInitiated: true, parent: parent)
    }

    func showVerified() {
        guard panel != nil else { return }
        guard let enrollment else {
            if onPair != nil { dismiss() }
            return
        }
        self.enrollment = nil
        present([
            label(L("iPhone connection verified", "已验证 iPhone 连接"), heading: true),
            label(L("Select the shortcut below, then go back to apply.", "选中下方的捷径，然后点返回生效。")),
            label(enrollment.shortcutName, heading: true),
            label(L("If Settings doesn't open", "如果 iPhone 没有自动跳转") + "\n" +
                  L("On iPhone, go to Settings → Accessibility → Touch → Back Tap → Double Tap.",
                    "在 iPhone 打开「设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下」。")),
            button(L("Done", "完成"), #selector(finishSetup))
        ], userInitiated: false)
    }

    @objc private func finishSetup() { dismiss() }

    private func stagedFile() -> URL? {
        guard let enrollment else { return nil }
        if let stagedDirectory { return stagedDirectory.appendingPathComponent(enrollment.filename) }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent(enrollment.filename)
        do {
            guard let template = Self.bundledFile else {
                throw CocoaError(.fileNoSuchFile)
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            stagedDirectory = directory
            try manager.copyItem(at: template, to: file)
            return file
        } catch {
            removeStagedFile()
            reportError(L("Could not prepare Toss Tap", "无法准备 Toss Tap 捷径"),
                        L("Reinstall Toss and open iPhone Shortcut again.", "请重新安装 Toss，再打开「iPhone 快捷指令」。"))
            return nil
        }
    }

    @objc private func sendTemplate() {
        guard sharingService == nil, prepareEmbeddedPairing?() != false, let file = stagedFile() else { return }
        share(file)
    }

    private func share(_ file: URL) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [file]) else {
            finishSharing()
            reportAirDropFailure()
            return
        }
        sharingService = service
        service.delegate = self
        service.perform(withItems: [file])
    }

    private func reportAirDropFailure() {
        reportError(L("AirDrop is unavailable", "隔空投送暂不可用"),
                    L("Unlock your iPhone and try AirDrop again.", "解锁 iPhone 后再试隔空投送。"))
    }

    private func reportError(_ title: String, _ message: String) {
        if showEmbeddedContent != nil {
            updateDeliveryStatus(title + "\n" + message, color: SettingsStyle.danger)
            return
        }
        guard let panel, panel.attachedSheet == nil else { return }
        let sheet = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let done = button(L("Done", "完成"), #selector(dismissError(_:)), kind: .filled)
        done.keyEquivalent = "\r"
        let stack = content([label(title, heading: true), label(message), done])
        sheet.contentView = stack
        sheet.setContentSize(stack.fittingSize)
        SettingsStyle.applyUnifiedWindowStyle(in: sheet)
        panel.beginSheet(sheet)
    }

    @objc private func dismissError(_ sender: NSButton) {
        guard let sheet = sender.window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard self.sharingService === sharingService else { return }
        finishSharing()
        updateDeliveryStatus(L("AirDrop sent.", "隔空投送已发出。"))
    }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        guard self.sharingService === sharingService else { return }
        finishSharing()
        if (error as NSError).code != NSUserCancelledError { reportAirDropFailure() }
    }

    private func updateDeliveryStatus(_ text: String, color: NSColor = SettingsStyle.ink) {
        guard let status = deliveryStatus else { return }
        status.stringValue = text
        status.textColor = color
        status.isHidden = false
        if let embeddedContent { showEmbeddedContent?(embeddedContent) }
        else if let stack = panel?.contentView as? NSStackView { panel?.setContentSize(stack.fittingSize) }
    }

    private func finishSharing() {
        sharingService?.delegate = nil
        sharingService = nil
    }

    func removeStagedFile() {
        finishSharing()
        if let stagedDirectory { try? FileManager.default.removeItem(at: stagedDirectory) }
        stagedDirectory = nil
    }

    func dismiss() {
        if let showEmbeddedContent {
            self.showEmbeddedContent = nil
            prepareEmbeddedPairing = nil
            embeddedWindow = nil
            embeddedContent = nil
            clearEnrollment()
            showEmbeddedContent(nil)
        }
        panel?.close()
    }

    func dismiss(from parent: NSWindow) {
        if embeddedWindow === parent || panel?.parent === parent { dismiss() }
    }

    func windowWillClose(_ notification: Notification) {
        if let panel { panel.parent?.removeChildWindow(panel) }
        clearEnrollment()
        panel?.contentView = nil
        panel = nil
    }

    private func clearEnrollment() {
        onPair = nil
        enrollment = nil
        deliveryStatus = nil
        removeStagedFile()
    }

    private func present(_ views: [NSView], userInitiated: Bool, parent: NSWindow? = nil) {
        if let showEmbeddedContent {
            let stack = content(views, embedded: true)
            embeddedContent = stack
            showEmbeddedContent(stack)
            return
        }
        let window = panel ?? NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let firstPresentation = panel == nil
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.title = L("iPhone Shortcut", "iPhone 快捷指令")
        window.delegate = self
        let stack = content(views)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        SettingsStyle.applyUnifiedWindowStyle(in: window)
        if window.parent !== parent {
            window.parent?.removeChildWindow(window)
            if let parent {
                window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                              y: parent.frame.midY - window.frame.height / 2))
                parent.addChildWindow(window, ordered: .above)
            } else {
                window.center()
            }
        } else if firstPresentation { window.center() }
        panel = window
        if userInitiated {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    private func content(_ views: [NSView], embedded: Bool = false) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = embedded ? 8 : 12
        if !embedded { stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24) }
        return stack
    }

    private func label(_ text: String, heading: Bool = false, width: CGFloat = 360) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = heading ? SettingsStyle.serif(20) : SettingsStyle.sans(13)
        field.textColor = SettingsStyle.ink
        field.preferredMaxLayoutWidth = width
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func button(_ title: String, _ action: Selector, kind: SettingsPill.Kind = .ghost) -> NSButton {
        SettingsPill(title, kind: kind, monochrome: true, target: self, action: action)
    }

    private func qrCode(_ payload: String) -> NSView {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return qrFailure() }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return qrFailure() }
        let bounds = code.extent.insetBy(dx: -4, dy: -4)
        let padded = code.composited(over: CIImage(color: .white).cropped(to: bounds))
        let scale = max(1, floor(190 / bounds.width))
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return qrFailure() }
        let imageView = NSImageView()
        imageView.image = NSImage(cgImage: image, size: scaled.extent.size)
        imageView.setAccessibilityLabel(L("QR code for iPhone", "iPhone 扫描的二维码"))
        return imageView
    }

    private func qrFailure() -> NSView {
        label(L("Could not display the QR code. Close this window and try again.", "无法显示二维码，请关闭窗口后重试。"))
    }
}
