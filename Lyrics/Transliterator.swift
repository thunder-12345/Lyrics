import Foundation

/// Phonetic romanization (script conversion), not translation — meaning is
/// unchanged, only the script. Uses Apple's built-in ICU "Any-Latin"
/// transliterator, so this is free, offline, and effectively instant even
/// across a full song's lines; no network call, no caching needed.
enum Transliterator {
    static func transliterate(_ text: String) -> String {
        guard let latin = text.applyingTransform(.toLatin, reverse: false) else { return text }
        // ICU's Any-Latin keeps IAST-style diacritics (ā, ṁ, ō, ṭ, ḍ, ṣ...),
        // which read as more formal/academic than how people actually
        // casually romanize lyrics. Folding to plain ASCII reads much closer
        // to natural fan-style spelling and is easier to sing along to.
        return latin.folding(options: .diacriticInsensitive, locale: nil)
    }

    static func transliterate(lines: [LRCLine]) -> [LRCLine] {
        lines.map { LRCLine(time: $0.time, text: transliterate($0.text)) }
    }
}
