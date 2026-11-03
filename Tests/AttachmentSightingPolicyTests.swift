import Foundation

// Pure label and scope checks. No AX calls or target application access.
@main enum AttachmentSightingPolicyTests {
    static func main() {
        var checks = 0
        func check(_ result: @autoclosure () -> Bool, _ message: String) {
            precondition(result(), message); checks += 1
        }
        let file = "iPad-0e74ef51-647d-4795-90b1-a5ec8ea28686.png"
        for label in [file, "Remove \(file)", "移除 1792378332002_\(file)", "削除「\(file)」", "\(file) "] {
            check(AttachmentSighting.namesFile(label, filename: file), "exact filename: \(label)")
        }
        for label in ["\(file).bak", "copy-\(file)", "wrong_\(file)", "12_\(file)", "\(file) and another.png"] {
            check(!AttachmentSighting.namesFile(label, filename: file), "substring must not trigger an early landing: \(label)")
        }
        check(!AttachmentSighting.namesFile("anything", filename: ""), "empty filename cannot match everything")
        let card = CGRect(x: 10, y: 20, width: 500, height: 300)
        check(AttachmentSighting.canAscend(role: "AXGroup", frame: card), "bounded card ancestor allowed")
        for role in ["AXApplication", "AXWindow", "AXWebArea", "AXScrollArea"] {
            check(!AttachmentSighting.canAscend(role: role, frame: card), "small window must not expose history: \(role)")
        }
        check(!AttachmentSighting.canAscend(role: "AXGroup", frame: nil), "missing geometry cannot bypass card bounds")
        check(!AttachmentSighting.canAscend(role: nil, frame: card), "unknown ancestor rejected")
        check(!AttachmentSighting.canAscend(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 500, height: 900)), "thread-size ancestor rejected")
        // Queued-press release (2026-10-28): wait for the previous tile to stop growing, not a fixed 0.65 s.
        let claudeFinal = CGSize(width: 173, height: 173)
        check(!AttachmentSighting.growthSettled(current: CGSize(width: 159, height: 159), previous: CGSize(width: 159, height: 159),
                                                expectedFinal: claudeFinal), "Claude card resting at 159 pt before growing is not settled")
        check(!AttachmentSighting.growthSettled(current: claudeFinal, previous: CGSize(width: 166, height: 166),
                                                expectedFinal: claudeFinal), "still moving: one read at the final size is not enough")
        check(AttachmentSighting.growthSettled(current: claudeFinal, previous: claudeFinal, expectedFinal: claudeFinal),
              "two reads at the remembered final size: settled")
        check(!AttachmentSighting.growthSettled(current: claudeFinal, previous: claudeFinal, expectedFinal: nil),
              "no known final size: never settles early")
        check(!AttachmentSighting.growthSettled(current: claudeFinal, previous: nil, expectedFinal: claudeFinal),
              "the first read alone is not settled")
        let codex = CGSize(width: 184, height: 183)
        check(AttachmentSighting.growthSettled(current: codex, previous: codex, expectedFinal: codex), "Codex tile settles on the second read")
        check(AttachmentSighting.releasesQueuedPress(landingAge: nil, tileSettled: false), "nothing landing: start at once")
        check(AttachmentSighting.releasesQueuedPress(landingAge: 0.05, tileSettled: true), "settled tile: no fixed wait")
        check(!AttachmentSighting.releasesQueuedPress(landingAge: 0.3, tileSettled: false), "growing tile holds the next press")
        check(AttachmentSighting.releasesQueuedPress(landingAge: 0.65, tileSettled: false), "0.65 s ceiling")
        var gate = AttachmentSighting.LandingSettleGate()
        check(gate.isSettled, "no landing yet: nothing to wait for")
        gate.begin(7)
        check(!gate.isSettled, "toss 7's tile is growing")
        gate.begin(9); gate.settle(7)
        check(!gate.isSettled, "a late settle from toss 7 cannot release toss 9")
        gate.settle(9)
        check(gate.isSettled, "toss 9's own settle releases the queue")
        print("Attachment sighting: \(checks) pure assertions passed; no application access.")
    }
}
