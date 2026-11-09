// Ashley's approved family: decimal MB, selected from the validated attachment
// bytes (after PNG encoding), never transfer duration or an earlier queued capture.
// Real iPad captures use <2 MB, 2-5 MB, 5-8 MB and >=8 MB (2026-11-07).
enum SuccessSound: String, CaseIterable {
    case small = "Toss-Success"
    case medium = "Toss-Success-Medium"
    case large = "Toss-Success-Large"
    case extraLarge = "Toss-Success-XLarge"

    static func forFileSize(_ bytes: Int?) -> SuccessSound {
        guard let bytes, bytes > 0 else { return .small }
        switch bytes {
        case ..<2_000_000: return .small
        case ..<5_000_000: return .medium
        case ..<8_000_000: return .large
        default: return .extraLarge
        }
    }
}
