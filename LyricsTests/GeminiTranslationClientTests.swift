import XCTest
@testable import Lyrics

final class GeminiTranslationClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.requestHandler = nil
        URLProtocolStub.lastRequest = nil
        URLProtocolStub.lastRequestBody = nil
        super.tearDown()
    }

    private func makeClient(apiKey: String = "test-key") -> GeminiTranslationClient {
        GeminiTranslationClient(session: URLProtocolStub.makeSession(), apiKeyProvider: { apiKey })
    }

    private func geminiResponseBody(translated: [String]) -> Data {
        let inner = try! JSONEncoder().encode(translated)
        let innerText = String(data: inner, encoding: .utf8)!
        let payload: [String: Any] = [
            "candidates": [[
                "content": ["parts": [["text": innerText]]]
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testThrowsEmptyInputWithoutMakingANetworkCall() async throws {
        URLProtocolStub.requestHandler = { _ in XCTFail("Should not make a network call for empty input"); return (200, Data()) }
        let client = makeClient()

        do {
            _ = try await client.translate(segments: [])
            XCTFail("Expected GeminiTranslationError.emptyInput")
        } catch GeminiTranslationError.emptyInput {
            // expected
        }
    }

    func testReturnsTranslatedLinesInOrder() async throws {
        URLProtocolStub.requestHandler = { _ in
            (200, self.geminiResponseBody(translated: ["hola", "mundo"]))
        }
        let client = makeClient()

        let result = try await client.translate(segments: ["hello", "world"])

        XCTAssertEqual(result, ["hola", "mundo"])
    }

    func testThrowsLineCountMismatchWhenResponseCountDiffersFromInput() async throws {
        URLProtocolStub.requestHandler = { _ in
            (200, self.geminiResponseBody(translated: ["only one"]))
        }
        let client = makeClient()

        do {
            _ = try await client.translate(segments: ["hello", "world"])
            XCTFail("Expected GeminiTranslationError.lineCountMismatch")
        } catch GeminiTranslationError.lineCountMismatch {
            // expected
        }
    }

    func testThrowsInvalidResponseOnNon200Status() async throws {
        URLProtocolStub.requestHandler = { _ in (500, Data()) }
        let client = makeClient()

        do {
            _ = try await client.translate(segments: ["hello"])
            XCTFail("Expected GeminiTranslationError.invalidResponse")
        } catch GeminiTranslationError.invalidResponse {
            // expected
        }
    }

    func testThrowsInvalidResponseOnUnparseableBody() async throws {
        URLProtocolStub.requestHandler = { _ in (200, Data("not json".utf8)) }
        let client = makeClient()

        do {
            _ = try await client.translate(segments: ["hello"])
            XCTFail("Expected GeminiTranslationError.invalidResponse")
        } catch GeminiTranslationError.invalidResponse {
            // expected
        }
    }

    func testPropagatesApiKeyProviderFailureWithoutMakingANetworkCall() async throws {
        struct KeyError: Error {}
        URLProtocolStub.requestHandler = { _ in XCTFail("Should not make a network call when the API key is unavailable"); return (200, Data()) }
        let client = GeminiTranslationClient(session: URLProtocolStub.makeSession(), apiKeyProvider: { throw KeyError() })

        do {
            _ = try await client.translate(segments: ["hello"])
            XCTFail("Expected KeyError to propagate")
        } catch is KeyError {
            // expected
        }
    }

    func testRequestBodyIncludesNumberedLinesAndJsonArraySchema() async throws {
        URLProtocolStub.requestHandler = { _ in (200, self.geminiResponseBody(translated: ["a", "b"])) }
        let client = makeClient()

        _ = try await client.translate(segments: ["first line", "second line"])

        let sentBody = try XCTUnwrap(URLProtocolStub.lastRequestBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let promptText = try XCTUnwrap(parts.first?["text"] as? String)

        XCTAssertTrue(promptText.contains("0: first line"))
        XCTAssertTrue(promptText.contains("1: second line"))

        let generationConfig = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        XCTAssertEqual(generationConfig["responseMimeType"] as? String, "application/json")
        let schema = try XCTUnwrap(generationConfig["responseSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "ARRAY")
    }

    func testSendsApiKeyAsQueryParameter() async throws {
        URLProtocolStub.requestHandler = { _ in (200, self.geminiResponseBody(translated: ["a"])) }
        let client = makeClient(apiKey: "my-secret-key")

        _ = try await client.translate(segments: ["hello"])

        let url = try XCTUnwrap(URLProtocolStub.lastRequest?.url)
        XCTAssertTrue(url.absoluteString.contains("key=my-secret-key"))
    }
}
