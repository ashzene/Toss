import AppKit
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
    var kind: Kind = .ghost { didSet { needsDisplay = true } }
    private var compact = false
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    convenience init(_ title: String, kind: Kind = .ghost, compact: Bool = true, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.compact = compact
        self.kind = kind
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    override var wantsUpdateLayer: Bool { false }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    private var textFont: NSFont { kind == .quiet ? SettingsStyle.sans(13) : SettingsStyle.sans(compact ? 12.5 : 13, .medium) }
    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: textFont])
        if kind == .quiet { return NSSize(width: ceil(size.width) + 2, height: 26) }
        return NSSize(width: ceil(size.width) + (compact ? 26 : 32), height: compact ? 27 : 32)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(!isEnabled ? 0.4 : (isHighlighted ? 0.6 : 1))
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        var color = SettingsStyle.ink
        var attributes: [NSAttributedString.Key: Any] = [.font: textFont]
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
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = SettingsStyle.line
        }
        attributes[.foregroundColor] = color
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
}

// Ink switch (no accent color), used for Launch at Login. Mixed = waiting for approval.
final class SettingsSwitch: NSButton {
    convenience init(target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        isBordered = false
        title = ""
        allowsMixedState = true
        self.target = target
        self.action = action
        setContentHuggingPriority(.required, for: .horizontal)
    }
    override var wantsUpdateLayer: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 20) }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: NSRect(x: 0, y: (bounds.height - 20) / 2, width: 34, height: 20), xRadius: 10, yRadius: 10).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.5)
        let track = NSRect(x: 0, y: (bounds.height - 20) / 2, width: 34, height: 20)
        (state == .on ? SettingsStyle.ink : state == .mixed ? SettingsStyle.muted : SettingsStyle.line).setFill()
        NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10).fill()
        (state == .off ? SettingsStyle.knobOff : SettingsStyle.background).setFill()
        let x = state == .off ? track.minX + 2 : track.maxX - 18
        NSBezierPath(ovalIn: NSRect(x: x, y: track.minY + 2, width: 16, height: 16)).fill()
    }
}

// Keycap like the website's <kbd>: 1 pt edge, 2 pt along the bottom.
final class SettingsKeycap: NSView {
    private let symbol: String
    init(_ symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { return nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 26) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
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
