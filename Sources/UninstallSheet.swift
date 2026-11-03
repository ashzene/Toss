import AppKit

enum UninstallCopy {
    static var link: String { L("Uninstall Toss…", "卸载 Toss…") }
    static var title: String { L("Uninstall Toss?", "卸载 Toss？") }
    static var body: String { L("Pairing and settings will be removed. Nothing to do on your iPad.", "配对和设置都会删掉，iPad 上不用动。") }
}

// Ordinary Toss paper, typography and pills; no system destructive alert style.
@MainActor
final class UninstallSheet: NSWindowController {
    var onDecision: ((Bool) -> Void)?
    private var decided = false
    let titleLabel = NSTextField(labelWithString: UninstallCopy.title)
    let bodyLabel = NSTextField(wrappingLabelWithString: UninstallCopy.body)
    private(set) var cancelButton: SettingsPill!
    private(set) var uninstallButton: SettingsPill!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 218),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = UninstallCopy.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = SettingsStyle.background
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.isOpaque = true
        let content = window.contentView!
        // A sheet otherwise draws the system sheet material (a lighter, warmer grey in dark mode)
        // that does not match the window. Paint the Settings window's own background instead.
        let paper = UninstallSheetBackground()
        paper.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(paper)
        NSLayoutConstraint.activate([paper.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                                     paper.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     paper.topAnchor.constraint(equalTo: content.topAnchor),
                                     paper.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        titleLabel.font = SettingsStyle.serif(26)
        titleLabel.textColor = SettingsStyle.ink
        bodyLabel.font = SettingsStyle.sans(14.5)
        bodyLabel.textColor = SettingsStyle.muted
        bodyLabel.preferredMaxLayoutWidth = 388
        bodyLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        cancelButton = SettingsPill(L("Cancel", "取消"), compact: false, target: self, action: #selector(cancel))
        uninstallButton = SettingsPill(L("Uninstall", "卸载"), kind: .filled, compact: false,
                                       target: self, action: #selector(confirm))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, uninstallButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        for view in [titleLabel, bodyLabel, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -36),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: bodyLabel.bottomAnchor, constant: 26),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28)
        ])
    }
    required init?(coder: NSCoder) { nil }

    @objc private func cancel() { decide(false) }
    @objc private func confirm() { decide(true) }
    private func decide(_ confirmed: Bool) {
        guard !decided else { return }
        decided = true
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        window?.orderOut(nil)
        onDecision?(confirmed)
    }
}

// The same background token as the Settings window, redrawn when light/dark changes.
final class UninstallSheetBackground: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.layer?.backgroundColor = SettingsStyle.background.cgColor }
    }
}
