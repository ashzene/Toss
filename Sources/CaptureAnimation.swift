import AppKit
import ImageIO
import QuartzCore
import ScreenCaptureKit

// This is visual feedback only. It never reads target UI, changes focus,
// touches the clipboard, or decides whether an attachment succeeded.
struct CaptureAnimationState {
    enum Phase: Equatable { case capturing, captured, confirmed, failed }
    private(set) var requestID: UInt64?
    private(set) var generation: UInt64 = 0
    private(set) var phase: Phase?

    mutating func begin(_ id: UInt64) {
        generation &+= 1
        requestID = id
        phase = .capturing
    }

    @discardableResult mutating func captured(_ id: UInt64) -> Bool {
        guard requestID == id, phase == .capturing else { return false }
        phase = .captured
        return true
    }

    @discardableResult mutating func finish(_ id: UInt64, success: Bool) -> Bool {
        guard requestID == id, phase == .capturing || phase == .captured else { return false }
        phase = success ? .confirmed : .failed
        return true
    }

    func acceptsImage(_ id: UInt64, generation token: UInt64) -> Bool {
        requestID == id && generation == token && phase == .captured
    }

    func matches(_ id: UInt64, generation token: UInt64) -> Bool {
        requestID == id && generation == token
    }

    mutating func dismiss() {
        generation &+= 1
        requestID = nil
        phase = nil
    }
}


// Pure geometry only: the landing spot must come from a separately confirmed
// native attachment. Never infer a slot, fixed coordinate, or substitute screen.
// (2026-10-24: the picture "lands" in the composer instead of flying
// across the screen after the chip is already visible.)
struct CaptureLandingPlan: Equatable {
    let screenFrame: CGRect
    let destinationFrame: CGRect
    // The whole attachment tile in screen coordinates. The landing copy fills it
    // (aspect-fill) so the real thumbnail underneath is never visible as a second layer.
    var tileFrame: CGRect = .zero
}

enum CaptureCardTiming {
    // Toast slides up and fades in once the result is known.
    static let appear: Double = 0.2
    // One continuous wobble from the moment of impact (no approach, no rest frame); its
    // length depends on the style...
    static var landing: Double { CaptureJelly.params().duration }
    // ...and only then a fade, handing over to the real chip.
    static let landingFade: Double = 0.15
    static var landingTotal: Double { landing + landingFade }
    static let fadeOut: Double = 0.2
}

// The picture lands on the confirmed chip like jelly. Every style starts at the impact,
// already deformed and still moving (never parked), and is a damped spring: each swing is
// `ratio` of the last, eased to exactly the chip's size at the end.
// - lean (11:25, "horizontal"): thrown in from the side; the top leans into a parallelogram.
// - drop (11:39, "vertical"): falls straight down; squash and stretch only.
// - both (11:47, "combined"): drop plus a quicker lean, out of step with the bounce.
// - extra (14:56, default): like both, but the up/down is much bigger and slower (the
//   up/down was not bouncy enough); the lean stays secondary.
// - patch (flag): like extra, but squashes below and stretches narrower than the chip. It needs
//   an opaque patch of the sampled composer colour over the real chip; without one it is extra.
// Covered styles (all but patch) never uncover the real chip: they squash and stretch around
// a base enlarged by the spring's reach, so the flattest side is exactly the chip's size; the
// copy is `margin` larger than the tile on every side so its rounded corners still cover the
// tile's corners when sheared (a rounded rect contains its rect inset by 0.293 x radius).
// Pinned at the tile's bottom centre. Defaults key jellyLandingStyle. Pure for tests.
enum CaptureJelly {
    enum Style { case lean, drop, both, extra, patch }
    static var style: Style {
        switch UserDefaults.standard.string(forKey: "jellyLandingStyle") {
        case "horizontal": return .lean
        case "vertical": return .drop
        case "combined", "both": return .both
        case "patch": return .patch
        default: return .extra
        }
    }
    static let cornerRadius: CGFloat = 9
    static let margin: CGFloat = 3

    // A damped spring from impact: already at `start`, moving at `velocity` (per second).
    struct Spring { let start: Double; let velocity: Double; let frequency: Double }
    enum Body { case leanSquash, covered, upright, free }
    // upright (2026-10-25 video: the bulge covered the neighbouring attachment):
    // pinned at the tile's bottom-LEFT, the copy only grows right and up. New tiles are
    // appended at the right end of the row in Codex and Claude, so nothing is on that side;
    // the sideways growth is capped below the gap between tiles (Codex 11 pt, Claude ~8 pt on
    // a 173-184 pt tile) and all of the bounce goes into the height.
    static let uprightWidthCap = 0.04
    struct Params { let duration: Double; let ratio: Double; let body: Body; let bounce: Spring?; let lean: Spring? }

    static let leanPeak = 16.0 * Double.pi / 180       // lean only: the squash follows the lean...
    static let leanPeakSquash = 0.12                   // ...1.12 wide at its peak
    static func params(_ style: Style = style) -> Params {
        let degree = Double.pi / 180
        switch style {
        case .lean:
            return Params(duration: 1.15, ratio: 0.6, body: .leanSquash, bounce: nil,
                          lean: Spring(start: -8 * degree, velocity: -4.0, frequency: 14.35))
        case .drop:
            return Params(duration: 1.15, ratio: 0.6, body: .covered,
                          bounce: Spring(start: -0.08, velocity: 2.5, frequency: 20), lean: nil)
        case .both:
            return Params(duration: 1.15, ratio: 0.6, body: .covered,
                          bounce: Spring(start: -0.08, velocity: 2.5, frequency: 20),
                          lean: Spring(start: -5 * degree, velocity: -7.0, frequency: 24))
        case .extra:
            return Params(duration: 1.6, ratio: 0.68, body: .upright,
                          bounce: Spring(start: -0.13, velocity: 2.7, frequency: 19.6), lean: nil)
        case .patch:
            return Params(duration: 1.6, ratio: 0.68, body: .free,
                          bounce: Spring(start: -0.22, velocity: 7.0, frequency: 19.6),
                          lean: Spring(start: -4 * degree, velocity: -4.0, frequency: 22))
        }
    }

    // The spring's value and its reach (the decaying amplitude it never exceeds). The last
    // 15% is eased to exactly 0 so it ends at the chip's size.
    static func spring(_ spring: Spring?, at t: Double, params p: Params) -> (value: Double, reach: Double) {
        guard let spring else { return (0, 0) }
        let decay = log(1 / p.ratio) * spring.frequency / Double.pi
        let t = min(max(0, t), p.duration)
        let sine = (spring.velocity + decay * spring.start) / spring.frequency
        let fade = exp(-decay * t)
        let value = fade * (spring.start * cos(spring.frequency * t) + sine * sin(spring.frequency * t))
        let tail = max(0, (t / p.duration - 0.85) / 0.15)
        let window = 1 - tail * tail * (3 - 2 * tail)
        return (value * window, (spring.start * spring.start + sine * sine).squareRoot() * fade * window)
    }

    // Skew angle in radians (negative = top leans left).
    static func lean(at t: Double, style: Style = style) -> Double {
        let p = params(style)
        return spring(p.lean, at: t, params: p).value
    }

    static func scale(at t: Double, style: Style = style) -> (x: Double, y: Double) {
        let p = params(style)
        switch p.body {
        case .leanSquash:
            // Wide while leaning left, tall while leaning right; never below 1.
            let d = -lean(at: t, style: style) / leanPeak * leanPeakSquash
            return d >= 0 ? (1 + d, 1) : (1, 1 - d)
        case .covered:
            // Width and height squash and stretch against each other around a base enlarged by
            // the spring's reach, which shrinks back to 1 as the bounce dies: the squashed side
            // bottoms out at exactly the chip's size and never uncovers it.
            let b = spring(p.bounce, at: t, params: p)
            let base = 1 / (1 - b.reach)
            return (base * (1 + b.value), base * (1 - b.value))
        case .upright:
            // The height bounces around the enlarged base exactly like covered; the width may
            // only grow by uprightWidthCap, so the bounce reads vertical and stays off neighbours.
            let b = spring(p.bounce, at: t, params: p)
            let base = 1 / (1 - b.reach)
            return (1 + min(uprightWidthCap, max(0, base * (1 + b.value) - 1)), base * (1 - b.value))
        case .free:
            // Volume-preserving squash and stretch, also below the chip's size (patch only).
            let b = spring(p.bounce, at: t, params: p)
            return (exp(b.value), exp(-b.value))
        }
    }

    // Layer transform about the bottom-centre anchor: x' = a*x + c*y + tx, y' = d*y.
    // The top edge moves by `shift`; widening by |shift| and centring by -shift/2 keeps the
    // whole original tile inside the parallelogram.
    struct Shape: Equatable { let a: Double; let c: Double; let d: Double; let tx: Double }
    static func shape(at t: Double, tile: CGSize, style: Style = style) -> Shape {
        let (sx, sy) = scale(at: t, style: style)
        let h = Double(tile.height), w = Double(tile.width)
        let shift = tan(lean(at: t, style: style)) * sy * h
        return Shape(a: sx + abs(shift) / w, c: h > 0 ? shift / h : 0, d: sy, tx: -shift / 2)
    }

    // Where the deformation is pinned: the tile's bottom-left (upright) or bottom-centre.
    static func pinsLeft(_ style: Style = style) -> Bool { params(style).body == .upright }

    // Hover shield (off unless jellyBlockHover; 2026-10-25, to be confirmed on Claude): the
    // landing tile plus room for a corner ✕, in screen coordinates.
    static let blockHoverKey = "jellyBlockHover"
    static var blocksHover: Bool { UserDefaults.standard.bool(forKey: blockHoverKey) }
    static let hoverShieldReach: CGFloat = 16
    static func hoverShieldFrame(tile: CGRect) -> CGRect { tile.insetBy(dx: -hoverShieldReach, dy: -hoverShieldReach) }
    static let pointerShieldRadius: CGFloat = 24
    static let pointerShieldLifetime: Double = 3

    // Sampled finer than the display refresh so no straight segments show.
    static func keyframes(tile: CGSize, style: Style = style, count: Int? = nil) -> [Shape] {
        let duration = params(style).duration
        let count = count ?? Int((duration * 105).rounded()) + 1
        return (0..<count).map { shape(at: duration * Double($0) / Double(count - 1), tile: tile, style: style) }
    }
}

// How the target app draws an attachment tile, so the copy matches it and the final fade
// reveals an identical tile. Codex: the picture covers the tile (object-cover). Claude in
// dark mode: a dark rounded card (sRGB 25,25,25, corner radius 15 pt) with the picture
// fitted and centred in it; measured from Claude 2026-10-24 (tile 173 x 174 pt; its AX
// button frame is exactly the card). Claude's light-mode card colour is unmeasured, so it
// keeps the cover look rather than guess a colour.
// What user input does to a landing copy (2026-10-25). Switching apps still cancels at once
// (workspace observer); a failed or interrupted toss fades it via interrupt(requestID:).
enum CaptureFlightInputPolicy {
    enum Action: Equatable { case ignore, fade, cancel }
    static let fadeDuration = 0.15
    static func action(for type: NSEvent.EventType, inTile: Bool) -> Action {
        switch type {
        case .keyDown: return .ignore
        case .scrollWheel: return .fade
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return inTile ? .cancel : .fade
        default: return .ignore
        }
    }
}

enum CaptureTileLook: Equatable {
    case cover
    case card(red: UInt8, green: UInt8, blue: UInt8, cornerRadius: CGFloat)
    static func forTarget(claude: Bool, darkAppearance: Bool) -> CaptureTileLook {
        claude && darkAppearance ? .card(red: 25, green: 25, blue: 25, cornerRadius: 15) : .cover
    }
    // Claude paints its card a few pt outside the AX button's frame (2026-10-25 Live
    // Photos: the real picture's right and bottom edges showed beside the copy), so the copy
    // covers this much more on every side there. Conservative until measured in pixels; extra
    // cover lands on Claude's own dark card area and does not show.
    static let claudeOutset: CGFloat = 6
    // With the pointer resting on the landing spot, Claude's card is hovered from the moment it
    // appears: it grows toward the top and right and shows its ✕ at the top-right corner
    // (2026-10-25 Live Photos: the hand cursor was on the new tile every time, and the
    // real card showed above and right of the copy). Codex tiles do not grow on hover.
    // Fallback while the hover shield is unproven: extra cover when hovered (defaults
    // jellyClaudeHoverExtra, pt; 0 = off until measured). The top extra never reaches the row
    // above: at most `gapAbove` - 1 pt beyond the tile (v13: never cover a neighbour).
    static let hoverExtraKey = "jellyClaudeHoverExtra"
    static var claudeHoverExtra: CGFloat { CGFloat(UserDefaults.standard.double(forKey: hoverExtraKey)) }
    // `pointer`: the mouse in AX coordinates (top-left origin), if known. `gapAbove`: free space
    // between the tile and the tile above it, if there is one.
    static func coverFrame(_ tile: CGRect, claude: Bool, pointer: CGPoint? = nil,
                           hoverExtra: CGFloat = claudeHoverExtra, gapAbove: CGFloat? = nil) -> CGRect {
        guard claude else { return tile }
        let base = tile.insetBy(dx: -claudeOutset, dy: -claudeOutset)
        guard hoverExtra > 0, let pointer, base.contains(pointer) else { return base }
        var top = claudeOutset + hoverExtra
        if let gapAbove { top = min(top, max(0, gapAbove - 1)) }
        // AX y grows downward: extend up (minY) and right; the bottom-left pin stays put.
        return CGRect(x: base.minX, y: tile.minY - top,
                      width: base.width + hoverExtra, height: base.maxY - (tile.minY - top))
    }
    @MainActor static func pointerAX() -> CGPoint? {
        guard let primary = NSScreen.screens.first?.frame else { return nil }
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primary.maxY - p.y)
    }
    // The copy is `margin` larger than the tile on every side, so a concentric outline.
    var copyCornerRadius: CGFloat {
        switch self {
        case .cover: return CaptureJelly.cornerRadius
        case .card(_, _, _, let radius): return radius + CaptureJelly.margin
        }
    }
}

// Patch style only: the composer colour beside the confirmed chip, sampled from thin strips
// left and right of it. Every sample must agree (a border, text or another chip next to it
// makes them disagree); anything uncertain returns nil and the landing stays covered (extra).
enum CapturePatchSample {
    static let gap: CGFloat = 2       // strip starts this far outside the chip
    static let strip: CGFloat = 3     // strip width
    // The AX (top-left origin) rect to capture: the chip's middle band plus both strips.
    static func captureRect(chipAX: CGRect) -> CGRect {
        CGRect(x: chipAX.minX - gap - strip, y: chipAX.midY - 6,
               width: chipAX.width + 2 * (gap + strip), height: 12)
    }
    // Median colour of the samples if every one is within `tolerance` of it on all channels.
    static func agreedColor(_ samples: [(r: UInt8, g: UInt8, b: UInt8)], minimum: Int = 12,
                            tolerance: Int = 4) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard samples.count >= minimum else { return nil }
        func median(_ values: [UInt8]) -> UInt8 { values.sorted()[values.count / 2] }
        let m = (r: median(samples.map(\.r)), g: median(samples.map(\.g)), b: median(samples.map(\.b)))
        let agree = samples.allSatisfy {
            abs(Int($0.r) - Int(m.r)) <= tolerance && abs(Int($0.g) - Int(m.g)) <= tolerance &&
            abs(Int($0.b) - Int(m.b)) <= tolerance
        }
        return agree ? m : nil
    }
    // Pixels of the two strips in a capture of captureRect (RGBA, row-major, `scale` px per pt).
    static func stripSamples(rgba: [UInt8], width: Int, height: Int, scale: CGFloat) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let stripPx = max(1, Int((strip * scale).rounded(.down)))
        guard width > 2 * stripPx + 2, height > 0, rgba.count >= width * height * 4 else { return [] }
        var out: [(r: UInt8, g: UInt8, b: UInt8)] = []
        for y in 0..<height {
            for x in Array(0..<stripPx) + Array((width - stripPx)..<width) {
                let i = (y * width + x) * 4
                out.append((rgba[i], rgba[i + 1], rgba[i + 2]))
            }
        }
        return out
    }
}

// The corner shows only the result toast: 280 x 56, 16 pt from the visible frame's
// right and bottom edges. Nothing is shown there while capturing.
enum CaptureCardLayout {
    static let width: CGFloat = 280
    static let height: CGFloat = 56
    static let shadowMargin: CGFloat = 24
    static let edgeInset: CGFloat = 16
    static let panelSize = CGSize(width: width + 2 * shadowMargin, height: height + 2 * shadowMargin)
    static let markFrame = CGRect(x: 14, y: 18, width: 20, height: 20)

    static func panelFrame(in visible: CGRect) -> CGRect {
        CGRect(x: visible.maxX - edgeInset - width - shadowMargin, y: visible.minY + edgeInset - shadowMargin,
               width: panelSize.width, height: panelSize.height)
    }
    // The toast's screen rect inside panelFrame(in:).
    static func card(in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + shadowMargin, y: panel.minY + shadowMargin, width: width, height: height)
    }
}

enum CaptureFlightEventAdmission {
    static func accepts(timestamp: TimeInterval, startedAt: TimeInterval) -> Bool {
        timestamp.isFinite && startedAt.isFinite && startedAt > 0 && timestamp >= startedAt
    }
}

enum CaptureFlightGeometry {
    static func aspectFit(_ image: CGSize, in frame: CGRect) -> CGRect? {
        guard valid(frame), image.width.isFinite, image.height.isFinite,
              image.width > 0, image.height > 0 else { return nil }
        let scale = min(frame.width / image.width, frame.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func landing(destinationAXFrame: CGRect?, imageSize: CGSize,
                        screens: [CGRect], targetPID: pid_t?, frontmostPID: pid_t?,
                        reduceMotion: Bool) -> CaptureLandingPlan? {
        guard !reduceMotion, let targetPID, targetPID > 0, frontmostPID == targetPID,
              let destinationAXFrame, valid(destinationAXFrame),
              let primary = screens.first, screens.allSatisfy(valid) else { return nil }
        // AX uses the top-left of the PRIMARY screen, not the union of displays.
        let destination = CGRect(x: destinationAXFrame.minX,
                                 y: primary.maxY - destinationAXFrame.maxY,
                                 width: destinationAXFrame.width, height: destinationAXFrame.height)
        guard valid(destination) else { return nil }
        let targetScreens = screens.indices.filter { screens[$0].contains(destination) }
        guard targetScreens.count == 1, let to = aspectFit(imageSize, in: destination) else { return nil }
        return CaptureLandingPlan(screenFrame: screens[targetScreens[0]], destinationFrame: to, tileFrame: destination)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite &&
        rect.height.isFinite && rect.width > 0 && rect.height > 0 &&
        rect.maxX.isFinite && rect.maxY.isFinite
    }
}


@MainActor
final class CaptureAnimation {
    private(set) var lastArrivalStatus = "idle"
    private var state = CaptureAnimationState()
    private var toastScreen: NSScreen?
    private var thumbnail: CGImage?
    private var panel: CaptureFeedbackPanel?
    private var feedback: CaptureFeedbackView?
    // When the shown toast is due to fade (set with its hold); see detachToast.
    private var toastFadeAt: Double?
    // A finished press's toast still holding while a queued press runs; removed when it has
    // faded or as soon as the next toast takes its place.
    private var detachedToast: (panel: CaptureFeedbackPanel, view: CaptureFeedbackView)?

    // A queued press starts while the previous ✓ toast is still holding: let that toast finish
    // its hold and fade on its own instead of being cut by the new press's begin().
    func detachToast() {
        guard let panel, let feedback, let fadeAt = toastFadeAt else { return }
        removeDetachedToast()
        self.panel = nil
        self.feedback = nil
        toastFadeAt = nil
        detachedToast = (panel, feedback)
        let wait = max(0, fadeAt - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.detachedToast?.panel === panel else { return }
            feedback.fadeOut(reduceMotion: self.reduceMotion)
            DispatchQueue.main.asyncAfter(deadline: .now() + CaptureCardTiming.fadeOut) { [weak self] in
                guard let self, self.detachedToast?.panel === panel else { return }
                self.removeDetachedToast()
            }
        }
    }

    private func removeDetachedToast() {
        guard let old = detachedToast else { return }
        detachedToast = nil
        old.view.clear()
        old.panel.orderOut(nil)
        old.panel.contentView = nil
    }
    private var dismissal: Task<Void, Never>?
    private var accessibilityObserver: NSObjectProtocol?
    private var flightPanel: CaptureFeedbackPanel?
    // A landing copy is about to start: sampling the chip colour, no panel yet (a queued press
    // waits these few ms), or bouncing on the chip (see detachLanding).
    var isSamplingLanding: Bool { lastArrivalStatus == "sampling" }
    var isLanding: Bool { flightPanel != nil && lastArrivalStatus == "landing" }
    // Seconds since the current landing copy appeared (nil when none is bouncing).
    var landingAge: Double? {
        guard isLanding, let landingStartedAt else { return nil }
        return ProcessInfo.processInfo.systemUptime - landingStartedAt
    }
    private var landingEndsAt: Double?
    private var landingStartedAt: Double?

    // A queued keypress starts while the previous picture is still bouncing (2026-10-28:
    // it must stay smooth, the queue must not look stuck). That landing plays on to its end on its own
    // panel; the new keypress's begin()/dismiss() no longer own or cut it. Core Animation
    // drives the bounce, so the panel only has to be removed when it is over.
    func detachLanding() {
        guard let panel = flightPanel, let view = flightView, lastArrivalStatus == "landing",
              let endsAt = landingEndsAt else { return }
        // The hover and pointer shields stay with their copy until the bounce ends, so the real tile
        // under it still sees no hover (Claude would grow the card and show its ✕ beside the copy).
        let hover = hoverShield, pointer = pointerShield
        hoverShield = nil
        pointerShield = nil
        flightPanel = nil
        flightView = nil
        clearFlight() // monitors and the cleanup task; this panel is no longer attached
        lastArrivalStatus = "detached"
        landingEndsAt = nil
        landingStartedAt = nil
        // Nothing watches input for this copy any more. A click or scroll on either shield (that one
        // event is taken, as before the detach) fades the copy and removes both shields at once;
        // otherwise everything goes when the bounce ends. Each step runs once.
        let teardown = CaptureDetachedTeardown(
            fade: {
                hover?.orderOut(nil); hover?.contentView = nil
                pointer?.orderOut(nil); pointer?.contentView = nil
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = CaptureFlightInputPolicy.fadeDuration
                    panel.animator().alphaValue = 0
                })
            },
            remove: {
                hover?.orderOut(nil); hover?.contentView = nil
                pointer?.orderOut(nil); pointer?.contentView = nil
                panel.alphaValue = 0
                view.clear()
                panel.orderOut(nil)
                panel.contentView = nil
            })
        if let hover {
            let catcher = CaptureShieldView(frame: CGRect(origin: .zero, size: hover.frame.size))
            catcher.onTouch = { teardown.touched() }
            hover.contentView = catcher
        }
        (pointer?.contentView as? CaptureShieldView)?.onTouch = { teardown.touched() }
        let remaining = max(0, endsAt - ProcessInfo.processInfo.systemUptime)
        // A faded copy is invisible and click-through until then.
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { teardown.finish() }
    }
    // Created at the keypress and ordered in at alpha 0 (invisible, click-through), so that
    // showing the jelly or the toast at confirmation costs no window creation (test
    // video, 15:40: the real tile showed for 100-170 ms before the copy).
    private var spareFlight: CaptureFeedbackPanel?
    private var spareToast: CaptureFeedbackPanel?
    private var flightView: CaptureFlightView?
    private var flightApplicationObserver: NSObjectProtocol?
    private var flightGlobalMonitor: Any?
    private var flightLocalMonitor: Any?
    private var hoverShield: CaptureFeedbackPanel?
    private var pointerShield: CaptureFeedbackPanel?
    private var landingCleanup: Task<Void, Never>?
    private let decodeQueue = DispatchQueue(label: "io.github.ashzene.toss.animation-decode", qos: .utility)

    init() {
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.reduceMotion else { return }
                    self.feedback?.disableMotion()
                    if self.flightPanel != nil {
                        self.lastArrivalStatus = "reduced-motion"
                        self.clearFlight()
                    }
                }
            }
    }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        if let flightApplicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(flightApplicationObserver)
        }
        if let flightGlobalMonitor { NSEvent.removeMonitor(flightGlobalMonitor) }
        if let flightLocalMonitor { NSEvent.removeMonitor(flightLocalMonitor) }
    }

    // All lifecycle methods return immediately. In particular, none must be
    // awaited before capture, paste, verification, or the confirmation sound.
    // Nothing appears in the corner while capturing; begin only remembers the screen.
    func begin(requestID: UInt64, screen: NSScreen? = nil) {
        dismiss()
        state.begin(requestID)
        lastArrivalStatus = "idle"
        confirmedOffset = nil
        toastScreen = screen ?? NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main
        guard let toastScreen else { return }
        if !reduceMotion { spareFlight = Self.makePanel(frame: toastScreen.frame, allSpaces: false, prepared: true) }
        spareToast = Self.makePanel(frame: CaptureCardLayout.panelFrame(in: toastScreen.visibleFrame),
                                    allSpaces: true, prepared: true)
    }

    // A borderless, non-activating, click-through panel that never shows in screen
    // captures and has no system appear animation (it scaled a new window up from slightly
    // smaller for the first frames, which lifted the copy off the chip's bottom edge).
    // prepared: ordered in now at alpha 0, so making it visible later is immediate.
    private static func makePanel(frame: CGRect, allSpaces: Bool, prepared: Bool) -> CaptureFeedbackPanel {
        let panel = CaptureFeedbackPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: !prepared)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.collectionBehavior = allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
                                             : [.fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.sharingType = .none
        panel.animationBehavior = .none
        if prepared {
            panel.alphaValue = 0
            // Never use makeKeyAndOrderFront, makeFirstResponder or NSApp.activate.
            panel.orderFrontRegardless()
        }
        return panel
    }

    // The prepared panel if it matches `frame`, else a new one; shown at full opacity.
    private func takePanel(_ spare: inout CaptureFeedbackPanel?, frame: CGRect, allSpaces: Bool) -> CaptureFeedbackPanel {
        let panel: CaptureFeedbackPanel
        if let ready = spare, ready.frame == frame {
            panel = ready
        } else {
            spare?.orderOut(nil)
            panel = Self.makePanel(frame: frame, allSpaces: allSpaces, prepared: false)
        }
        spare = nil
        return panel
    }

    // The picture is decoded only for the composer landing; the corner never shows it.
    func captured(requestID: UInt64, image: URL) {
        guard state.captured(requestID) else { return }
        let generation = state.generation
        // ImageIO makes only a small UI thumbnail. The original PNG used by
        // the attachment transaction is never rewritten or downsampled.
        decodeQueue.async { [weak self] in
            let thumbnail: CGImage? = autoreleasepool {
                guard image.isFileURL,
                      let source = CGImageSourceCreateWithURL(image as CFURL,
                        [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.state.acceptsImage(requestID, generation: generation),
                      let thumbnail else { return }
                self.thumbnail = thumbnail
            }
        }
    }

    // The caller must have independently verified the native attachment. The picture
    // lands on the confirmed chip; it never changes the native insertion itself.
    // toastHold: how long the ✓ toast stays; nil = no toast (Show notifications off).
    // Early start (AttachmentSighting): the new tile was seen before the full confirmation.
    // The jelly starts now; confirmed() then only adds the toast. A failure removes it.
    // Also used at paste time with a predicted slot; the stable sighting then corrects it.
    func sighted(requestID: UInt64, destinationAXFrame: CGRect, targetPID: pid_t, look: CaptureTileLook) {
        guard state.requestID == requestID, state.phase == .captured, earlyLanding != requestID else { return }
        if startLanding(requestID: requestID, destinationAXFrame: destinationAXFrame, targetPID: targetPID, look: look) {
            earlyLanding = requestID
            earlyTileAX = destinationAXFrame
        }
    }
    private var earlyLanding: UInt64?
    private var earlyTileAX: CGRect?
    // How far the early copy was from the confirmed attachment's frame (pt), for diagnostics.
    private(set) var confirmedOffset: CGFloat?

    // The stable, real frame of the new tile. If the copy is already up (a predicted slot) and
    // more than `tolerance` away, it moves there at once, without restarting the bounce; if
    // nothing is up yet, the landing starts here. Returns how far the copy moved (pt), or nil.
    @discardableResult
    func settle(requestID: UInt64, destinationAXFrame: CGRect, targetPID: pid_t, look: CaptureTileLook,
                tolerance: CGFloat = 2) -> CGFloat? {
        guard state.requestID == requestID else { return nil }
        guard earlyLanding == requestID, let previous = earlyTileAX, let view = flightView, let panel = flightPanel else {
            sighted(requestID: requestID, destinationAXFrame: destinationAXFrame, targetPID: targetPID, look: look)
            return nil
        }
        let offset = max(abs(previous.minX - destinationAXFrame.minX), abs(previous.minY - destinationAXFrame.minY),
                         abs(previous.width - destinationAXFrame.width), abs(previous.height - destinationAXFrame.height))
        guard offset > tolerance else { return offset }
        // Same conversion as the landing plan: AX top-left of the primary screen to the panel.
        guard let primary = NSScreen.screens.first?.frame else { return offset }
        let screenRect = CGRect(x: destinationAXFrame.minX, y: primary.maxY - destinationAXFrame.maxY,
                                width: destinationAXFrame.width, height: destinationAXFrame.height)
        guard panel.frame.contains(screenRect) else { clearFlight(); return offset }
        view.retarget(tile: screenRect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY))
        earlyTileAX = destinationAXFrame
        return offset
    }

    // The real tile grew after it was read (Claude: 160 -> 173 pt, 2026-10-25). The running copy
    // grows to cover the larger frame too; it never shrinks, and the bounce keeps going.
    // Returns how much wider/taller the copy became (pt), or nil if nothing changed.
    @discardableResult
    func grow(requestID: UInt64, toAX frame: CGRect) -> CGFloat? {
        guard state.requestID == requestID, let current = earlyTileAX, let view = flightView, let panel = flightPanel,
              let primary = NSScreen.screens.first?.frame else { return nil }
        let target = current.union(frame)
        guard target.width > current.width + 0.25 || target.height > current.height + 0.25 else { return nil }
        let screenRect = CGRect(x: target.minX, y: primary.maxY - target.maxY, width: target.width, height: target.height)
        guard panel.frame.contains(screenRect) else { return nil }
        view.retarget(tile: screenRect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY))
        earlyTileAX = target
        return max(target.width - current.width, target.height - current.height)
    }

    func confirmed(requestID: UInt64, destinationAXFrame: CGRect? = nil, targetPID: pid_t? = nil,
                   look: CaptureTileLook = .cover, title: String, toastHold: Double?) {
        guard state.finish(requestID, success: true) else { return }
        // The toast first, then the jelly (the caller has already played the sound).
        let toastShown = toastHold != nil && showToast(success: true, title: title)
        let early = earlyLanding == requestID && flightPanel != nil
        // Third check on an early copy: the confirmation's own full-read frame of the attachment.
        // More than 1 pt away from the copy's tile: the copy moves onto it at once.
        if early, let confirmedFrame = destinationAXFrame, let pid = targetPID {
            confirmedOffset = settle(requestID: requestID, destinationAXFrame: confirmedFrame, targetPID: pid,
                                     look: look, tolerance: 1)
        }
        let landed = early || startLanding(requestID: requestID, destinationAXFrame: destinationAXFrame,
                                           targetPID: targetPID, look: look)
        if landed && !early { earlyTileAX = destinationAXFrame }
        retireResult(requestID: requestID, toastHold: toastShown ? toastHold : nil, waitForLanding: landed)
    }

    // A failed keypress (the caller decides which ones): the ✕ toast, if enabled.
    // Nothing on screen claims the attachment is absent.
    func failCurrent(title: String, toastHold: Double?) {
        guard let requestID = state.requestID, state.finish(requestID, success: false) else {
            dismiss(); return
        }
        clearFlight()
        let toastShown = toastHold != nil && showToast(success: false, title: title)
        retireResult(requestID: requestID, toastHold: toastShown ? toastHold : nil, waitForLanding: false)
    }

    func cancel(requestID: UInt64) {
        guard state.requestID == requestID else { return }
        dismiss()
    }

    // Hover shield at paste time (jellyBlockHover): a small invisible window under the resting
    // pointer, put up right before Cmd+V, so a card the app draws under the pointer is never
    // hovered at all (2026-10-25: with the shield only at landing, Claude had already started
    // its hover growth and the right edge showed while it shrank back). Removed with the
    // flight, on any failure or cancel, after `pointerShieldLifetime` without a landing, or as
    // soon as it is clicked or scrolled on.
    func shieldPointer(requestID: UInt64) {
        guard CaptureJelly.blocksHover, !reduceMotion, state.requestID == requestID else { return }
        removePointerShield()
        let p = NSEvent.mouseLocation
        let r = CaptureJelly.pointerShieldRadius
        let frame = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let shield = Self.makePanel(frame: frame, allSpaces: false, prepared: false)
        shield.ignoresMouseEvents = false
        shield.backgroundColor = NSColor(white: 0, alpha: 0.004)
        let view = CaptureShieldView(frame: CGRect(origin: .zero, size: frame.size))
        view.onTouch = { [weak self] in self?.removePointerShield() }
        shield.contentView = view
        shield.orderFrontRegardless()
        pointerShield = shield
        DispatchQueue.main.asyncAfter(deadline: .now() + CaptureJelly.pointerShieldLifetime) { [weak self, weak shield] in
            guard let self, let shield, self.pointerShield === shield, self.flightPanel == nil else { return }
            self.removePointerShield()
        }
    }
    private func removePointerShield() {
        pointerShield?.orderOut(nil)
        pointerShield?.contentView = nil
        pointerShield = nil
    }

    func dismiss() {
        if flightPanel != nil && lastArrivalStatus == "landing" { lastArrivalStatus = "cancelled" }
        dismissal?.cancel()
        dismissal = nil
        state.dismiss()
        earlyLanding = nil
        earlyTileAX = nil
        thumbnail = nil
        clearFlight()
        feedback?.clear()
        panel?.orderOut(nil)
        panel?.contentView = nil
        feedback = nil
        panel = nil
        toastFadeAt = nil
        transferNoticeShowing = false
        spareFlight?.orderOut(nil)
        spareToast?.orderOut(nil)
        spareFlight = nil
        spareToast = nil
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // User input during the landing removes only that overlay; the toast stays.
    // An interruption fades the landing copy out (the real tile is right underneath) instead of
    // cutting it mid-bounce (2026-10-25: a cut-off jelly looked wrong).
    func fadeFlight() {
        guard let panel = flightPanel, lastArrivalStatus == "landing" || lastArrivalStatus == "sampling" else {
            cancelFlight(); return
        }
        lastArrivalStatus = "faded"
        hoverShield?.orderOut(nil); hoverShield = nil
        removePointerShield()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = CaptureFlightInputPolicy.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.flightPanel === panel else { return }
                self.clearFlight()
            }
        })
    }

    // The transaction was interrupted: fade any landing copy, then retire everything else.
    func interrupt(requestID: UInt64) {
        guard state.requestID == requestID else { return }
        guard flightPanel != nil else { dismiss(); return }
        let generation = state.generation
        fadeFlight()
        DispatchQueue.main.asyncAfter(deadline: .now() + CaptureFlightInputPolicy.fadeDuration + 0.02) { [weak self] in
            guard let self, self.state.matches(requestID, generation: generation) else { return }
            self.dismiss()
        }
    }

    func cancelFlight() {
        guard flightPanel != nil else { return }
        if lastArrivalStatus == "landing" { lastArrivalStatus = "cancelled" }
        clearFlight()
    }

    // toastHold: the hold of a toast already on screen, or nil when none is shown.
    private func retireResult(requestID: UInt64, toastHold: Double?, waitForLanding: Bool) {
        let landing = waitForLanding ? CaptureCardTiming.landingTotal + 0.05 : 0
        guard let toastHold else {
            if waitForLanding { retire(requestID: requestID, delay: landing) } else { dismiss() }
            return
        }
        toastFadeAt = ProcessInfo.processInfo.systemUptime + CaptureCardTiming.appear + max(0, toastHold)
        retire(requestID: requestID, delay: max(landing, CaptureCardTiming.appear + max(0, toastHold)))
    }

    private var transferNoticeShowing = false

    // Reuse the result-toast panel and drawing; updates change text without an entrance animation.
    func showTransferNotice(_ title: String) {
        if let until = toastFadeAt, until > ProcessInfo.processInfo.systemUptime { return }
        if transferNoticeShowing, let feedback, panel != nil {
            feedback.showProgress(title: title); return
        }
        guard let screen = toastScreen ?? NSScreen.main else { return }
        removeDetachedToast()
        dismissal?.cancel(); dismissal = nil
        panel?.orderOut(nil)
        let frame = CaptureCardLayout.panelFrame(in: screen.visibleFrame)
        let panel = takePanel(&spareToast, frame: frame, allSpaces: true)
        let view = CaptureFeedbackView(frame: NSRect(origin: .zero, size: frame.size), scale: screen.backingScaleFactor)
        panel.contentView = view
        self.panel = panel; feedback = view; transferNoticeShowing = true
        view.showProgress(title: title)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hideTransferNotice() {
        guard transferNoticeShowing else { return }
        panel?.orderOut(nil); panel = nil; feedback = nil
        transferNoticeShowing = false
    }

    private func showToast(success: Bool, title: String) -> Bool {
        transferNoticeShowing = false
        panel?.orderOut(nil)
        removeDetachedToast() // two toasts never stack in the corner
        guard let screen = toastScreen ?? NSScreen.main else { return false }
        let frame = CaptureCardLayout.panelFrame(in: screen.visibleFrame)
        let panel = takePanel(&spareToast, frame: frame, allSpaces: true)
        let view = CaptureFeedbackView(frame: NSRect(origin: .zero, size: frame.size), scale: screen.backingScaleFactor)
        panel.contentView = view
        self.panel = panel
        feedback = view
        view.show(success: success, title: title, reduceMotion: reduceMotion)
        panel.alphaValue = 1
        // Never use makeKeyAndOrderFront, makeFirstResponder or NSApp.activate.
        panel.orderFrontRegardless()
        return true
    }

    @discardableResult
    private func startLanding(requestID: UInt64, destinationAXFrame: CGRect?, targetPID: pid_t?,
                              look: CaptureTileLook) -> Bool {
        guard !reduceMotion else { lastArrivalStatus = "reduced-motion"; return false }
        guard let destinationAXFrame else { lastArrivalStatus = "fallback-no-frame"; return false }
        guard let targetPID, targetPID > 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            lastArrivalStatus = "fallback-foreground"; return false
        }
        guard let image = thumbnail else {
            lastArrivalStatus = "fallback-no-thumbnail"; return false
        }
        let screens = NSScreen.screens
        let screenFrames = screens.map(\.frame)
        guard let plan = CaptureFlightGeometry.landing(
                destinationAXFrame: destinationAXFrame,
                imageSize: CGSize(width: image.width, height: image.height),
                screens: screenFrames, targetPID: targetPID,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                reduceMotion: reduceMotion),
              let selectedScreen = screens.first(where: { $0.frame == plan.screenFrame }) else {
            lastArrivalStatus = "fallback-geometry"; return false
        }
        clearFlight()
        let generation = state.generation
        // Synchronous: the event monitors and the workspace observer run on the main thread, and
        // hopping to the next tick left the copy over the next app for ~2 frames (2026-10-25).
        let cancel: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state.matches(requestID, generation: generation) else { return }
                self.cancelFlight()
            }
        }
        // Typing right after a toss is normal and leaves the jelly alone; a click elsewhere or a
        // scroll fades it; a click on the picture itself removes it at once (2026-10-25).
        let react: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.state.matches(requestID, generation: generation) else { return }
                var inTile = false
                if let tile = self.earlyTileAX, let primary = NSScreen.screens.first?.frame {
                    let p = NSEvent.mouseLocation
                    inTile = tile.contains(CGPoint(x: p.x, y: primary.maxY - p.y))
                }
                switch CaptureFlightInputPolicy.action(for: event.type, inTile: inTile) {
                case .ignore: break
                case .fade: self.fadeFlight()
                case .cancel: self.cancelFlight()
                }
            }
        }
        // These monitors exist only for the short landing decoration. Do not inspect key
        // content or swallow input; clicks, scrolling and typing cancel a stale
        // visual even when the user switches chats/windows within the same app.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        let flightStartedAt = ProcessInfo.processInfo.systemUptime
        // AX confirmation may have delayed previously queued input (including
        // our earlier paste). Only an interaction after this flight may cancel it.
        flightGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            if CaptureFlightEventAdmission.accepts(timestamp: event.timestamp, startedAt: flightStartedAt) { react(event) }
        }
        flightLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if CaptureFlightEventAdmission.accepts(timestamp: event.timestamp, startedAt: flightStartedAt) { react(event) }
            return event
        }
        guard flightGlobalMonitor != nil, flightLocalMonitor != nil else {
            clearFlight(); lastArrivalStatus = "fallback-monitor"; return false
        }
        flightApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in cancel() }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            clearFlight(); lastArrivalStatus = "fallback-foreground"; return false
        }
        guard NSScreen.screens.map(\.frame) == screenFrames else {
            clearFlight(); lastArrivalStatus = "fallback-geometry"; return false
        }
        // Patch style: sample the composer colour beside the chip first (read only, at most
        // 80 ms, only with Screen Recording already granted). Anything uncertain lands as extra.
        guard CaptureJelly.style == .patch else {
            showLanding(plan: plan, image: image, screen: selectedScreen, style: CaptureJelly.style,
                        patch: nil, look: look, requestID: requestID, generation: generation)
            return true
        }
        guard CGPreflightScreenCaptureAccess() else {
            showLanding(plan: plan, image: image, screen: selectedScreen, style: .extra,
                        patch: nil, look: look, requestID: requestID, generation: generation)
            patchStatus = "no-permission"
            return true
        }
        lastArrivalStatus = "sampling"
        CapturePatchSampler.sample(chipAX: destinationAXFrame, timeout: 0.08) { [weak self] color in
            guard let self, self.state.matches(requestID, generation: generation),
                  self.flightGlobalMonitor != nil, self.flightPanel == nil,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
                  NSScreen.screens.map(\.frame) == screenFrames else { return }
            self.patchStatus = color == nil ? "sample-uncertain" : "patched"
            self.showLanding(plan: plan, image: image, screen: selectedScreen,
                             style: color == nil ? .extra : .patch, patch: color, look: look,
                             requestID: requestID, generation: generation)
        }
        return true
    }

    private(set) var patchStatus = "off"

    private func showLanding(plan: CaptureLandingPlan, image: CGImage, screen: NSScreen,
                             style: CaptureJelly.Style, patch: CGColor?, look: CaptureTileLook,
                             requestID: UInt64, generation: UInt64) {
        let overlay = takePanel(&spareFlight, frame: plan.screenFrame, allSpaces: false)
        let view = CaptureFlightView(frame: CGRect(origin: .zero, size: plan.screenFrame.size),
                                     image: image, scale: screen.backingScaleFactor, look: look)
        overlay.contentView = view
        flightPanel = overlay
        flightView = view
        if CaptureJelly.blocksHover {
            // A small invisible window over the landing tile that takes the pointer for the
            // landing, so the app under it sees no hover (Claude grows a hovered card and shows
            // its ✕ at once). Non-activating, never key; a click on it cancels the flight like
            // any click (local monitor). Removed with the flight, and the hover comes back.
            let shieldFrame = CaptureJelly.hoverShieldFrame(tile: plan.tileFrame)
            let shield = Self.makePanel(frame: shieldFrame, allSpaces: false, prepared: false)
            shield.ignoresMouseEvents = false
            shield.backgroundColor = NSColor(white: 0, alpha: 0.004)
            shield.contentView = NSView(frame: CGRect(origin: .zero, size: shieldFrame.size))
            shield.orderFrontRegardless()
            hoverShield = shield
        }
        view.land(at: plan.tileFrame.offsetBy(dx: -plan.screenFrame.minX, dy: -plan.screenFrame.minY),
                  style: style, patch: patch)
        overlay.alphaValue = 1
        overlay.orderFrontRegardless()
        lastArrivalStatus = "landing"
        landingStartedAt = ProcessInfo.processInfo.systemUptime
        landingEndsAt = landingStartedAt! + CaptureJelly.params(style).duration
            + CaptureCardTiming.landingFade + 0.05
        // The overlay outlives nothing: once the picture has handed over to the chip, remove it.
        landingCleanup?.cancel()
        landingCleanup = Task { @MainActor [weak self] in
            let total = CaptureJelly.params(style).duration + CaptureCardTiming.landingFade + 0.05
            do { try await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000)) }
            catch { return }
            guard let self, self.state.matches(requestID, generation: generation), self.flightView === view else { return }
            if self.lastArrivalStatus == "landing" { self.lastArrivalStatus = "completed" }
            self.clearFlight()
        }
    }

    private func clearFlight() {
        landingCleanup?.cancel()
        landingCleanup = nil
        if let flightGlobalMonitor { NSEvent.removeMonitor(flightGlobalMonitor) }
        if let flightLocalMonitor { NSEvent.removeMonitor(flightLocalMonitor) }
        flightGlobalMonitor = nil
        flightLocalMonitor = nil
        if let flightApplicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(flightApplicationObserver)
        }
        flightApplicationObserver = nil
        hoverShield?.orderOut(nil)
        hoverShield = nil
        removePointerShield()
        flightPanel?.alphaValue = 0
        flightView?.clear()
        flightPanel?.orderOut(nil)
        flightPanel?.contentView = nil
        flightView = nil
        flightPanel = nil
    }

    private func retire(requestID: UInt64, delay: Double) {
        dismissal?.cancel()
        let generation = state.generation
        dismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, self.state.matches(requestID, generation: generation) else { return }
            if let feedback = self.feedback {
                feedback.fadeOut(reduceMotion: self.reduceMotion)
                do { try await Task.sleep(nanoseconds: UInt64(CaptureCardTiming.fadeOut * 1_000_000_000)) }
                catch { return }
                guard self.state.matches(requestID, generation: generation) else { return }
            }
            self.dismiss()
        }
    }
}

private final class CaptureFlightView: NSView {
    private let thumbnail = CALayer()
    private let picture = CALayer()    // card look only: the picture fitted inside the card
    private let patch = CALayer()
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(frame: NSRect, image: CGImage, scale: CGFloat, look: CaptureTileLook) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.contentsScale = scale
        thumbnail.contentsScale = scale
        thumbnail.masksToBounds = true
        thumbnail.cornerRadius = look.copyCornerRadius
        switch look {
        case .cover:
            thumbnail.contents = image
            thumbnail.contentsGravity = .resizeAspectFill
        case .card(let red, let green, let blue, _):
            // Opaque card colour, picture fitted inside the tile area (the copy's margin
            // is card colour too), exactly like the target draws it.
            thumbnail.backgroundColor = CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                                                blue: CGFloat(blue) / 255, alpha: 1)
            picture.contents = image
            picture.contentsGravity = .resizeAspect
            picture.contentsScale = scale
            thumbnail.addSublayer(picture)
        }
        patch.isHidden = true
        layer?.addSublayer(patch)
        layer?.addSublayer(thumbnail)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    // Only the picture: it hits the confirmed attachment already leaning and wobbles like
    // jelly (CaptureJelly), covering the real chip, then fades and hands over to it.
    // One keyframe timeline from impact; there is no separate approach to join.
    // Patch style: an opaque patch of the sampled composer colour hides the real chip, so the
    // picture may squash below and stretch narrower than it; both fade out together.
    func land(at tile: CGRect, style: CaptureJelly.Style, patch color: CGColor?) {
        let style = style == .patch && color == nil ? .extra : style
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // `margin` larger on every side, pinned at the tile's own bottom centre.
        let m = CaptureJelly.margin
        thumbnail.bounds = CGRect(origin: .zero, size: tile.insetBy(dx: -m, dy: -m).size)
        if CaptureJelly.pinsLeft(style) {
            thumbnail.anchorPoint = CGPoint(x: m / (tile.width + 2 * m), y: m / (tile.height + 2 * m))
            thumbnail.position = CGPoint(x: tile.minX, y: tile.minY)
        } else {
            thumbnail.anchorPoint = CGPoint(x: 0.5, y: m / (tile.height + 2 * m))
            thumbnail.position = CGPoint(x: tile.midX, y: tile.minY)
        }
        picture.frame = thumbnail.bounds.insetBy(dx: m, dy: m)
        thumbnail.opacity = 0
        if let color, style == .patch {
            patch.frame = tile.insetBy(dx: -1, dy: -1)
            patch.cornerRadius = CaptureJelly.cornerRadius + 1
            patch.backgroundColor = color
            patch.opacity = 0
            patch.isHidden = false
        }
        CATransaction.commit()
        let wobble = CaptureJelly.params(style).duration
        let total = wobble + CaptureCardTiming.landingFade
        let jelly = CAKeyframeAnimation(keyPath: "transform")
        jelly.values = CaptureJelly.keyframes(tile: tile.size, style: style).map { shape in
            var m = CATransform3DIdentity
            m.m11 = CGFloat(shape.a); m.m21 = CGFloat(shape.c)
            m.m22 = CGFloat(shape.d); m.m41 = CGFloat(shape.tx)
            return NSValue(caTransform3D: m)
        }
        jelly.duration = wobble
        let handover = CAKeyframeAnimation(keyPath: "opacity")
        handover.values = [1, 1, 0]
        handover.keyTimes = [0, NSNumber(value: wobble / total), 1]
        handover.duration = total
        let picture = CAAnimationGroup()
        picture.animations = [jelly, handover]
        picture.duration = total
        thumbnail.add(picture, forKey: "landing")
        if !patch.isHidden { patch.add(handover, forKey: "landing") }
    }

    // Moves the running copy onto a corrected tile frame at once (no animation of the move);
    // the bounce keeps going, since its keyframes are relative to the anchor.
    func retarget(tile: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let m = CaptureJelly.margin
        thumbnail.bounds = CGRect(origin: .zero, size: tile.insetBy(dx: -m, dy: -m).size)
        if thumbnail.anchorPoint.x < 0.5 {
            thumbnail.anchorPoint = CGPoint(x: m / (tile.width + 2 * m), y: m / (tile.height + 2 * m))
            thumbnail.position = CGPoint(x: tile.minX, y: tile.minY)
        } else {
            thumbnail.anchorPoint = CGPoint(x: 0.5, y: m / (tile.height + 2 * m))
            thumbnail.position = CGPoint(x: tile.midX, y: tile.minY)
        }
        picture.frame = thumbnail.bounds.insetBy(dx: m, dy: m)
        CATransaction.commit()
    }

    func clear() {
        thumbnail.removeAllAnimations()
        patch.removeAllAnimations()
        thumbnail.contents = nil
        picture.contents = nil
    }
}

// A detached landing's last steps: a touch fades the copy and drops its shields (once); `finish`,
// at the end of the bounce, removes everything (once); a touch after that does nothing.
@MainActor
final class CaptureDetachedTeardown {
    private let fade: () -> Void, remove: () -> Void
    private(set) var faded = false, removed = false
    init(fade: @escaping () -> Void, remove: @escaping () -> Void) { self.fade = fade; self.remove = remove }
    func touched() {
        guard !faded, !removed else { return }
        faded = true; fade()
    }
    func finish() {
        guard !removed else { return }
        removed = true; remove()
    }
}

// The pointer shield's content: a click or scroll on it removes the shield (that one event is
// not passed on); it never takes focus.
private final class CaptureShieldView: NSView {
    var onTouch: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onTouch?() }
    override func rightMouseDown(with event: NSEvent) { onTouch?() }
    override func otherMouseDown(with event: NSEvent) { onTouch?() }
    override func scrollWheel(with event: NSEvent) { onTouch?() }
}

private final class CaptureFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// The result toast in the Toss style (SettingsStyle palette, Hanken Grotesk):
// a drawn check or cross and one line of text, 280 x 56.
private final class CaptureFeedbackView: NSView {
    private let card = CALayer()
    private let mark = CAShapeLayer()
    private let title = CATextLayer()
    private var markIsSuccess = true
    private var markIsProgress = false

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    init(frame: NSRect, scale: CGFloat) {
        super.init(frame: frame)
        _ = SettingsStyle.fontsRegistered
        wantsLayer = true
        layer = CALayer()
        layer?.contentsScale = scale
        layer?.addSublayer(card)
        let m = CaptureCardLayout.shadowMargin
        card.frame = CGRect(x: m, y: m, width: CaptureCardLayout.width, height: CaptureCardLayout.height)
        card.cornerRadius = 12
        card.borderWidth = 1
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.18
        card.shadowRadius = 12
        card.shadowOffset = CGSize(width: 0, height: -3)
        title.contentsScale = scale
        title.truncationMode = .end
        title.frame = CGRect(x: 42, y: 19, width: 222, height: 18)
        title.font = SettingsStyle.sans(13, .medium)
        title.fontSize = 13
        card.addSublayer(title)
        mark.frame = CaptureCardLayout.markFrame
        mark.fillColor = nil
        mark.lineWidth = 1.6
        mark.lineCap = .round
        mark.lineJoin = .round
        card.addSublayer(mark)
        refreshColors()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            withoutActions {
                card.backgroundColor = SettingsStyle.background.cgColor
                card.borderColor = SettingsStyle.line.cgColor
                title.foregroundColor = SettingsStyle.ink.cgColor
                let colors = CaptureCardMarkColors.colors(progress: markIsProgress, success: markIsSuccess)
                mark.strokeColor = colors.stroke.cgColor
                mark.fillColor = colors.fill?.cgColor
            }
        }
    }

    func showProgress(title text: String) {
        markIsSuccess = true
        markIsProgress = true
        refreshColors()
        withoutActions {
            title.string = text
            title.isWrapped = true
            title.frame = CGRect(x: 42, y: text.contains("\n") ? 7 : 19, width: 222,
                                 height: text.contains("\n") ? 40 : 18)
            mark.path = CGPath(ellipseIn: CGRect(x: 5, y: 5, width: 5, height: 5), transform: nil)
            card.opacity = 1
        }
    }

    // Slides up 8 pt and fades in; the check (or cross) draws itself in.
    func show(success: Bool, title text: String, reduceMotion: Bool) {
        markIsSuccess = success
        markIsProgress = false
        refreshColors()
        withoutActions {
            title.string = text
            mark.path = Self.markPath(success: success, in: CGRect(origin: .zero, size: CaptureCardLayout.markFrame.size))
            card.opacity = 1
        }
        let duration = CaptureCardTiming.appear
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = duration
        card.add(appear, forKey: "appear")
        guard !reduceMotion else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = -8
        slide.toValue = 0
        slide.duration = duration
        slide.timingFunction = Self.ease
        card.add(slide, forKey: "slide")
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.25
        draw.beginTime = CACurrentMediaTime() + duration * 0.5
        draw.fillMode = .backwards
        draw.timingFunction = Self.ease
        mark.add(draw, forKey: "draw")
    }

    // Toss check/cross in the icon's line style, drawn in a 10 pt box centred in the slot (y-up).
    private static func markPath(success: Bool, in slot: CGRect) -> CGPath {
        let box = slot.insetBy(dx: 5, dy: 5)
        let path = CGMutablePath()
        if success {
            path.move(to: CGPoint(x: box.minX, y: box.minY + 4.5))
            path.addLine(to: CGPoint(x: box.minX + 3.6, y: box.minY + 0.5))
            path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - 0.5))
        } else {
            let cross = box.insetBy(dx: 1, dy: 1)
            path.move(to: CGPoint(x: cross.minX, y: cross.minY)); path.addLine(to: CGPoint(x: cross.maxX, y: cross.maxY))
            path.move(to: CGPoint(x: cross.maxX, y: cross.minY)); path.addLine(to: CGPoint(x: cross.minX, y: cross.maxY))
        }
        return path
    }

    func fadeOut(reduceMotion: Bool) {
        withoutActions { card.opacity = 0 }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = CaptureCardTiming.fadeOut
        card.add(fade, forKey: "fade")
        guard !reduceMotion else { return }
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = 0
        drop.toValue = -4
        drop.duration = CaptureCardTiming.fadeOut
        drop.timingFunction = CAMediaTimingFunction(name: .easeIn)
        card.add(drop, forKey: "retire")
    }

    func clear() {
        withoutActions { for item in [card, mark, title] { item.removeAllAnimations() } }
    }

    func disableMotion() {
        card.removeAnimation(forKey: "slide")
        card.removeAnimation(forKey: "retire")
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// Patch style only. Captures the thin strips beside the confirmed chip (never Toss's own
// panels, which are excluded from capture) and reports their agreed colour, or nil on any
// error, timeout, missing API or disagreement. The caller has checked Screen Recording.
@MainActor
enum CapturePatchSampler {
    static func sample(chipAX: CGRect, timeout: Double, done: @escaping (CGColor?) -> Void) {
        var finished = false
        let finish: (CGColor?) -> Void = { color in
            guard !finished else { return }
            finished = true
            done(color)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        guard #available(macOS 15.2, *) else { finish(nil); return }
        let rect = CapturePatchSample.captureRect(chipAX: chipAX)
        SCScreenshotManager.captureImage(in: rect) { image, _ in
            let color = image.flatMap { colour(of: $0, pointWidth: rect.width) }
            DispatchQueue.main.async { finish(color) }
        }
    }

    nonisolated private static func colour(of image: CGImage, pointWidth: CGFloat) -> CGColor? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, pointWidth > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn, let c = CapturePatchSample.agreedColor(CapturePatchSample.stripSamples(
            rgba: rgba, width: w, height: h, scale: CGFloat(w) / pointWidth)) else { return nil }
        return CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}

#if TOSS_RENDER
// Offscreen screenshots of the corner toast (scratch harness only).
@MainActor
func renderToastView(success: Bool, title: String) -> NSView {
    let view = CaptureFeedbackView(frame: NSRect(origin: .zero, size: CaptureCardLayout.panelSize), scale: 2)
    view.show(success: success, title: title, reduceMotion: true)
    return view
}
#endif

// The "on its way" dot is neutral grey: colour in Toss is only the green/red result mark
// (design rule, 2026-11-03). The result check/cross is stroked only, never filled.
enum CaptureCardMarkColors {
    static func colors(progress: Bool, success: Bool) -> (stroke: NSColor, fill: NSColor?) {
        if progress { return (SettingsStyle.muted, SettingsStyle.muted) }
        return (success ? SettingsStyle.ok : SettingsStyle.danger, nil)
    }
}
