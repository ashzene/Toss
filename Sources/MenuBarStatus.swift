import AppKit
import QuartzCore

// The option stroke and a solid up arrow, with no keycap or frame, centred in
// the 22 pt view. While uploading only the arrow moves (up 1.5 pt, down 1 pt)
// and takes the target's colour: Codex blue or Claude orange. Idle is template.
@MainActor
final class TossMenuIcon: NSView {
    static let size: CGFloat = 22
    static let arrowTravel: CGFloat = 1.5
    static let arrowDip: CGFloat = 1.0
    static let period: Double = 0.9
    static let lineWidth: CGFloat = 1.6
    static let codexBlue = NSColor(srgbRed: 0x02 / 255.0, green: 0x85 / 255.0, blue: 0xFF / 255.0, alpha: 1)
    static let claudeOrange = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
    private let optionShape = CAShapeLayer()
    private let arrowShape = CAShapeLayer()
    private var active = false
    private var stillReceiving: DispatchWorkItem?
    static let stillReceivingAfter: Double = 0.8
    static let receivingOpacity: Float = 0.45
    static let nudgeHop: CGFloat = 3
    private var tint: NSColor?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static let optionPath: CGPath = {
        let path = CGMutablePath()
        path.addLines(between: [.init(x: 2.2, y: 5.7), .init(x: 7.6, y: 5.7),
                                .init(x: 14.4, y: 16.7), .init(x: 19.8, y: 16.7)])
        return path
    }()
    static let arrowPath: CGPath = {
        let path = CGMutablePath()
        path.addLines(between: [.init(x: 16.05, y: 3.85), .init(x: 20.2, y: 8.35),
                                .init(x: 17.75, y: 8.35), .init(x: 17.75, y: 10.8),
                                .init(x: 14.35, y: 10.8), .init(x: 14.35, y: 8.35),
                                .init(x: 11.9, y: 8.35)])
        path.closeSubpath()
        return path
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        optionShape.path = Self.optionPath
        optionShape.fillColor = nil
        optionShape.lineWidth = Self.lineWidth
        optionShape.lineCap = .round
        optionShape.lineJoin = .round
        arrowShape.path = Self.arrowPath
        for shape in [optionShape, arrowShape] { layer?.addSublayer(shape) }
        setAccessibilityElement(false)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [optionShape, arrowShape] {
            shape.frame = bounds
            shape.contentsScale = window?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    func setUploading(_ uploading: Bool, tint: NSColor? = nil) {
        let newTint = uploading ? tint : nil
        if newTint != self.tint {
            self.tint = newTint
            updateColors()
        }
        guard active != uploading else { return }
        active = uploading
        arrowShape.removeAnimation(forKey: "upload")
        arrowShape.removeAnimation(forKey: "receiving")
        stillReceiving?.cancel(); stillReceiving = nil
        if uploading {
            // Still receiving after ~0.8 s (2026-10-25): the arrow also breathes, quietly. No
            // popup, sound or colour; it only tells a slow transfer from a missed keypress.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.active else { return }
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 1; breathe.toValue = Self.receivingOpacity
                breathe.duration = Self.period / 2
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                self.arrowShape.add(breathe, forKey: "receiving")
            }
            stillReceiving = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stillReceivingAfter, execute: work)
        }
        if uploading {
            let movement = CAKeyframeAnimation(keyPath: "transform.translation.y")
            movement.values = [0, -Self.arrowTravel, 0, Self.arrowDip, 0]
            movement.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            movement.duration = Self.period
            movement.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
            movement.repeatCount = .infinity
            arrowShape.add(movement, forKey: "upload")
        }
    }
    // A repeated keypress while a request runs: one short extra hop of the arrow, so the
    // press is visibly received (never queued). Additive, on top of the upload bounce.
    func nudge() {
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, -Self.nudgeHop, 0]
        hop.keyTimes = [0, 0.4, 1]
        hop.duration = 0.22
        hop.isAdditive = true
        hop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        arrowShape.add(hop, forKey: "nudge")
    }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            optionShape.strokeColor = NSColor.labelColor.cgColor
            arrowShape.fillColor = (tint ?? NSColor.labelColor).cgColor
            CATransaction.commit()
        }
    }
}

enum TossUploadTarget {
    case codex, claude
    @MainActor var color: NSColor {
        switch self {
        case .codex: return TossMenuIcon.codexBlue
        case .claude: return TossMenuIcon.claudeOrange
        }
    }
}

struct TossStatusPresentation {
    var connection = TossConnectionStatus.notChecked
    var phase = TossTransferPhase.idle
    var paired = false
    var enabled = false
    var canRecheck = true
    var lastMessage = ""
    var retryError: String?
    var uploadTarget: TossUploadTarget?
    // The same one-line status the Settings window shows.
    var summary = ""
    var summaryTone: NSColor?
    var lastCaptureResult: TossCaptureResult?
    var captureInProgress = false
}

// Paints the popover (arrow included) in the website colour instead of the
// translucent material, so the desktop never shows through.
@MainActor
private final class TossStatusBackground: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsStyle.background.cgColor
        }
    }
}

@MainActor
private final class TossStatusRoot: NSView {
    private var backdrop: NSView?
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsStyle.background.cgColor
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !(window is TossStatusWindow), let frame = window.contentView?.superview,
              backdrop?.superview !== frame else { return }
        backdrop?.removeFromSuperview()
        let view = TossStatusBackground(frame: frame.bounds)
        view.autoresizingMask = [.width, .height]
        frame.addSubview(view, positioned: .below, relativeTo: window.contentView)
        backdrop = view
    }
}

// Same look as the Settings window: serif name, one status line, a grey note,
// the last screenshot, and pill buttons. Colour appears only in status dots.
@MainActor
final class TossStatusPanel: NSViewController {
    static var width: CGFloat {
        _ = SettingsStyle.fontsRegistered
        let titles = [L("Check connection", "检查连接"), L("Settings", "设置"),
                      L("Export Logs", "导出日志"), L("Diagnostics", "诊断信息")]
        let controls = titles.enumerated().map { index, title in
            SettingsPill(title, kind: index < 2 ? .ghost : .quiet, target: nil, action: nil).intrinsicContentSize.width
        }
        let controlsWidth: CGFloat = controls.reduce(0, +)
        // 20 pt margins on both sides and four 8 pt gaps; the spacer may shrink to zero.
        // The smallest of the usual steps that fits, so English grows only as much as it must.
        let needed = controlsWidth + 2 * 20 + 4 * 8
        return [340, 360, 380, 400, 420].first { $0 >= needed } ?? ceil(needed)
    }
    var onClose: (() -> Void)?
    var onRecheck: (() -> Void)?
    var onSettings: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    var onExportLogs: (() -> Void)?
    var exportingLogs = false { didSet { exportLogs.isEnabled = !exportingLogs } }
    private let stack = NSStackView()
    private let summary = SettingsStatus(size: 13.5, emphasizesLead: true)
    private let note = SettingsDetail(wrappingLabelWithString: "")
    private let job = SettingsStatus(size: 13)
    private let captureCaption = NSTextField(labelWithString: "")
    private let receiptDetails = NSStackView()
    private let receiptSummary = SettingsDetail(wrappingLabelWithString: "")
    private let receiptNote = SettingsDetail(wrappingLabelWithString: "")
    private let activity = SettingsActivityBar()
    private let recheck = SettingsPill(L("Check connection", "检查连接"), target: nil, action: nil)
    private let settings = SettingsPill(L("Settings", "设置"), target: nil, action: nil)
    private let exportLogs = SettingsPill(L("Export Logs", "导出日志"), kind: .quiet, target: nil, action: nil)

    override func loadView() {
        _ = SettingsStyle.fontsRegistered
        let root = TossStatusRoot(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        view = root
        let inner = Self.width - 40
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18)
        ])
        func hairline() -> NSView {
            let line = NSBox()
            line.boxType = .custom
            line.titlePosition = .noTitle
            line.borderWidth = 0
            line.fillColor = SettingsStyle.line
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            line.widthAnchor.constraint(equalToConstant: inner).isActive = true
            return line
        }
        func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            return view
        }
        func place(_ child: NSView, gap: CGFloat) {
            stack.addArrangedSubview(child)
            stack.setCustomSpacing(gap, after: child)
        }

        let name = NSTextField(labelWithString: "Toss")
        name.font = SettingsStyle.serif(22)
        name.textColor = SettingsStyle.ink
        place(name, gap: 8)
        place(summary, gap: 8)
        note.font = SettingsStyle.sans(12.5)
        note.textColor = SettingsStyle.muted
        note.preferredMaxLayoutWidth = inner
        note.setContentCompressionResistancePriority(.required, for: .vertical)
        place(note, gap: 16)

        captureCaption.font = SettingsStyle.sans(13.5)
        captureCaption.textColor = SettingsStyle.ink
        let row = NSStackView(views: [captureCaption, spacer(), job, activity])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        row.widthAnchor.constraint(equalToConstant: inner).isActive = true
        place(hairline(), gap: 0)
        place(row, gap: 0)
        receiptDetails.orientation = .vertical
        receiptDetails.alignment = .leading
        receiptDetails.spacing = 5
        receiptDetails.widthAnchor.constraint(equalToConstant: inner).isActive = true
        for field in [receiptSummary, receiptNote] {
            field.font = SettingsStyle.sans(12.5)
            field.textColor = field === receiptSummary ? SettingsStyle.ink : SettingsStyle.muted
            field.preferredMaxLayoutWidth = inner
            field.widthAnchor.constraint(equalToConstant: inner).isActive = true
            field.setContentCompressionResistancePriority(.required, for: .vertical)
            receiptDetails.addArrangedSubview(field)
        }
        receiptDetails.isHidden = true
        place(receiptDetails, gap: 14)
        place(hairline(), gap: 14)

        recheck.target = self
        recheck.action = #selector(recheckClicked)
        settings.target = self
        settings.action = #selector(settingsClicked)
        exportLogs.target = self
        exportLogs.action = #selector(exportLogsClicked)
        let diagnostics = SettingsPill(L("Diagnostics", "诊断信息"), kind: .quiet, target: self, action: #selector(diagnosticsClicked))
        let buttons = NSStackView(views: [recheck, settings, spacer(), exportLogs, diagnostics])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: inner).isActive = true
        place(buttons, gap: 0)
    }
    func update(_ value: TossStatusPresentation) {
        loadViewIfNeeded()
        let connection = value.connection
        let route = connection.state == .ready ? connection.transportLabel.map { " · " + $0 } ?? "" : ""
        summary.show(value.summary.isEmpty ? nil : value.summary + route, dot: value.summaryTone)
        var detail = connection.state == .connecting ? value.retryError : connection.errorMessage
        if !value.paired { detail = L("Pair your iPad in Settings to start.", "先在设置里配对 iPad。") }
        let inProgress = value.captureInProgress || value.phase == .preparing || value.phase.animates
        captureCaption.stringValue = inProgress ? L("Current screenshot", "当前截图") : L("Last screenshot", "上一张截图")
        let receipt = inProgress ? nil : value.lastCaptureResult
        receiptDetails.isHidden = receipt == nil
        receiptSummary.stringValue = receipt?.summary ?? ""
        receiptNote.stringValue = receipt?.detail ?? ""
        receiptSummary.setAccessibilityIdentifier("Toss.lastCapture.summary")
        receiptNote.setAccessibilityIdentifier("Toss.lastCapture.detail")
        if let receipt {
            let tone: NSColor? = receipt.outcome == .confirmed ? SettingsStyle.ok :
                receipt.outcome == .cancelled ? nil : SettingsStyle.accent
            job.show(receipt.status, dot: tone)
        } else {
            switch value.phase {
            case .idle:
                job.show(value.enabled ? L("Waiting for a shortcut", "等你按快捷键") : L("Off", "已关闭"))
            case .preparing:
                job.show(L("Preparing…", "准备中…"))
            case .uploading:
                job.show(L("Uploading", "正在上传"))
            case .slow:
                job.show(L("Taking longer…", "比平时慢…"))
                if detail == nil { detail = L("Still waiting for your iPad. Your shortcut was received.", "还在等 iPad。快捷键已经收到了。") }
            case .completed:
                job.show(L("Added to chat", "已放进聊天"), dot: SettingsStyle.ok)
            case .failed:
                job.show(L("Not completed", "没完成"), dot: SettingsStyle.accent)
                if detail == nil, !value.lastMessage.isEmpty { detail = value.lastMessage }
            case .cancelled:
                job.show(L("Cancelled", "已取消"))
            }
        }
        note.stringValue = detail ?? ""
        stack.setCustomSpacing(detail == nil ? 16 : 8, after: summary)
        activity.animating = value.phase.animates
        let unreachable = connection.state == .failed || connection.state == .disconnected
        recheck.isHidden = !value.paired
        recheck.kind = unreachable ? .filled : .ghost
        recheck.isEnabled = value.canRecheck
        settings.kind = value.paired ? .ghost : .filled
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: stack.fittingSize.height + 18 + 16)
    }
    @objc private func recheckClicked() { onRecheck?() }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func diagnosticsClicked() { onDiagnostics?() }
    @objc private func exportLogsClicked() { onExportLogs?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }
}

@MainActor
private final class TossStatusWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class TossStatusController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let legacyMenu: NSMenu
    private let openSetupIfNeeded: () -> Bool
    private let icon = TossMenuIcon(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    private let panel = TossStatusPanel()
    private let popover = NSPopover()
    private var fallbackWindow: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var value = TossStatusPresentation()
    private var isShown: Bool { popover.isShown || fallbackWindow?.isVisible == true }

    init(item: NSStatusItem, menu: NSMenu, recheck: @escaping () -> Void,
         settings: @escaping () -> Void, diagnostics: @escaping () -> Void, exportLogs: @escaping () -> Void,
         openSetupIfNeeded: @escaping () -> Bool = { false }) {
        self.item = item
        self.legacyMenu = menu
        self.openSetupIfNeeded = openSetupIfNeeded
        super.init()
        item.length = NSStatusItem.squareLength
        item.autosaveName = "TossStatus"
        guard let button = item.button else { return }
        button.title = ""
        button.image = nil
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        icon.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        button.setAccessibilityLabel(L("Toss Status", "Toss 状态"))
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = panel
        popover.delegate = self
        panel.onClose = { [weak self] in self?.closePanel() }
        panel.onRecheck = recheck
        panel.onSettings = { [weak self] in self?.closePanel(); settings() }
        panel.onDiagnostics = { [weak self] in self?.closePanel(); diagnostics() }
        panel.onExportLogs = exportLogs
    }
    func setExportingLogs(_ exporting: Bool) { panel.exportingLogs = exporting }
    func nudge() { icon.nudge() }
    // Can the icon be seen: off-screen or not drawn means hidden (macOS 26 Menu Bar setting off);
    // a frame under the camera notch means hidden by the notch.
    func iconVisibility() -> MenuIconVisibility {
        guard item.isVisible, let window = item.button?.window else { return .hidden }
        let frame = window.frame
        let screens = NSScreen.screens
        let onScreen = window.occlusionState.contains(.visible) && screens.contains { $0.frame.intersects(frame) }
        let notches: [CGRect] = screens.compactMap { screen in
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
            return CGRect(x: left.maxX, y: min(left.minY, right.minY), width: right.minX - left.maxX,
                          height: max(left.height, right.height))
        }
        return MenuIconPolicy.classify(frame: frame, onScreen: onScreen, notches: notches)
    }
    func update(_ presentation: TossStatusPresentation) {
        value = presentation
        icon.setUploading(value.phase.animates, tint: value.uploadTarget?.color)
        let connection: String
        switch value.connection.state {
        case .ready: connection = L("iPad Connected", "iPad 已连接") + (value.connection.transportLabel.map { " · " + $0 } ?? "")
        case .connecting: connection = L("Connecting to iPad", "正在连接 iPad")
        case .failed, .disconnected: connection = L("iPad Not Connected", "iPad 没连上")
        case .notChecked: connection = value.paired ? L("Connection Not Checked", "还没检查连接") : L("iPad Not Paired", "iPad 还没配对")
        }
        let activity = value.phase == .slow ? L(" · Screenshot is taking longer; still waiting", " · 截图比平时慢，还在等") :
            (value.phase.animates ? L(" · Uploading screenshot", " · 正在上传截图") : "")
        let label = "Toss · " + connection + activity
        item.button?.toolTip = label
        item.button?.setAccessibilityLabel(label)
        if isShown { refreshPanel() }
    }
    private func refreshPanel() {
        panel.update(value)
        if fallbackWindow?.isVisible == true, let window = fallbackWindow {
            let top = window.frame.maxY
            window.setContentSize(panel.preferredContentSize)
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        } else {
            popover.contentSize = panel.preferredContentSize
        }
    }
    func showPanel() {
        if openSetupIfNeeded() { closePanel(); return }
        guard !isShown, let button = item.button, let anchorWindow = button.window else { return }
        refreshPanel()
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = anchorWindow.screen ?? NSScreen.main
        // A crowded menu bar can place the item's window behind the camera
        // housing. Never anchor a popover to that invisible position.
        let safeAreas = [screen?.auxiliaryTopLeftArea, screen?.auxiliaryTopRightArea].compactMap { $0 }
        let visibleAnchor = screen.map { $0.frame.contains(anchor) } == true &&
            (safeAreas.isEmpty || safeAreas.contains { $0.contains(anchor) })
        if visibleAnchor {
            popover.contentViewController = panel
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        } else {
            popover.contentViewController = nil
            let window = fallbackWindow ?? TossStatusWindow(contentRect: .zero, styleMask: [.borderless],
                                                               backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .popUpMenu
            window.hasShadow = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentViewController = panel
            window.setContentSize(panel.preferredContentSize)
            if let frame = screen?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: frame.maxX - window.frame.width - 12,
                                                    y: frame.maxY - 8))
            }
            fallbackWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        startDismissalMonitoring()
    }
    func closePanel() {
        stopDismissalMonitoring()
        popover.performClose(nil)
        fallbackWindow?.orderOut(nil)
        fallbackWindow?.contentViewController = nil
        popover.contentViewController = panel
    }
    func popoverDidClose(_ notification: Notification) { stopDismissalMonitoring() }
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

    private func startDismissalMonitoring() {
        stopDismissalMonitoring()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
                                                                   .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closePanel(); return nil }
            } else if event.window !== self.panel.view.window && event.window !== self.item.button?.window {
                self.closePanel()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
                                                                     .otherMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePanel() }
            })
        }
    }
    private func stopDismissalMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
    @objc private func clicked() {
        guard let button = item.button else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            closePanel()
            NSMenu.popUpContextMenu(legacyMenu, with: event, for: button)
        } else if openSetupIfNeeded() {
            closePanel()
        } else if isShown {
            closePanel()
        } else {
            showPanel()
        }
    }
}
