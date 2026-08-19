import Foundation

enum GeminiTranslationError: Error {
    case invalidResponse
    case lineCountMismatch
    case emptyInput
}

/// Batched, LLM-based translation of lyric text into English — one request
/// per song rather than per line, both to stay well within the free tier's
/// rate limit and because the model translates more coherently with
/// full-song context than it would translating each line in isolation.
final class GeminiTranslationClient {
    private static let model = "gemini-3.6-flash"
    private let session = URLSession.shared

    /// Translates each segment independently but in one request. The
    /// returned array is guaranteed either to throw or to be exactly
    /// `segments.count` long — callers must not trust a mismatched count,
    /// since that would desync translated text from the original timing.
    func translate(segments: [String]) async throws -> [String] {
        guard !segments.isEmpty else { throw GeminiTranslationError.emptyInput }
        let apiKey = try AppConfig.value(for: "GeminiAPIKey")

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.model):generateContent?key=\(apiKey)") else {
            throw GeminiTranslationError.invalidResponse
        }

        let body: [String: Any] = [
            "contents": [["parts": [["text": Self.buildPrompt(segments: segments)]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "ARRAY",
                    "items": ["type": "STRING"]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let fetchStartedAt = Date()
        let (data, response) = try await session.data(for: request)
        let ms = TimingLogger.elapsedMS(since: fetchStartedAt)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            TimingLogger.log("gemini_translate_failed ms=\(ms) segments=\(segments.count)")
            throw GeminiTranslationError.invalidResponse
        }

        guard let decoded = try? JSONDecoder().decode(GeminiResponse.self, from: data),
              let text = decoded.candidates.first?.content.parts.first?.text,
              let jsonData = text.data(using: .utf8),
              let translated = try? JSONDecoder().decode([String].self, from: jsonData) else {
            throw GeminiTranslationError.invalidResponse
        }

        guard translated.count == segments.count else {
            TimingLogger.log("gemini_translate_count_mismatch expected=\(segments.count) got=\(translated.count)")
            throw GeminiTranslationError.lineCountMismatch
        }

        TimingLogger.log("gemini_translate_ok ms=\(ms) segments=\(segments.count)")
        return translated
    }

    private static func buildPrompt(segments: [String]) -> String {
        let numbered = segments.enumerated()
            .map { "\($0.offset): \($0.element)" }
            .joined(separator: "\n")
        return """
        Translate the following song lyric lines into natural, idiomatic \
        English, preserving tone and meaning rather than translating \
        word-for-word. Return ONLY a JSON array of strings, exactly \
        \(segments.count) elements, one translated line per input line, in \
        the same order. Do not merge, split, number, or add commentary to \
        any line, even if an input line is short, blank, or repeats an \
        earlier one.

        \(numbered)
        """
    }
}

private struct GeminiResponse: Codable {
    let candidates: [Candidate]

    struct Candidate: Codable {
        let content: Content
    }

    struct Content: Codable {
        let parts: [Part]
    }

    struct Part: Codable {
        let text: String
    }
}
