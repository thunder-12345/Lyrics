import XCTest
@testable import Lyrics

final class TransliteratorTests: XCTestCase {
    func testRomanizesCyrillicScript() {
        XCTAssertEqual(Transliterator.transliterate("Привет мир"), "Privet mir")
    }

    func testRomanizesJapaneseScript() {
        XCTAssertEqual(Transliterator.transliterate("こんにちは"), "kon'nichiha")
    }

    func testFoldsDiacriticsToPlainAscii() {
        // "café" round-trips through the Any-Latin transform unchanged in
        // script but should still lose the accent during ASCII folding.
        XCTAssertEqual(Transliterator.transliterate("café"), "cafe")
    }

    func testLeavesPlainAsciiTextUnchanged() {
        XCTAssertEqual(Transliterator.transliterate("namaste"), "namaste")
    }

    func testEmptyStringStaysEmpty() {
        XCTAssertEqual(Transliterator.transliterate(""), "")
    }

    func testLinesVariantPreservesTimeAndTransliteratesText() {
        let lines = [
            LRCLine(time: 1.0, text: "Привет"),
            LRCLine(time: 2.5, text: "мир")
        ]

        let result = Transliterator.transliterate(lines: lines)

        XCTAssertEqual(result, [
            LRCLine(time: 1.0, text: "Privet"),
            LRCLine(time: 2.5, text: "mir")
        ])
    }

    func testLinesVariantOnEmptyArrayReturnsEmptyArray() {
        XCTAssertEqual(Transliterator.transliterate(lines: []), [])
    }
}
