import Foundation

// Pure lifecycle and geometry assertions. Does not construct NSApplication, windows,
// layers, decode screenshots, or contact any app or device.
@main struct CaptureAnimationTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }
        var state = CaptureAnimationState()
        check(state.requestID == nil && state.phase == nil, "initially hidden")
        check(!state.finish(1, success: true), "no unsolicited success")
        state.begin(1)
        let first = state.generation
        check(state.phase == .capturing, "begin is only waiting")
        check(!state.acceptsImage(1, generation: first), "no image before captured")
        check(!state.captured(2), "wrong request cannot load an image")
        check(state.captured(1), "current receipt may load")
        check(!state.captured(1), "duplicate receipt ignored")
        check(state.acceptsImage(1, generation: first), "current load accepted")
        check(!state.finish(2, success: true), "wrong success ignored")
        check(state.finish(1, success: true), "native confirmation accepted")
        check(state.phase == .confirmed, "confirmed distinct from captured")
        check(!state.acceptsImage(1, generation: first), "late decode after success ignored")
        check(!state.finish(1, success: true), "duplicate success does not reset timers")
        check(!state.finish(1, success: false), "late failure cannot overwrite success")
        state.dismiss()
        check(!state.matches(1, generation: first), "old dismissal cannot touch a new panel")
        check(state.requestID == nil && state.phase == nil, "dismiss forgets request")
        state.begin(1)
        let reused = state.generation
        check(reused != first, "even reused numeric IDs have a different generation")
        check(state.captured(1), "reused ID current receipt accepted")
        check(!state.acceptsImage(1, generation: first), "old decode cannot leak across transactions")
        check(state.acceptsImage(1, generation: reused), "new decode accepted")
        check(state.finish(1, success: false), "failure accepted")
        check(state.phase == .failed, "failure never claims success")
        check(!state.acceptsImage(1, generation: reused), "late decode after failure ignored")
        state.begin(3)
        let pending = state.generation
        check(!state.matches(1, generation: reused), "old fade cannot retire replacement")
        check(state.finish(3, success: true), "native success does not wait for a thumbnail")
        check(!state.captured(3), "receipt after terminal callback ignored")
        state.dismiss()
        check(!state.matches(3, generation: pending), "cancel invalidates terminal timer")
        state.begin(4)
        let cancelled = state.generation
        check(state.captured(4), "begin fourth decode")
        state.dismiss()
        check(!state.acceptsImage(4, generation: cancelled), "cancel invalidates in-flight decoder")
        check(!state.finish(4, success: true), "cancel rejects late confirmation")

        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let left = CGRect(x: -1280, y: -100, width: 1280, height: 1024)
        let target = CGRect(x: 500, y: 600, width: 120, height: 120)
        let landscape = CGSize(width: 2388, height: 1668)
        func plan(_ target: CGRect? = target,
                  image: CGSize = landscape, screens: [CGRect] = [primary],
                  pid: Int32? = 42, foreground: Int32? = 42,
                  reduceMotion: Bool = false) -> CaptureLandingPlan? {
            CaptureFlightGeometry.landing(destinationAXFrame: target,
                imageSize: image, screens: screens, targetPID: pid,
                frontmostPID: foreground, reduceMotion: reduceMotion)
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.000_001 }
        let firstPlan = plan()!
        check(firstPlan.screenFrame == primary, "confirmed geometry stays on the same screen")
        check(near(firstPlan.destinationFrame.midY, 240), "AX top-left is converted with primary maxY")
        check(firstPlan.tileFrame == CGRect(x: 500, y: 180, width: 120, height: 120),
              "landing copy covers the whole confirmed tile, so no second layer shows")
        check(near(firstPlan.destinationFrame.midX, 560), "AX x coordinate is preserved")
        check(near(firstPlan.destinationFrame.width / firstPlan.destinationFrame.height,
                   landscape.width / landscape.height), "landscape image is never stretched")
        let portrait = plan(image: CGSize(width: 1668, height: 2388))!
        check(near(portrait.destinationFrame.height, 120), "portrait fits destination height")
        check(portrait.destinationFrame.width < 120, "portrait is not cropped to a square")
        check(plan(nil) == nil, "missing verified destination falls back")
        check(plan(pid: nil) == nil && plan(foreground: nil) == nil, "missing process identity falls back")
        check(plan(pid: 0) == nil && plan(pid: -1) == nil, "invalid process identity rejected")
        check(plan(foreground: 43) == nil, "foreground change suppresses landing")
        check(plan(reduceMotion: true) == nil, "reduced motion never lands")
        check(plan(screens: []) == nil, "missing screen geometry falls back")
        check(plan(screens: [primary, primary]) == nil, "overlapping screen identity is ambiguous")
        check(plan(CGRect(x: 1600, y: 100, width: 120, height: 120), screens: [primary, right])?.screenFrame == right,
              "landing happens on the chip's own screen, wherever the corner card is")
        check(plan(CGRect(x: 1400, y: 100, width: 120, height: 120), screens: [primary, right]) == nil,
              "destination spanning displays is rejected")
        let rightPlan = plan(CGRect(x: 1600, y: 50, width: 120, height: 120), screens: [primary, right])!
        check(rightPlan.screenFrame == right && near(rightPlan.destinationFrame.midY, 790),
              "secondary display conversion still uses PRIMARY maxY, not desktop union height")
        let leftPlan = plan(CGRect(x: -1100, y: 500, width: 120, height: 120), screens: [primary, left])!
        check(leftPlan.screenFrame == left && near(leftPlan.destinationFrame.midX, -1040),
              "negative display origins are handled without clamping")
        for invalid in [CGRect.zero, CGRect(x: 1, y: 1, width: -2, height: 4),
                        CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10),
                        CGRect(x: 0, y: CGFloat.nan, width: 10, height: 10)] {
            check(plan(invalid) == nil, "invalid target geometry rejected")
        }
        check(plan(image: .zero) == nil, "empty bitmap dimensions rejected")
        check(plan(image: CGSize(width: CGFloat.infinity, height: 10)) == nil, "nonfinite image dimensions rejected")
        check(plan(CGRect(x: 500, y: -5000, width: 120, height: 120)) == nil, "offscreen target rejected")
        check(CaptureFlightGeometry.aspectFit(CGSize(width: 100, height: 100), in: target) == target,
              "equal-aspect handoff uses the exact target frame")
        // The corner holds only the result toast, 16 pt from the right/bottom edges.
        let visible = CGRect(x: -1920, y: 73, width: 1920, height: 1000)
        let panel = CaptureCardLayout.panelFrame(in: visible)
        let card = CaptureCardLayout.card(in: panel)
        check(card.maxX == visible.maxX - 16 && card.minY == visible.minY + 16,
              "toast sits 16 pt from the right and bottom, also on a negative-origin display")
        check(card.size == CGSize(width: 280, height: 56), "toast is 280 x 56")
        check(panel.height == CaptureCardLayout.height + 2 * CaptureCardLayout.shadowMargin,
              "panel is just the toast plus its shadow; no room left for a picture card")
        check(CaptureCardLayout.markFrame.maxX < 42 && CaptureCardLayout.markFrame.maxY <= CaptureCardLayout.height,
              "mark sits left of the title inside the toast")
        check(CaptureCardTiming.appear > 0 && CaptureCardTiming.appear <= 0.25, "toast appears in one short motion")
        // Jelly landing: every style starts at the impact (deformed and moving), is a damped
        // spring, and ends at exactly the chip's size and shape.
        typealias Style = CaptureJelly.Style
        let degrees = 180 / Double.pi
        let tile = CGSize(width: 84, height: 60)
        check(UserDefaults.standard.string(forKey: "jellyLandingStyle") != nil || CaptureJelly.style == .extra,
              "extra is the default style")
        check(CaptureCardTiming.landing == CaptureJelly.params().duration &&
              CaptureCardTiming.landingTotal == CaptureCardTiming.landing + 0.15,
              "the fade starts only after the current style has settled")
        func samples(_ style: Style) -> [Double] {
            let d = CaptureJelly.params(style).duration
            return (0...4000).map { d * Double($0) / 4000 }
        }
        func peaks(_ values: [Double], _ times: [Double]) -> [(t: Double, v: Double)] {
            var out: [(t: Double, v: Double)] = []
            for i in 1..<(values.count - 1) where abs(values[i]) >= abs(values[i - 1]) && abs(values[i]) > abs(values[i + 1]) {
                out.append((times[i], values[i]))
            }
            return out
        }
        func steady(_ swings: [(t: Double, v: Double)], ratio: Double) -> Bool {
            zip(swings, swings.dropFirst()).allSatisfy { a, b in
                let r: Double = abs(b.v) / abs(a.v)
                return a.v * b.v < 0 && abs(r - ratio) < 0.07
            }
        }
        // Raster check on the real geometry: every point of the tile (edges and corners) lies
        // inside the transformed copy, rounded corners and all.
        // pinLeft: the anchor is the tile's bottom-left corner instead of its bottom centre.
        func tileCovered(_ s: CaptureJelly.Shape, pinLeft: Bool = false) -> Bool {
            let m = Double(CaptureJelly.margin), r = Double(CaptureJelly.cornerRadius)
            let w = Double(tile.width), h = Double(tile.height)
            let left = pinLeft ? 0 : -w / 2
            let (minX, maxX, minY, maxY) = (left - m, left + w + m, -m, h + m)
            for i in 0...42 { for j in 0...30 {
                let px = left + w * Double(i) / 42, py = h * Double(j) / 30
                let y = py / s.d, x = (px - s.tx - s.c * y) / s.a
                guard x >= minX - 1e-9, x <= maxX + 1e-9, y >= minY - 1e-9, y <= maxY + 1e-9 else { return false }
                let cx = min(max(x, minX + r), maxX - r), cy = min(max(y, minY + r), maxY - r)
                if (x - cx) * (x - cx) + (y - cy) * (y - cy) > r * r + 1e-9 { return false }
            } }
            return true
        }
        check(CaptureJelly.margin >= CaptureJelly.cornerRadius * (1 - 1 / 2.squareRoot()),
              "the margin covers the copy's rounded corners, so the tile's corners never peek out")
        for style in [Style.lean, .drop, .both, .extra, .patch] {
            let p = CaptureJelly.params(style)
            let times = samples(style)
            let s0 = CaptureJelly.scale(at: 0, style: style), lean0 = CaptureJelly.lean(at: 0, style: style)
            let s1 = CaptureJelly.scale(at: 1.0 / 60, style: style), lean1 = CaptureJelly.lean(at: 1.0 / 60, style: style)
            check((s0.x != 1 || s0.y != 1 || lean0 != 0) && (s1 != s0 || lean1 != lean0),
                  "\(style): frame 0 is the impact, already deformed and still moving")
            check(CaptureJelly.shape(at: p.duration, tile: tile, style: style) == CaptureJelly.Shape(a: 1, c: 0, d: 1, tx: 0),
                  "\(style): ends at the chip's exact size and shape")
            check(CaptureJelly.keyframes(tile: tile, style: style).first == CaptureJelly.shape(at: 0, tile: tile, style: style),
                  "\(style): keyframes start at the impact")
            check(CaptureJelly.keyframes(tile: tile, style: style).count >= Int(p.duration * 100),
                  "\(style): sampled at least 100 times a second (no straight segments)")
            if p.body != .free {
                let frames = (0...300).map { CaptureJelly.shape(at: p.duration * Double($0) / 300, tile: tile, style: style) }
                check(frames.allSatisfy { tileCovered($0, pinLeft: CaptureJelly.pinsLeft(style)) },
                      "\(style): no pixel of the real chip shows beside the copy")
                check(times.allSatisfy { let s = CaptureJelly.scale(at: $0, style: style); return s.x >= 1 - 1e-12 && s.y >= 1 - 1e-12 },
                      "\(style): never smaller than the chip in either axis")
            }
            if p.bounce != nil && p.body != .upright {
                let spread = times.map { let s = CaptureJelly.scale(at: $0, style: style); return s.x - s.y }
                let swings = peaks(spread, times).filter { abs($0.v) >= 0.01 }
                check(steady(swings, ratio: p.ratio), "\(style): wide and tall alternate, each about \(p.ratio)x the last")
            }
            if p.lean != nil {
                let leans = times.map { CaptureJelly.lean(at: $0, style: style) }
                let swings = peaks(leans, times).filter { abs($0.v) * degrees >= 0.5 }
                check(swings.first!.v < 0, "\(style): the first lean is to the left")
                check(steady(swings, ratio: p.ratio), "\(style): the lean swings left/right, each about \(p.ratio)x the last")
            }
        }
        func leanPeak(_ style: Style) -> Double { samples(style).map { abs(CaptureJelly.lean(at: $0, style: style)) }.max()! * degrees }
        // Horizontal: a 15-18 degree lean with at least 5 swings.
        check(leanPeak(.lean) > 15 && leanPeak(.lean) < 18, "horizontal leans 15-18 degrees (\(leanPeak(.lean)))")
        // Vertical / combined: tall at contact, compressed to the chip's height while spreading.
        for style in [Style.drop, .both] {
            let s = samples(style).map { CaptureJelly.scale(at: $0, style: style) }
            check(s[0].y > 1.2, "\(style): lands stretched tall")
            check(s.contains { $0.y < 1.01 && $0.x > 1.2 }, "\(style): compresses to the chip's height, about 1.22 wide")
        }
        check(samples(.drop).allSatisfy { CaptureJelly.lean(at: $0, style: .drop) == 0 }, "vertical never leans")
        check(leanPeak(.both) > 14 && leanPeak(.both) < 16, "combined leans about 15 degrees (\(leanPeak(.both)))")
        // Extra (14:56, more bounce; 2026-10-25 video: the bulge covered the
        // neighbouring tile): pinned at the bottom-left, the width grows at most 4 % (below the
        // gap to the next tile), no lean, and the whole bounce is in the height.
        let extraTimes = samples(.extra)
        let extra = extraTimes.map { CaptureJelly.scale(at: $0, style: .extra) }
        check(CaptureJelly.params(.extra).duration == 1.6, "extra settles in 1.6 s")
        check(CaptureJelly.pinsLeft(.extra) && !CaptureJelly.pinsLeft(.both), "extra is pinned at the tile's bottom-left")
        check(extra.allSatisfy { $0.x >= 1 && $0.x <= 1 + CaptureJelly.uprightWidthCap + 1e-12 },
              "extra never grows sideways more than 4 % (never reaches the next tile)")
        check(184 * CaptureJelly.uprightWidthCap + Double(CaptureJelly.margin) < 11 &&
              173 * CaptureJelly.uprightWidthCap + Double(CaptureJelly.margin) < 11,
              "the right edge stays inside the gap after a Codex (184 pt) or Claude (173 pt) tile")
        check(samples(.extra).allSatisfy { CaptureJelly.lean(at: $0, style: .extra) == 0 }, "extra does not lean")
        check(extra[0].y > 1.33, "extra lands stretched about 1.37 tall (\(extra[0].y))")
        let heights = extra.map { $0.y - 1 }
        var heightPeaks: [(t: Double, v: Double)] = []
        for i in 1..<(heights.count - 1) where heights[i] >= heights[i - 1] && heights[i] > heights[i + 1] {
            heightPeaks.append((extraTimes[i], heights[i]))
        }
        let firstSettle = extraTimes.indices.first { extra[$0].y < 1.005 }!
        check(extraTimes[firstSettle] < 0.13, "extra comes down to the tile's height right after impact")
        check(heightPeaks.first.map { $0.v > 0.18 } == true, "then springs up again, about 1.20 tall (\(heightPeaks.first!))")
        let tallSwings = heightPeaks.filter { $0.v >= 0.01 }
        check(tallSwings.count >= 4, "extra: at least 4 visible upward rebounds after the impact (\(tallSwings.count))")
        check(zip(tallSwings, tallSwings.dropFirst()).allSatisfy { $1.v < $0.v * 0.7 }, "each rebound is clearly smaller than the last")
        let period = tallSwings[1].t - tallSwings[0].t
        check(period > 0.30 && period < 0.34, "extra: a full bounce about 0.32 s, slow enough to follow (\(period))")
        // Patch: true squash below and stretch narrower than the chip, keeping its volume.
        let patch = samples(.patch).map { CaptureJelly.scale(at: $0, style: .patch) }
        check(patch.allSatisfy { abs($0.x * $0.y - 1) < 1e-9 }, "patch keeps its volume")
        check(patch.contains { $0.y < 0.76 && $0.x > 1.3 }, "patch crushes to about 0.74 tall / 1.35 wide")
        check(patch.contains { $0.y > 1.2 && $0.x < 0.84 }, "patch stretches to about 1.23 tall with a narrow waist")
        // Early sighting (off by default): the tile is found from the elements labelled with the
        // picture's name, using the real geometry measured on 2026-10-24.
        check(AttachmentSighting.defaultsKey == "jellyEarlyStart" && !UserDefaults.standard.bool(forKey: "jellyEarlyStart"),
              "early start is off unless jellyEarlyStart is set")
        let codexRemove = CGRect(x: 744, y: 677, width: 25, height: 24), codexImage = CGRect(x: 582, y: 680, width: 184, height: 183)
        let otherImage = CGRect(x: 387, y: 680, width: 184, height: 183)
        check(AttachmentSighting.tile(labelled: [codexRemove], images: [otherImage, codexImage]) == codexImage,
              "Codex: the tile is the image under the new picture's remove button, not a neighbour")
        let claudeCard = CGRect(x: 1025, y: 714, width: 173, height: 174), claudeRemove = CGRect(x: 1180, y: 703, width: 30, height: 29)
        check(AttachmentSighting.tile(labelled: [claudeCard, claudeRemove], images: []) == claudeCard,
              "Claude: the tile is the card button labelled with the file name")
        check(AttachmentSighting.tile(labelled: [codexRemove], images: []) == nil, "only a tiny button seen: no tile, no early start")
        check(AttachmentSighting.tile(labelled: [CGRect(x: 0, y: 0, width: 1200, height: 900)], images: []) == nil,
              "an implausibly large element is never taken as the tile")
        // A frame counts only when two reads agree (a tile still animating in is ignored).
        let seen = CGRect(x: 1025, y: 714, width: 173, height: 174)
        check(!AttachmentSighting.stable(nil, seen), "a first sighting alone is never used")
        check(AttachmentSighting.stable(seen, seen.offsetBy(dx: 0.3, dy: -0.2)), "two matching reads: stable")
        check(!AttachmentSighting.stable(seen.insetBy(dx: 7, dy: 7), seen), "a tile still growing in (smaller) is not stable")
        // Predicted slot: one width plus the measured gap right of the last tile, only with two
        // tiles in the last row and only if it fits (Codex: 184 x 183 tiles, 11 pt apart).
        let t1 = CGRect(x: 582, y: 680, width: 184, height: 183), t2 = CGRect(x: 777, y: 680, width: 184, height: 183)
        check(AttachmentSighting.predictedSlot(tiles: [t1, t2], rowRight: 1600) == CGRect(x: 972, y: 680, width: 184, height: 183),
              "Codex: the next slot is exactly where the third tile landed (x 972)")
        check(AttachmentSighting.predictedSlot(tiles: [t2, t1], rowRight: 1600) != nil, "tile order does not matter")
        check(AttachmentSighting.predictedSlot(tiles: [t1], rowRight: 1600) == nil, "one tile: gap unknown, no prediction")
        check(AttachmentSighting.predictedSlot(tiles: [], rowRight: 1600) == nil, "no tiles: no prediction")
        check(AttachmentSighting.predictedSlot(tiles: [t1, t2], rowRight: 1100) == nil, "the slot would not fit the row (wraps): no prediction")
        let wrapped = CGRect(x: 582, y: 870, width: 184, height: 183)
        check(AttachmentSighting.predictedSlot(tiles: [t1, t2, wrapped], rowRight: 1600) == nil,
              "a single tile on a new row: no prediction")
        check(AttachmentSighting.predictedSlot(tiles: [t1, CGRect(x: 777, y: 680, width: 120, height: 183)], rowRight: 1600) == nil,
              "tiles of different sizes: no prediction")
        // Slot memory (2026-10-25): learned from Toss's own confirmed pastes, so the first and the
        // learned2 picture also get a slot before the app paints anything.
        let box = CGRect(x: 553, y: 878, width: 551, height: 66)
        let learned1 = AttachmentSighting.learn(nil, composer: box, tiles: [], confirmed: t1)
        check(learned1 == AttachmentSighting.SlotMemory(width: 184, height: 183, composerWidth: 551, firstDX: 29, firstDY: -198, gap: nil),
              "first tile: size and place relative to the pre-paste text box")
        let learned2 = AttachmentSighting.learn(learned1, composer: box, tiles: [t1], confirmed: t2)
        check(learned2?.gap == 11 && learned2?.firstDX == 29, "learned2 tile: the gap is learned, the first place kept")
        check(AttachmentSighting.learn(learned2, composer: box, tiles: [], confirmed: CGRect(x: 0, y: 0, width: 20, height: 20)) == learned2,
              "an implausible frame teaches nothing")
        check(AttachmentSighting.learn(learned2, composer: box.insetBy(dx: 50, dy: 0), tiles: [t1], confirmed: t2)?.firstDX == nil,
              "a resized composer starts a fresh memory")
        check(AttachmentSighting.predictedSlot(tiles: [], rowRight: 1600, composer: box, memory: learned2) == t1,
              "empty row: the remembered first place")
        check(AttachmentSighting.predictedSlot(tiles: [], rowRight: 1600, composer: box.offsetBy(dx: 0, dy: 40), memory: learned2)
              == t1.offsetBy(dx: 0, dy: 40), "the first place follows the text box")
        check(AttachmentSighting.predictedSlot(tiles: [t1], rowRight: 1600, composer: box, memory: learned2) == t2,
              "one tile: right of it with the remembered gap")
        check(AttachmentSighting.predictedSlot(tiles: [], rowRight: 1600, composer: box.insetBy(dx: 20, dy: 0), memory: learned2) == nil,
              "different composer width: memory not used")
        check(AttachmentSighting.predictedSlot(tiles: [], rowRight: 1600, composer: box, memory: learned1.map {
              var m = $0; m.firstDX = nil; return m }) == nil, "nothing remembered for an empty row: no prediction")
        check(AttachmentSighting.predictedSlot(tiles: [t1], rowRight: 900, composer: box, memory: learned2) == nil,
              "a remembered slot that would not fit the row: no prediction")
        check(AttachmentSighting.predictedSlot(tiles: [t1, t2], rowRight: 1600, composer: box, memory: nil) == CGRect(x: 972, y: 680, width: 184, height: 183),
              "two measured tiles still win over memory")
        let mdomain = "local.toss.slot-memory-tests.\(UUID().uuidString)"
        let mdefaults = UserDefaults(suiteName: mdomain)!
        AttachmentSighting.saveMemory(learned2!, app: "claude", defaults: mdefaults)
        check(AttachmentSighting.loadMemory("claude", defaults: mdefaults) == learned2 && AttachmentSighting.loadMemory("codex", defaults: mdefaults) == nil,
              "memory persists per app")
        mdefaults.removePersistentDomain(forName: mdomain)
        // Growth (2026-10-25): Claude's card is first read at 160 x 159 and settles at 173 x 172,
        // bottom-left fixed. Learned once, then the copy starts at the final size.
        let early = CGRect(x: 1100, y: 700, width: 160, height: 159)
        let settled = CGRect(x: 1100, y: 686, width: 173, height: 173)   // same bottom (859), same left
        let g = AttachmentSighting.growth(first: early, final: settled)
        check(g != nil && g!.left == 0 && g!.down == 0, "grows right and up: bottom-left anchored")
        check(AttachmentSighting.growth(first: settled, final: settled) == nil, "no growth, nothing learned")
        let grownMemory = AttachmentSighting.learn(nil, composer: box, tiles: [], confirmed: settled, first: early)
        check(grownMemory?.finalWidth == 173 && grownMemory?.finalHeight == 173 && grownMemory?.growLeft == 0,
              "growth is remembered with the settled size")
        let predictedFinal = AttachmentSighting.grown(early, memory: grownMemory)
        check(predictedFinal == settled, "with memory, the first read becomes the settled frame at once")
        check(AttachmentSighting.grown(settled, memory: grownMemory) == settled, "already grown: unchanged (idempotent)")
        check(AttachmentSighting.grown(early, memory: nil) == early, "no memory: unchanged")
        // Every intermediate frame of a bottom-left growth is inside the copy built from memory.
        for step in 0...13 {
            let k = CGFloat(step)
            let mid = CGRect(x: 1100, y: 700 - k, width: 160 + k, height: 159 + k)
            check(CaptureTileLook.coverFrame(predictedFinal, claude: true).contains(mid), "growth step \(step) is covered")
        }
        let centred = AttachmentSighting.growth(first: early, final: early.insetBy(dx: -6.5, dy: -6.5))
        check(centred.map { abs($0.left - 0.5) < 0.01 && abs($0.down - 0.5) < 0.01 } == true, "centred growth is recognised too")
        // Rows are grouped by their bottom edge: a growing tile beside a settled one is in the same row.
        let rowLearn = AttachmentSighting.learn(grownMemory, composer: box, tiles: [settled],
                                                confirmed: CGRect(x: 1285, y: 700, width: 160, height: 159))
        check(rowLearn?.gap == 12, "the gap is learned even while the new tile is still small")
        check(AttachmentSighting.predictedSlot(tiles: [settled, CGRect(x: 1285, y: 700, width: 160, height: 159)], rowRight: 1800) == nil,
              "tiles of different sizes still give no measured prediction")
        // Codex tiles do not grow: nothing remembered, nothing changes.
        check(AttachmentSighting.learn(nil, composer: box, tiles: [], confirmed: t1, first: t1)?.finalWidth == nil,
              "Codex: no growth recorded")
        // Input during a landing (2026-10-25): typing leaves it, a click elsewhere or a scroll
        // fades it, a click on the picture removes it at once.
        check(CaptureFlightInputPolicy.action(for: .keyDown, inTile: false) == .ignore, "typing after a toss keeps the jelly")
        check(CaptureFlightInputPolicy.action(for: .keyDown, inTile: true) == .ignore, "typing never cuts it")
        check(CaptureFlightInputPolicy.action(for: .scrollWheel, inTile: false) == .fade, "scroll fades")
        check(CaptureFlightInputPolicy.action(for: .leftMouseDown, inTile: false) == .fade, "click elsewhere fades")
        check(CaptureFlightInputPolicy.action(for: .leftMouseDown, inTile: true) == .cancel, "click on the picture removes it at once")
        check(CaptureFlightInputPolicy.action(for: .rightMouseDown, inTile: true) == .cancel, "right click on the picture too")
        check(CaptureFlightInputPolicy.fadeDuration <= 0.2, "the fade is short")
        // Claude paints outside its AX frame: the copy covers 6 pt more on every side there only.
        check(CaptureTileLook.coverFrame(t1, claude: true) == t1.insetBy(dx: -6, dy: -6), "Claude: +6 pt cover on every side")
        check(CaptureTileLook.coverFrame(t1, claude: false) == t1, "Codex: exact tile")
        let centre = CGPoint(x: t1.midX, y: t1.midY)
        check(CaptureTileLook.coverFrame(t1, claude: true, pointer: centre, hoverExtra: 0) == t1.insetBy(dx: -6, dy: -6),
              "hover extra off (default until measured): the plain 6 pt cover")
        let hovered = CaptureTileLook.coverFrame(t1, claude: true, pointer: centre, hoverExtra: 10)
        check(hovered == CGRect(x: t1.minX - 6, y: t1.minY - 16, width: t1.width + 22, height: t1.height + 22),
              "Claude hovered: 10 pt more toward the top and right")
        check(hovered.minX == t1.minX - 6 && hovered.maxY == t1.maxY + 6, "the bottom-left corner stays where the jelly is pinned")
        let capped = CaptureTileLook.coverFrame(t1, claude: true, pointer: centre, hoverExtra: 10, gapAbove: 12)
        check(capped.minY == t1.minY - 11 && capped.maxY == t1.maxY + 6 && capped.width == t1.width + 22,
              "the top never reaches the row above: at most gap - 1 pt")
        check(CaptureTileLook.coverFrame(t1, claude: true, pointer: CGPoint(x: t1.maxX + 40, y: t1.midY), hoverExtra: 10)
              == t1.insetBy(dx: -6, dy: -6), "pointer elsewhere: no hover extra")
        check(CaptureTileLook.coverFrame(t1, claude: false, pointer: centre, hoverExtra: 10) == t1,
              "Codex does not grow on hover")
        let row2 = CGRect(x: 582, y: 875, width: 184, height: 183)
        check(AttachmentSighting.gapAbove(row2, tiles: [t1, t2]) == 12, "gap to the tile above")
        check(AttachmentSighting.gapAbove(t2, tiles: [t1]) == nil, "a tile beside is not above")
        // Hover shield: covers the tile and a corner ✕ reaching 16 pt out; off unless switched on.
        check(CaptureJelly.hoverShieldFrame(tile: t1) == t1.insetBy(dx: -16, dy: -16), "shield covers the tile and its corner button")
        check(CaptureJelly.pointerShieldRadius >= 16 && CaptureJelly.pointerShieldLifetime <= 3,
              "pointer shield: small and short-lived")
        check(CaptureJelly.blockHoverKey == "jellyBlockHover" && CaptureTileLook.hoverExtraKey == "jellyClaudeHoverExtra",
              "stable switch names")
        // Tile look: Codex is covered by the picture; Claude in dark mode is a dark card with the
        // picture fitted inside, measured 2026-10-24; light-mode Claude stays covered (unmeasured).
        check(CaptureTileLook.forTarget(claude: false, darkAppearance: true) == .cover, "Codex tile: picture covers it")
        check(CaptureTileLook.forTarget(claude: true, darkAppearance: true) == .card(red: 25, green: 25, blue: 25, cornerRadius: 15),
              "Claude dark tile: dark card, 15 pt corners")
        check(CaptureTileLook.forTarget(claude: true, darkAppearance: false) == .cover, "Claude light: no guessed colour")
        let cardLook = CaptureTileLook.forTarget(claude: true, darkAppearance: true)
        check(cardLook.copyCornerRadius == 15 + CaptureJelly.margin,
              "the card copy's outline is concentric with the tile's rounded corners, margin all round")
        // Claude's AX rect is the card itself: the recorded button frame equals the on-screen tile.
        let claudeButton = CGRect(x: 1025, y: 714, width: 173, height: 174)
        let claudeTileOnScreen = CGRect(x: 1025, y: 715, width: 172, height: 172)
        check(abs(claudeButton.minX - claudeTileOnScreen.minX) <= 1 && abs(claudeButton.maxY - claudeTileOnScreen.maxY) <= 1.5 &&
              abs(claudeButton.width - claudeTileOnScreen.width) <= 1, "Claude's attachment button frame is the tile (within 1.5 pt)")
        // Patch colour: only a unanimous sample counts; anything else falls back to extra.
        let grey: (r: UInt8, g: UInt8, b: UInt8) = (40, 40, 42)
        check(CapturePatchSample.agreedColor(Array(repeating: grey, count: 24)).map { $0 == grey } == true,
              "a uniform gap gives its exact colour")
        check(CapturePatchSample.agreedColor(Array(repeating: grey, count: 23) + [(200, 200, 200)]) == nil,
              "one disagreeing pixel (text, border, another chip) means no patch")
        check(CapturePatchSample.agreedColor(Array(repeating: grey, count: 5)) == nil, "too few samples means no patch")
        let chip = CGRect(x: 500, y: 300, width: 84, height: 60)
        let rect = CapturePatchSample.captureRect(chipAX: chip)
        check(rect.minX < chip.minX && rect.maxX > chip.maxX && rect.minY > chip.minY && rect.maxY < chip.maxY,
              "the capture spans the chip's middle band and the gaps on both sides only")
        var rgba = [UInt8](repeating: 255, count: 20 * 2 * 4)   // 20 x 2 px, scale 1
        for y in 0..<2 { for x in [0, 1, 2, 17, 18, 19] { let i = (y * 20 + x) * 4; rgba[i] = 40; rgba[i + 1] = 40; rgba[i + 2] = 42 } }
        let strips = CapturePatchSample.stripSamples(rgba: rgba, width: 20, height: 2, scale: 1)
        check(strips.count == 12 && strips.allSatisfy { $0 == grey }, "only the strips beside the chip are sampled, not the chip")
        check(!CaptureFlightEventAdmission.accepts(timestamp: 99.99, startedAt: 100),
              "queued input or paste predating flight cannot cancel it")
        check(CaptureFlightEventAdmission.accepts(timestamp: 100, startedAt: 100),
              "interaction at the start boundary is admitted")
        check(CaptureFlightEventAdmission.accepts(timestamp: 100.1, startedAt: 100),
              "new interaction during flight cancels it")
        check(!CaptureFlightEventAdmission.accepts(timestamp: .nan, startedAt: 100), "invalid input timestamp rejected")
        check(!CaptureFlightEventAdmission.accepts(timestamp: .infinity, startedAt: 100), "nonfinite input timestamp rejected")
        check(!CaptureFlightEventAdmission.accepts(timestamp: 100, startedAt: .nan), "invalid start timestamp rejected")
        check(!CaptureFlightEventAdmission.accepts(timestamp: 100, startedAt: 0), "missing start timestamp rejected")
        // A detached landing (queued press, 2026-10-28) has no input monitor: a touch on its shield
        // fades it once, the end of the bounce removes everything once.
        MainActor.assumeIsolated {
            var fades = 0, removals = 0
            let teardown = CaptureDetachedTeardown(fade: { fades += 1 }, remove: { removals += 1 })
            teardown.touched(); teardown.touched()
            check(fades == 1 && removals == 0, "a touch on a detached shield fades the copy once and frees the pointer")
            teardown.finish(); teardown.finish(); teardown.touched()
            check(fades == 1 && removals == 1, "the bounce's end removes the detached copy exactly once")
            let untouched = CaptureDetachedTeardown(fade: { fades += 1 }, remove: { removals += 1 })
            untouched.finish()
            check(fades == 1 && removals == 2 && untouched.removed && !untouched.faded, "untouched copy is removed at its end without fading")
        }
        // Progress dot is neutral grey (no colour beyond the result mark); result marks are never filled.
        let progressColors = CaptureCardMarkColors.colors(progress: true, success: true)
        check(progressColors.stroke == SettingsStyle.muted && progressColors.fill == SettingsStyle.muted, "progress dot is neutral grey")
        check(progressColors.stroke != SettingsStyle.ok && progressColors.fill != SettingsStyle.ok, "progress never uses the green result colour")
        check(CaptureCardMarkColors.colors(progress: false, success: true).stroke == SettingsStyle.ok, "success mark stays green")
        check(CaptureCardMarkColors.colors(progress: false, success: false).stroke == SettingsStyle.danger, "failure mark stays red")
        check(CaptureCardMarkColors.colors(progress: false, success: true).fill == nil, "result mark is not filled after a progress dot")
        print("CaptureAnimation: \(count) pure assertions passed; no UI created.")
    }
}
