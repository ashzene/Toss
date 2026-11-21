import AppKit
import SwiftUI
import CoreText
import QuartzCore

// Toss look shared by the Settings window and the menu-bar popover: the
// website's palette and type. Every color resolves per appearance, so both
// follow the system's light/dark mode.
enum SettingsStyle {
    static func rgb(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    // Toss paper, the light surface of every Toss window, popover and toast (Ashley 2026-10-29:
    // 「白色界面全部换成之前那个黄黄的」, F0EEE6, the card tone of her reference (10-29)).
    static let paper = rgb(0xF0EEE6)
    // Raised light: keycaps and switch knobs on paper, and the ink of dark mode. The 10-23 off-white,
    // also the app icon's glyph (Assets/Toss.icon/icon.json); never pure white.
    static let raised = rgb(0xFAF9F5)
    static let background = dynamic(paper, rgb(0x0D0D0C))
    static let settingsBackground = dynamic(paper, rgb(0x060606))
    static let ink = dynamic(rgb(0x141413), raised)
    static let muted = dynamic(rgb(0x65645F), rgb(0xA3A19A))
    // Hairline one step darker than on the old paper, so it keeps the same contrast (1.2:1).
    static let line = dynamic(rgb(0xDCDAD2), rgb(0x2A2926))
    static let key = dynamic(raised, rgb(0x1E1E1C))
    static let keyEdge = dynamic(rgb(0x141413, alpha: 0.12), rgb(0xFFFFFF, alpha: 0.10))
    static let knobOff = dynamic(raised, rgb(0x8A8882))
    static let ok = dynamic(rgb(0x2E9E5B), rgb(0x3CC273))
    static let accent = dynamic(rgb(0xD9622B), rgb(0xF07A43))
    // Failure mark in the toast (Ashley 2026-10-24: the ✕ is red). Muted brick red, lighter in dark mode.
    static let danger = dynamic(rgb(0xC8372D), rgb(0xEF6A5E))
    static let width: CGFloat = 540
    static let margin: CGFloat = 36
    static let top: CGFloat = 44
    static let bottom: CGFloat = 28

    // Native glass belongs to the controls; the window uses a solid background.
    static func applyUnifiedWindowStyle(in window: NSWindow, backgroundColor: NSColor = background) {
        window.backgroundColor = backgroundColor
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }

    // Source Serif 4 and Hanken Grotesk (SIL OFL) ship in Resources/Fonts.
    // If they are missing the window falls back to New York and SF.
    static let fontsRegistered: Bool = {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return false }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        return true
    }()
    static func serif(_ size: CGFloat) -> NSFont {
        if let font = NSFont(name: "SourceSerif428pt-SemiBold", size: size) { return chinese(font, chineseSerif, .semibold) }
        let system = NSFont.systemFont(ofSize: size, weight: .semibold)
        return chinese(system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system, chineseSerif, .semibold)
    }
    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let name = weight.rawValue >= NSFont.Weight.semibold.rawValue ? "HankenGrotesk-SemiBold"
            : weight.rawValue >= NSFont.Weight.medium.rawValue ? "HankenGrotesk-Medium" : "HankenGrotesk-Regular"
        let size = size + textBoost
        return chinese(NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight), chineseSans, weight)
    }

    // One spacing scale for every window (Ashley 2026-10-30: 「感觉还是有点拥挤」, 「把按钮硬压下去了」).
    // A = before her note, B = roomier, C = airy; she picks one from 间距对比.
    enum Density: Int { case a, b, c }
    nonisolated(unsafe) static var density: Density = .a // Ashley 2026-10-30: 「a吧」
    private static func pick(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat) -> CGFloat { [a, b, c][density.rawValue] }
    static var noteGap: CGFloat { pick(4, 6, 9) }          // ink line → its grey note
    static var rowPad: CGFloat { pick(14, 17, 20) }        // above and below each list row
    static var statusRoom: CGFloat { pick(18, 26, 34) }    // list → status block, and status → divider
    static var footerGap: CGFloat { pick(16, 22, 28) }     // divider → buttons, the same in every state
    static var footerBottom: CGFloat { pick(28, 32, 36) }  // buttons → window edge
    // Settings window width and row padding, separate from the guide (Ashley 2026-10-30: 「这个太长了，能不能宽一点」).
    nonisolated(unsafe) static var settingsWidth: CGFloat = 620 // 「620试试看」
    nonisolated(unsafe) static var settingsRowPad: CGFloat?   // nil = the shared rowPad
    // Space above the title and between groups; trimmed from 44 / 28 when notes went back under titles.
    nonisolated(unsafe) static var settingsTop: CGFloat = 44
    nonisolated(unsafe) static var settingsSectionGap: CGFloat = 28
    nonisolated(unsafe) static var settingsInlineNotes = false // notes back under the title (「新开一行像以前那样放下面」)
    static let settingsBottom: CGFloat = 36 // Settings: pill row → window edge, same as the side margin (「最底下也感觉很拥挤」)
    static let settingsFooterGap: CGFloat = 30 // Settings: last divider → pill row
    static var guideHeight: CGFloat { pick(540, 590, 640) } // guide window, tall enough for its tallest state

    // The family Chinese characters fall back to inside the Latin fonts above; nil keeps the
    // system's choice (PingFang SC). Ashley 2026-10-30: 「中文有没有好看一点的字体」.
    // Chinese body text in Hiragino Sans GB (冬青黑体), on every Mac (Ashley 2026-10-30, option B).
    nonisolated(unsafe) static var chineseSans: String? = "Hiragino Sans GB"
    // Body text size step on top of each size above (Ashley 2026-10-30: 「看起来好小啊」); 0 = as designed.
    nonisolated(unsafe) static var textBoost: CGFloat = 0
    // Chinese headings in Songti SC Bold, next to Source Serif "Toss" (Ashley 2026-10-30: 「就这个就这个
    // 太美丽了」). Songti ships with every Mac, so nothing is bundled.
    nonisolated(unsafe) static var chineseSerif: String? = "STSongti-SC-Bold"
    private static func chinese(_ font: NSFont, _ family: String?, _ weight: NSFont.Weight) -> NSFont {
        guard let family else { return font }
        // A PostScript name ("STSongti-SC-Bold") picks one exact face; a family name picks by weight.
        // A family resolves to its face nearest the weight (AppKit weights 5 = regular, 9 = bold).
        let appKitWeight = weight.rawValue >= NSFont.Weight.semibold.rawValue ? 9 : weight.rawValue >= NSFont.Weight.medium.rawValue ? 6 : 5
        let name = family.contains("-") ? family
            : NSFontManager.shared.font(withFamily: family, traits: [], weight: appKitWeight, size: font.pointSize)?.fontName
        guard let name else { return font }
        let cjk = NSFontDescriptor(fontAttributes: [.name: name])
        return NSFont(descriptor: font.fontDescriptor.addingAttributes([.cascadeList: [cjk]]), size: font.pointSize) ?? font
    }
    // The menu keeps the full wording; the window's pill uses a short one.
    static func shortToggle(_ title: String) -> String {
        switch title {
        case "Enable Shortcuts", "打开快捷键": return L("Turn On", "打开")
        case "Disable Shortcuts", "Disable Auto-Resume", "关闭快捷键", "关闭自动恢复": return L("Turn Off", "关闭")
        case "Cancel Enabling", "取消打开": return L("Cancel", "取消")
        default: return title
        }
    }
}

// Pill button from the website: ghost (thin outline), filled (ink), or quiet (underlined text).
final class SettingsPill: NSButton {
    enum Kind { case ghost, filled, quiet }
    var kind: Kind = .ghost { didSet { needsDisplay = true; updateGlass() } }
    private var compact = false
    private var monochrome = false
    private var stylingTitle = false
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; updateGlassTitle() } }

    convenience init(_ title: String, kind: Kind = .ghost, compact: Bool = true, monochrome: Bool = false,
                     target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.compact = compact
        self.monochrome = monochrome
        self.kind = kind
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        if monochrome { focusRingType = .none }
        setButtonType(.momentaryPushIn)
        updateGlass()
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    // Native glass is layer-rendered; NSButton's default can remain false in a
    // subclass and would draw only the title, without its glass bezel.
    override var wantsUpdateLayer: Bool { usesNativeGlass }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    private var usesNativeGlass: Bool {
        if #available(macOS 26.0, *) { return !monochrome && kind != .quiet }
        return false
    }
    private func updateGlass() {
        guard #available(macOS 26.0, *) else { return }
        isBordered = usesNativeGlass
        wantsLayer = usesNativeGlass
        guard usesNativeGlass else { return }
        bezelStyle = .glass
        borderShape = .capsule
        controlSize = compact ? .small : .regular
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bezelColor = (kind == .filled ? SettingsStyle.ink : SettingsStyle.background).usingColorSpace(.sRGB)
        }
        tintProminence = kind == .filled ? .primary : .secondary
        font = textFont
        updateGlassTitle()
    }
    private func updateGlassTitle() {
        guard usesNativeGlass, !stylingTitle else { return }
        stylingTitle = true
        defer { stylingTitle = false }
        // Resolve colors here so AppKit's cached glass label also updates when
        // this window changes appearance without changing the system theme.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = kind == .filled ? SettingsStyle.background : SettingsStyle.ink
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: textFont, .foregroundColor: color.usingColorSpace(.sRGB) ?? color
            ])
        }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if monochrome && accepted { needsDisplay = true }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if monochrome && resigned { needsDisplay = true }
        return resigned
    }
    private var textFont: NSFont { kind == .quiet ? SettingsStyle.sans(13) : SettingsStyle.sans(compact ? 12.5 : 13, .medium) }
    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: textFont])
        if kind == .quiet { return NSSize(width: ceil(size.width) + 2, height: 26) }
        return NSSize(width: ceil(size.width) + (compact ? 26 : 32), height: compact ? 27 : 32)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        updateGlass()
    }
    override func draw(_ dirtyRect: NSRect) {
        if usesNativeGlass {
            super.draw(dirtyRect)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(!isEnabled ? 0.4 : (isHighlighted ? 0.6 : 1))
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        var color = SettingsStyle.ink
        switch kind {
        case .filled:
            SettingsStyle.ink.setFill()
            pill.fill()
            color = SettingsStyle.background
        case .ghost:
            SettingsStyle.line.setStroke()
            pill.lineWidth = 1
            pill.stroke()
        case .quiet:
            color = SettingsStyle.muted
        }
        drawTitle(in: bounds, color: color)
        if monochrome && window?.firstResponder === self {
            let focus = bounds.insetBy(dx: 2, dy: 2)
            (kind == .filled ? SettingsStyle.background : SettingsStyle.ink).setStroke()
            NSBezierPath(roundedRect: focus, xRadius: focus.height / 2, yRadius: focus.height / 2).stroke()
        }
    }
    fileprivate func drawTitle(in rect: NSRect, color: NSColor? = nil) {
        var attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        if kind == .quiet {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = SettingsStyle.line
        }
        let color = color ?? (kind == .filled ? SettingsStyle.background : kind == .quiet ? SettingsStyle.muted : SettingsStyle.ink)
        attributes[.foregroundColor] = color
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                 withAttributes: attributes)
    }
}

// The system Toggle owns the transparent lens and all input handling.
// Toss's original small ink switch covers it only while it is at rest.
@MainActor
private final class SettingsSwitchModel: ObservableObject {
    @Published var isOn = false
    @Published var pendingApproval = false
    @Published var isEnabled = true
    @Published var label = ""
    @Published var interacting = false
    private var interactionGeneration = 0
    func beginInteraction() {
        interactionGeneration += 1
        interacting = true
    }
    func endInteraction() {
        interactionGeneration += 1
        let generation = interactionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.interactionGeneration == generation else { return }
            self.interacting = false
        }
    }
    func cancelInteraction() {
        interactionGeneration += 1
        interacting = false
    }
    var onChange: ((Bool) -> Void)?

    func setFromUser(_ value: Bool) {
        guard isEnabled, value != isOn else { return }
        isOn = value
        onChange?(value)
    }
}

private struct RestingSettingsSwitch: NSViewRepresentable {
    var isOn: Bool
    var pendingApproval: Bool
    var isEnabled: Bool
    func makeNSView(context: Context) -> InkSwitchDrawing { InkSwitchDrawing() }
    func updateNSView(_ view: InkSwitchDrawing, context: Context) {
        view.isOn = isOn
        view.pendingApproval = pendingApproval
        view.enabled = isEnabled
        view.needsDisplay = true
    }
}
private final class InkSwitchDrawing: NSView {
    var isOn = false
    var pendingApproval = false
    var enabled = true
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        (window?.backgroundColor ?? SettingsStyle.background).setFill()
        bounds.fill()
        NSGraphicsContext.current?.cgContext.setAlpha(enabled ? 1 : 0.5)
        let track = NSRect(x: (bounds.width - 34) / 2, y: (bounds.height - 20) / 2, width: 34, height: 20)
        (isOn ? (pendingApproval ? SettingsStyle.muted : SettingsStyle.ink) : SettingsStyle.line).setFill()
        NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10).fill()
        (isOn ? SettingsStyle.background : SettingsStyle.knobOff).setFill()
        NSBezierPath(ovalIn: NSRect(x: track.minX + (isOn ? 16 : 2), y: track.minY + 2, width: 16, height: 16)).fill()
    }
}
private struct NativeSettingsSwitch: View {
    @ObservedObject var model: SettingsSwitchModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var nativeSize = CGSize(width: 54, height: 24)
    var body: some View {
        ZStack {
            Toggle(model.label, isOn: Binding(get: { model.isOn }, set: { model.setFromUser($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(colorScheme == .dark ? .white : .black)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { nativeSize = $0 }
                .scaleEffect(x: 34 / max(1, nativeSize.width), y: 20 / max(1, nativeSize.height))
                .frame(width: 34, height: 20)
            RestingSettingsSwitch(isOn: model.isOn, pendingApproval: model.pendingApproval, isEnabled: model.isEnabled)
                .frame(width: 58, height: 44)
                .opacity(model.interacting ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: 34, height: 20)
        .disabled(!model.isEnabled)
        .accessibilityLabel(model.label)
        .padding(12)
    }
}

// Bridge the native SwiftUI control to Toss's existing AppKit target/actions.
final class SettingsSwitch: NSControl {
    private let model = SettingsSwitchModel()
    private var hosting: NSHostingView<NativeSettingsSwitch>!
    private var inputMonitor: Any?
    private var releaseTimer: Timer?

    deinit {
        releaseTimer?.invalidate()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        releaseTimer?.invalidate()
        releaseTimer = nil
        model.cancelInteraction()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        guard window != nil else { return }
        // Observe presses inside this control. Event delivery and dragging remain
        // entirely with the system Toggle underneath the hit-transparent cover.
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown, self.isEnabled, !self.isHiddenOrHasHiddenAncestor,
               event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.beginNativeInteraction()
            } else if event.type == .leftMouseUp, self.model.interacting {
                self.finishNativeInteraction()
            }
            return event
        }
    }
    private func beginNativeInteraction() {
        model.beginInteraction()
        releaseTimer?.invalidate()
        // Native controls can consume mouseUp in their own tracking loop, bypassing
        // local event monitors. Observe release only for the duration of this press.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if NSEvent.pressedMouseButtons & 1 == 0 { self.finishNativeInteraction() }
            }
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    private func finishNativeInteraction() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        model.endInteraction()
    }
    var state: NSControl.StateValue = .off {
        didSet {
            model.pendingApproval = state == .mixed
            let value = state != .off
            if model.isOn != value { model.isOn = value }
        }
    }
    override var isEnabled: Bool {
        didSet {
            model.isEnabled = isEnabled
            if !isEnabled {
                releaseTimer?.invalidate()
                releaseTimer = nil
                model.cancelInteraction()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hosting = NSHostingView(rootView: NativeSettingsSwitch(model: model))
        clipsToBounds = false
        hosting.clipsToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -12),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 12),
            hosting.topAnchor.constraint(equalTo: topAnchor, constant: -12),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 12)
        ])
        setAccessibilityElement(false) // Expose the system switch once, via its hosting view.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        model.onChange = { [weak self] value in
            guard let self else { return }
            self.state = value ? .on : .off
            self.sendAction(self.action, to: self.target)
        }
    }
    required init?(coder: NSCoder) { nil }
    convenience init(target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 20) }
    override func accessibilityChildren() -> [Any]? {
        hosting.map { [$0] } ?? [] // NSControl otherwise treats this wrapper as a leaf.
    }
    override func setAccessibilityLabel(_ label: String?) {
        super.setAccessibilityLabel(label)
        model.label = label ?? ""
    }
    override func performClick(_ sender: Any?) {
        model.setFromUser(!model.isOn)
    }
}

// A native glass keycap with feedback only. It never synthesizes a key event,
// invokes a shortcut, or sends an action through the responder chain.
final class SettingsKeycap: NSButton {
    private let symbol: String
    init(_ symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        title = symbol
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(pressed(_:))
        keyEquivalent = ""
        setAccessibilityLabel(symbol == "⌥" ? "Option" : "Shift")
        updateGlass()
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { return nil }
    @objc private func pressed(_ sender: NSButton) { /* Visual feedback only. */ }
    private var usesNativeGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    override var wantsUpdateLayer: Bool { usesNativeGlass }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 26) }
    private func updateGlass() {
        isBordered = usesNativeGlass
        wantsLayer = usesNativeGlass
        guard #available(macOS 26.0, *) else { return }
        bezelStyle = .glass
        borderShape = .roundedRectangle
        controlSize = .small
        tintProminence = .secondary
        font = .systemFont(ofSize: 13, weight: .medium)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bezelColor = SettingsStyle.key.usingColorSpace(.sRGB)
            attributedTitle = NSAttributedString(string: symbol, attributes: [
                .font: font!, .foregroundColor: SettingsStyle.ink.usingColorSpace(.sRGB)!
            ])
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        updateGlass()
    }
    override func draw(_ dirtyRect: NSRect) {
        if usesNativeGlass { super.draw(dirtyRect); return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(isHighlighted ? 0.65 : 1)
        SettingsStyle.keyEdge.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let face = NSRect(x: 1, y: isFlipped ? 1 : 2, width: bounds.width - 2, height: bounds.height - 3)
        SettingsStyle.key.setFill()
        NSBezierPath(roundedRect: face, xRadius: 5, yRadius: 5).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                         .foregroundColor: SettingsStyle.ink]
        let size = (symbol as NSString).size(withAttributes: attributes)
        (symbol as NSString).draw(at: NSPoint(x: face.midX - size.width / 2, y: face.midY - size.height / 2),
                                  withAttributes: attributes)
    }
}

// A small status dot followed by muted text; hidden when there is nothing to say.
// With emphasizesLead, the part before " · " is drawn in ink ("Ready · iPad connected").
final class SettingsStatus: NSStackView {
    private final class Dot: NSView {
        var color = SettingsStyle.ok { didSet { needsDisplay = true } }
        override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) { color.setFill(); NSBezierPath(ovalIn: bounds).fill() }
    }
    private let dot = Dot()
    private let label = NSTextField(labelWithString: "")
    private let size: CGFloat
    private let emphasizesLead: Bool

    init(size: CGFloat = 13.5, emphasizesLead: Bool = false) {
        self.size = size
        self.emphasizesLead = emphasizesLead
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        dot.setContentHuggingPriority(.required, for: .horizontal)
        label.font = SettingsStyle.sans(size)
        label.textColor = SettingsStyle.muted
        addArrangedSubview(dot)
        addArrangedSubview(label)
    }
    required init?(coder: NSCoder) { return nil }
    func show(_ text: String?, dot color: NSColor? = nil) {
        isHidden = text == nil
        let value = text ?? ""
        if emphasizesLead, let split = value.range(of: " · ") {
            let line = NSMutableAttributedString(string: String(value[..<split.lowerBound]),
                attributes: [.font: SettingsStyle.sans(size, .medium), .foregroundColor: SettingsStyle.ink])
            line.append(NSAttributedString(string: String(value[split.lowerBound...]),
                attributes: [.font: SettingsStyle.sans(size), .foregroundColor: SettingsStyle.muted]))
            label.attributedStringValue = line
        } else {
            label.stringValue = value
        }
        dot.isHidden = color == nil
        if let color { dot.color = color }
    }
}

// Secondary line under a row title; it takes no space while empty.
final class SettingsDetail: NSTextField {
    private var styling = false
    override var stringValue: String {
        didSet {
            isHidden = stringValue.isEmpty
            // Wrapped notes get a little line spacing (Ashley 2026-10-30: 「太紧凑了」).
            guard !styling, let font, let textColor else { return }
            styling = true
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
            attributedStringValue = NSAttributedString(string: stringValue,
                attributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph])
            styling = false
        }
    }
}

// Thin indeterminate bar in ink: a short segment sliding along a hairline track.
final class SettingsActivityBar: NSView {
    private static let length: CGFloat = 64
    private let segment = CALayer()
    var animating = false {
        didSet {
            guard animating != oldValue else { return }
            isHidden = !animating
            segment.removeAllAnimations()
            guard animating else { return }
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -Self.length * 0.2
            slide.toValue = Self.length * 1.2
            slide.duration = 1.1
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            slide.repeatCount = .infinity
            segment.add(slide, forKey: "slide")
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 1
        layer?.masksToBounds = true
        layer?.addSublayer(segment)
        isHidden = true
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { return nil }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.length, height: 2) }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsStyle.line.cgColor
            segment.backgroundColor = SettingsStyle.ink.cgColor
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        segment.frame = NSRect(x: 0, y: 0, width: Self.length * 0.4, height: bounds.height)
        CATransaction.commit()
    }
}
