import Foundation

enum LyricsDisplayMode: String, CaseIterable, Identifiable {
    case original
    case transliterated
    case translated
    case combined

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original"
        case .transliterated: return "Transliterated"
        case .translated: return "Translated"
        case .combined: return "Combined"
        }
    }
}
