import ApplicationServices
import Foundation

// Early sighting of the new attachment (2026-10-25: start the jelly the moment the
// picture is seen, not after the full confirmation; the real tile otherwise shows for 2-4
// frames first). Visual only: the paste is still confirmed by the target's full readback,
// and the sound and ✓ toast wait for that. Reads only a bounded subtree around the composer,
// never the whole window, never writes, never focuses. Off unless jellyEarlyStart is set.
enum AttachmentSighting {
    static let defaultsKey = "jellyEarlyStart"
    static let ancestorLevels = 7          // from the composer up to the card that holds the tiles
    static let nodeBudget = 400            // Codex's composer card had ~60 elements; Claude's ~40
    static let maxCardHeight: CGFloat = 560 // composer cards measured 110-366 pt (+ a ~200 pt tile row); threads 900+
    static let interval = 0.01
    static let window = 1.5                // stop probing this long after the paste

    // The tile is the largest plausible frame among the elements labelled with the picture's file
    // name (Claude: the card button itself) and the images that contain such an element's centre
    // (Codex: the remove button sits on the image's corner). Nothing plausible: nil.
    static func tile(labelled: [CGRect], images: [CGRect]) -> CGRect? {
        func plausible(_ r: CGRect) -> Bool {
            r.minX.isFinite && r.minY.isFinite && r.width >= 40 && r.height >= 40 && r.width <= 600 && r.height <= 600
        }
        var candidates = labelled.filter(plausible)
        for hit in labelled {
            let centre = CGPoint(x: hit.midX, y: hit.midY)
            candidates += images.filter { plausible($0) && $0.contains(centre) }
        }
        return candidates.max { $0.width * $0.height < $1.width * $1.height }
    }

    // Two consecutive reads must agree before a frame is used: a tile that the app is still
    // animating in reports a smaller, changing frame (2026-10-25: Claude's copy was built on
    // a mid-animation frame and stayed 4-8 % too narrow).
    static func stable(_ previous: CGRect?, _ current: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        guard let previous else { return false }
        return abs(previous.minX - current.minX) <= tolerance && abs(previous.minY - current.minY) <= tolerance &&
            abs(previous.width - current.width) <= tolerance && abs(previous.height - current.height) <= tolerance
    }

    // The next slot in the attachment row, predicted before the paste from the tiles already
    // there: one tile width plus the measured gap to the right of the last tile. Only when at
    // least two tiles share the last row (so size and gap are measured, not assumed) and the
    // slot fits inside `rowRight`; anything else returns nil (the sighting decides instead).
    static func predictedSlot(tiles: [CGRect], rowRight: CGFloat) -> CGRect? {
        guard let bottom = tiles.map(\.maxY).max() else { return nil }
        let row = tiles.filter { abs($0.maxY - bottom) < 2 }.sorted { $0.minX < $1.minX }
        guard row.count >= 2, let last = row.last else { return nil }
        let previous = row[row.count - 2]
        let gap = last.minX - previous.maxX
        guard gap >= 0, gap <= 40, abs(last.width - previous.width) < 1, abs(last.height - previous.height) < 1 else { return nil }
        let slot = CGRect(x: last.maxX + gap, y: last.minY, width: last.width, height: last.height)
        return slot.maxX <= rowRight ? slot : nil
    }

    // What one app's last confirmed tiles looked like, so the first and second picture also get
    // a predicted slot (2026-10-25: the real tile was painted before AX showed it, and it
    // showed under the copy). Learned from Toss's own confirmed pastes, per app; only used while
    // the composer has the same width as when it was learned. Geometry only, no content.
    struct SlotMemory: Codable, Equatable {
        var width: CGFloat, height: CGFloat
        var composerWidth: CGFloat
        var firstDX: CGFloat?, firstDY: CGFloat?   // first tile, from the pre-paste text box's origin
        var gap: CGFloat?                          // between neighbouring tiles in a row
        // Growth after the tile is first read (2026-10-25: Claude's card is read at 160 pt and
        // then grows to 173 pt, bottom-left fixed, so the right edge showed beside the copy):
        // the size it settles at, and which share of the growth goes left / down.
        var finalWidth: CGFloat? = nil, finalHeight: CGFloat? = nil
        var growLeft: CGFloat? = nil, growDown: CGFloat? = nil
    }

    // The new tile has stopped growing: two reads in a row (~30 ms apart) give the same size, and
    // that size is the one it is known to end at (Codex: the confirmed size, its tiles never grow;
    // Claude: the remembered final card). Equal reads alone are not enough: Claude's card sits at
    // 159 pt for ~80 ms before it grows to 173 pt. Without a known final size it never settles
    // early, and the caller's ceiling applies.
    static func growthSettled(current: CGSize, previous: CGSize?, expectedFinal: CGSize?) -> Bool {
        guard let previous, let expectedFinal else { return false }
        let same = abs(current.width - previous.width) <= 0.5 && abs(current.height - previous.height) <= 0.5
        return same && current.width >= expectedFinal.width - 0.5 && current.height >= expectedFinal.height - 0.5
    }

    // Whose growth the queued-press release is waiting for. A late "settled" from an older toss's
    // follower must not release the queue for a newer toss whose tile is still growing.
    struct LandingSettleGate: Equatable {
        private(set) var owner: UInt64?
        private(set) var isSettled = true
        mutating func begin(_ id: UInt64) { owner = id; isSettled = false }
        mutating func settle(_ id: UInt64) { if id == owner { isSettled = true } }
    }

    // A queued press may start (and detach the previous landing) once that landing's tile has
    // settled, or after `ceiling` seconds of landing at most; at once when nothing is landing.
    static let queuedReleaseCeiling = 0.65
    static func releasesQueuedPress(landingAge: Double?, tileSettled: Bool,
                                    ceiling: Double = queuedReleaseCeiling) -> Bool {
        guard let landingAge else { return true }
        return tileSettled || landingAge >= ceiling
    }

    // `tile` as it will look once grown, if a growth is remembered; never smaller than `tile`.
    static func grown(_ tile: CGRect, memory: SlotMemory?) -> CGRect {
        guard let memory, let fw = memory.finalWidth, let fh = memory.finalHeight else { return tile }
        let w = max(tile.width, fw), h = max(tile.height, fh)
        let left = (memory.growLeft ?? 0) * (w - tile.width), down = (memory.growDown ?? 0) * (h - tile.height)
        return CGRect(x: tile.minX - left, y: tile.maxY + down - h, width: w, height: h)
    }

    // What a growth from `first` to `final` says about where the tile grows. Nil if it did not grow.
    static func growth(first: CGRect, final: CGRect) -> (left: CGFloat, down: CGFloat)? {
        let dw = final.width - first.width, dh = final.height - first.height
        guard dw > 0.5 || dh > 0.5, dw >= 0, dh >= 0, dw <= 60, dh <= 60 else { return nil }
        let left = dw > 0.5 ? min(1, max(0, (first.minX - final.minX) / dw)) : 0
        let down = dh > 0.5 ? min(1, max(0, (final.maxY - first.maxY) / dh)) : 0
        return (left, down)
    }
    static func memoryKey(_ app: String) -> String { "jellySlotMemory.\(app)" }

    static func loadMemory(_ app: String, defaults: UserDefaults = .standard) -> SlotMemory? {
        guard let data = defaults.data(forKey: memoryKey(app)) else { return nil }
        return try? JSONDecoder().decode(SlotMemory.self, from: data)
    }

    // After a confirmed paste: `composer` and `tiles` as read just before Cmd+V, `confirmed` the new tile.
    // `confirmed`: the new tile's settled frame; `first`: how it was first read, if it grew since.
    // Rows are grouped by their bottom edge (tiles of a row are bottom-aligned while one grows).
    static func learn(_ memory: SlotMemory?, composer: CGRect, tiles: [CGRect], confirmed: CGRect,
                      first: CGRect? = nil) -> SlotMemory? {
        guard confirmed.width >= 40, confirmed.height >= 40, confirmed.width <= 600, confirmed.height <= 600 else { return memory }
        var next = memory?.composerWidth == composer.width ? memory! :
            SlotMemory(width: 0, height: 0, composerWidth: composer.width)
        next.width = confirmed.width; next.height = confirmed.height
        if let first, let g = growth(first: first, final: confirmed) {
            next.finalWidth = confirmed.width; next.finalHeight = confirmed.height
            next.growLeft = g.left; next.growDown = g.down
        }
        if tiles.isEmpty {
            next.firstDX = confirmed.minX - composer.minX
            next.firstDY = confirmed.minY - composer.minY
        } else if let bottom = tiles.map(\.maxY).max(), abs(confirmed.maxY - bottom) < 2,
                  let last = tiles.filter({ abs($0.maxY - bottom) < 2 }).max(by: { $0.minX < $1.minX }) {
            let gap = confirmed.minX - last.maxX
            if gap >= 0, gap <= 40 { next.gap = gap }
        }
        return next
    }

    static func saveMemory(_ memory: SlotMemory, app: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(memory) { defaults.set(data, forKey: memoryKey(app)) }
    }

    // The slot from measured neighbours (two or more tiles), else from memory: right of a single
    // tile with the remembered gap, or the remembered first-tile place in an empty row.
    static func predictedSlot(tiles: [CGRect], rowRight: CGFloat, composer: CGRect?, memory: SlotMemory?) -> CGRect? {
        if let slot = predictedSlot(tiles: tiles, rowRight: rowRight) { return slot }
        guard let memory, let composer, abs(memory.composerWidth - composer.width) < 1 else { return nil }
        var slot: CGRect?
        if tiles.count == 1, let only = tiles.first, let gap = memory.gap {
            slot = CGRect(x: only.maxX + gap, y: only.minY, width: only.width, height: only.height)
        } else if tiles.isEmpty, let dx = memory.firstDX, let dy = memory.firstDY {
            slot = CGRect(x: composer.minX + dx, y: composer.minY + dy, width: memory.width, height: memory.height)
        }
        guard let slot, slot.maxX <= rowRight else { return nil }
        return slot
    }

    static func composerFrame(_ composer: AXUIElement) -> CGRect? { frame(composer) }

    // Free space between `tile` and the nearest tile above it that overlaps it horizontally.
    static func gapAbove(_ tile: CGRect, tiles: [CGRect]) -> CGFloat? {
        tiles.filter { $0.maxY <= tile.minY + 1 && $0.maxX > tile.minX && $0.minX < tile.maxX }
            .map { tile.minY - $0.maxY }.min()
    }

    // Before the paste: the tiles already in the composer (any attachment file, not only Toss's)
    // and the right edge of the composer area that holds them.
    static func existingTiles(composer: AXUIElement) -> (tiles: [CGRect], rowRight: CGFloat)? {
        guard let scan = scan(composer: composer, matching: { label in
            label.range(of: "\\S\\.(png|jpe?g|heic|gif|webp|tiff?|pdf)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }) else { return nil }
        var tiles: [CGRect] = []
        for hit in scan.labelled {
            guard let t = tile(labelled: [hit], images: scan.images),
                  !tiles.contains(where: { stable($0, t, tolerance: 1) }) else { continue }
            tiles.append(t)
        }
        return (tiles, scan.root.maxX)
    }

    // The exact unique filename, optionally preceded by Claude's numeric
    // upload ID or a localized action. A substring (name.png.bak / copy-name.png)
    // is not evidence of this capture, even for a visual-only early sighting.
    static func namesFile(_ label: String, filename: String) -> Bool {
        guard !filename.isEmpty else { return false }
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, "”\"」』)）".contains(last) { text.removeLast() }
        guard text.hasSuffix(filename) else { return false }
        var head = String(text.dropLast(filename.count))
        if head.hasSuffix("_") {
            head.removeLast()
            let digits = head.reversed().prefix { $0.isASCII && $0.isNumber }
            guard (6...20).contains(digits.count) else { return false }
            head.removeLast(digits.count)
        }
        guard let boundary = head.last else { return true }
        return boundary.isWhitespace || "“\"「『(（:：".contains(boundary)
    }

    static func canAscend(role: String?, frame: CGRect?) -> Bool {
        guard let role, !["AXApplication", "AXWindow", "AXWebArea", "AXScrollArea"].contains(role),
              let frame, frame.width > 0, frame.height > 0, frame.height <= maxCardHeight else { return false }
        return true
    }

    // One bounded read. Returns the tile's AX frame (top-left origin) or nil.
    static func probe(composer: AXUIElement, filename: String) -> CGRect? {
        guard let scan = scan(composer: composer, matching: { namesFile($0, filename: filename) }), !scan.labelled.isEmpty else { return nil }
        return tile(labelled: scan.labelled, images: scan.images)
    }

    private static func scan(composer: AXUIElement, matching: (String) -> Bool)
        -> (labelled: [CGRect], images: [CGRect], root: CGRect)? {
        var root = composer
        for _ in 0..<ancestorLevels {
            guard let parent = element(root, kAXParentAttribute) else { break }
            // Stop below the thread: in a long Codex chat the 7th ancestor is the whole
            // conversation (1,683 nodes), and the bounded scan ran out before the tiles.
            guard canAscend(role: string(parent, kAXRoleAttribute), frame: frame(parent)) else { break }
            root = parent
        }
        guard let rootFrame = frame(root) else { return nil }
        var queue = [root], index = 0
        var labelled: [CGRect] = [], images: [CGRect] = []
        while index < queue.count, index < nodeBudget {
            let node = queue[index]; index += 1
            AXUIElementSetMessagingTimeout(node, 0.03)
            let role = string(node, kAXRoleAttribute)
            if role == "AXButton" || role == "AXImage" || role == "AXGroup" {
                let labels = [string(node, kAXDescriptionAttribute), string(node, kAXTitleAttribute)].compactMap { $0 }
                if labels.contains(where: matching), let f = frame(node) { labelled.append(f) }
                else if role == "AXImage", let f = frame(node) { images.append(f) }
            }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
               let children = value as? [AXUIElement] { queue += children }
        }
        return (labelled, images, rootFrame)
    }

    private static func element(_ base: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(base, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func string(_ base: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(base, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    fileprivate static func frame(_ base: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(base, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(base, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

// Probes on its own queue until it sees the tile, the window ends, or it is cancelled.
final class AttachmentSighter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Toss.attachment-sighting", qos: .userInteractive)
    private var generation = 0

    // sighted(rect, seconds after start, seconds the frame took to settle after first being seen).
    func start(composer: AXUIElement, filename: String, sighted: @escaping @Sendable (CGRect, Double, Double) -> Void) {
        queue.async { [self] in
            generation += 1
            let token = generation, started = ProcessInfo.processInfo.systemUptime
            var previous: CGRect?, firstSeen: Double?
            func tick() {
                guard token == generation else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                guard elapsed < AttachmentSighting.window else { return }
                if let rect = AttachmentSighting.probe(composer: composer, filename: filename) {
                    if firstSeen == nil { firstSeen = elapsed }
                    if AttachmentSighting.stable(previous, rect) {
                        generation += 1
                        sighted(rect, elapsed, elapsed - (firstSeen ?? elapsed))
                        return
                    }
                    previous = rect
                } else {
                    previous = nil
                }
                queue.asyncAfter(deadline: .now() + AttachmentSighting.interval) { tick() }
            }
            tick()
        }
    }

    func cancel() { queue.async { [self] in generation += 1 } }

    // After the confirmation: re-read the tile every `interval` for `duration` and report each
    // larger frame (the copy grows with it), then the frame it settled at and when (seconds).
    // `settled` fires once, as soon as AttachmentSighting.growthSettled holds (see expectedFinal).
    func follow(composer: AXUIElement, filename: String, from first: CGRect, duration: Double = 0.6,
                interval: Double = 0.03, expectedFinal: CGSize? = nil,
                grew: @escaping @Sendable (CGRect) -> Void,
                settled: @escaping @Sendable () -> Void = {},
                done: @escaping @Sendable (CGRect, Double) -> Void) {
        queue.async { [self] in
            generation += 1
            let token = generation, started = ProcessInfo.processInfo.systemUptime
            var current = first, settledAt = 0.0
            var lastRead: CGSize?, reportedSettled = false
            func tick() {
                guard token == generation else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let read = AttachmentSighting.probe(composer: composer, filename: filename)
                if let rect = read, rect.width > current.width + 0.5 || rect.height > current.height + 0.5 {
                    current = rect; settledAt = elapsed
                    grew(rect)
                }
                if !reportedSettled, let rect = read,
                   AttachmentSighting.growthSettled(current: rect.size, previous: lastRead, expectedFinal: expectedFinal) {
                    reportedSettled = true
                    settled()
                }
                lastRead = read?.size
                guard elapsed < duration else {
                    if !reportedSettled { settled() }
                    done(current, settledAt); return
                }
                queue.asyncAfter(deadline: .now() + interval) { tick() }
            }
            tick()
        }
    }
}
