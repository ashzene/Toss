import AppKit
import CoreImage

@MainActor
final class IPhoneShortcutPairingPanel: NSObject, NSWindowDelegate, NSSharingServiceDelegate {
    private static let phoneShortcutFilename = "Toss Tap.shortcut"
    private var panel: NSPanel?
    private var onPair: (() -> Void)?
    private var configuration: String?
    private var stagedDirectory: URL?
    private var sharedConfigurationDirectory: URL?
    private var sharingService: NSSharingService?

    func showMismatch(onPair: @escaping () -> Void) {
        guard panel == nil else { return }
        self.onPair = onPair
        present([
            label(L("Pair the iPhone shortcut again", "重新配对 iPhone 快捷指令"), heading: true),
            label(L("A shortcut reached this Mac with a different pairing code. If you just tried Toss on your iPhone, pair it again here.",
                    "这台 Mac 收到了一份配对码不匹配的快捷指令请求。如果你刚在 iPhone 上用了 Toss，可以在这里重新配对。")),
            button(L("Pair iPhone…", "配对 iPhone…"), #selector(beginPairing))
        ], userInitiated: false)
    }

    @objc private func beginPairing() { onPair?() }

    func showPairing(address: String, secret: String) {
        onPair = nil
        configuration = address + "|" + secret
        present([
            label(L("Pair Toss Tap on your iPhone", "在 iPhone 上配对 Toss Tap"), heading: true),
            label(L("Copy the configuration for your iPhone. Without Universal Clipboard, AirDrop the pairing text to your own iPhone, open it in Files and copy the entire line.",
                    "先点「复制配对配置」。如果没有通用剪贴板，点「隔空投送配对文本」，发给自己的 iPhone，在「文件」里打开并复制整行。")),
            NSStackView(views: [button(L("Copy pairing configuration", "复制配对配置"), #selector(copyConfiguration(_:))),
                                button(L("AirDrop pairing text…", "隔空投送配对文本…"), #selector(sendConfiguration))]),
            label(L("Send the Toss Tap shortcut to your iPhone. Paste the configuration when Shortcuts asks, then add the shortcut. Choose Replace if Toss Tap is already installed.",
                    "将 Toss Tap 捷径发到 iPhone。在「设定此捷径」里粘贴配置，再添加捷径。已有同名 Toss Tap 时选「替换」。")),
            NSStackView(views: [button(L("Send via AirDrop…", "隔空投送…"), #selector(sendTemplate)),
                                button(L("Show file in Finder", "在访达中显示文件"), #selector(revealTemplate))]),
            label(L("Verify Toss Tap with the iPhone Camera. Scan this code, open the shortcut and choose Always Allow if asked to connect to this Mac. Then select Toss Tap in Settings → Accessibility → Touch → Back Tap → Double Tap.",
                    "用 iPhone「相机」扫下方的码，打开 Toss Tap 验证连接。如果询问是否允许连接这台 Mac，选「始终允许」。然后在「设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下」选 Toss Tap。")),
            qrCode("shortcuts://run-shortcut?name=Toss%20Tap&input=text&text=%2Fauthorize"),
            label(L("Waiting for iPhone. This window closes when Toss verifies the phone’s request.",
                    "正在等待 iPhone。Toss 验证手机的请求后，这个窗口会自动关闭。"))
        ], userInitiated: true)
    }

    @objc private func copyConfiguration(_ sender: NSButton) {
        guard let configuration else { return }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        if clipboard.setString(configuration, forType: .string) {
            sender.title = L("Configuration copied", "已复制配置")
        }
    }

    @objc private func sendConfiguration() {
        guard sharingService == nil, let configuration else { return }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("Toss Pairing.txt")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            sharedConfigurationDirectory = directory
            guard manager.createFile(atPath: file.path, contents: Data(configuration.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            finishSharing()
            reportAirDropFailure()
            return
        }
        share(file)
    }

    @objc private func revealTemplate() {
        guard let file = stagedFile() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private func stagedFile() -> URL? {
        if let stagedDirectory { return stagedDirectory.appendingPathComponent(Self.phoneShortcutFilename) }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent(Self.phoneShortcutFilename)
        do {
            guard let template = Bundle.main.url(forResource: "Toss iPhone Phone Setup", withExtension: "shortcut") else {
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
        guard sharingService == nil, let file = stagedFile() else { return }
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
                    L("Use Copy pairing configuration for the text, or Show file in Finder for the shortcut.",
                      "要复制配对文本，请点「复制配对配置」。要找到捷径文件，请点「在访达中显示文件」。"))
    }

    private func reportError(_ title: String, _ message: String) {
        guard let panel, panel.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: panel)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finishSharing() }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finishSharing()
        if (error as NSError).code != NSUserCancelledError { reportAirDropFailure() }
    }

    private func finishSharing() {
        sharingService?.delegate = nil
        sharingService = nil
        if let sharedConfigurationDirectory { try? FileManager.default.removeItem(at: sharedConfigurationDirectory) }
        sharedConfigurationDirectory = nil
    }

    func removeStagedFile() {
        finishSharing()
        if let stagedDirectory { try? FileManager.default.removeItem(at: stagedDirectory) }
        stagedDirectory = nil
    }

    func dismiss() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        onPair = nil
        configuration = nil
        panel?.contentView = nil
        panel = nil
    }

    private func present(_ views: [NSView], userInitiated: Bool) {
        let window = panel ?? NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let firstPresentation = panel == nil
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.title = L("iPhone Shortcut", "iPhone 快捷指令")
        window.delegate = self
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        if firstPresentation { window.center() }
        panel = window
        if userInitiated {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    private func label(_ text: String, heading: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = heading ? .boldSystemFont(ofSize: 18) : .systemFont(ofSize: 13)
        field.preferredMaxLayoutWidth = 360
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
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
