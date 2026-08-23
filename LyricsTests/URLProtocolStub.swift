import Foundation

/// Intercepts every request made through a `URLSession` configured with this
/// protocol registered, so network-backed clients (LRCLIB, Lyrics.ovh,
/// Gemini) can be tested against canned responses instead of real servers.
/// Each test sets `requestHandler` right before exercising the client under
/// test, then clears it in `tearDown` so stubs never leak between tests.
final class URLProtocolStub: URLProtocol {
    struct StubError: Error {}

    /// Returns (statusCode, body) for the given request, or throws to
    /// simulate a transport-level failure (no HTTP response at all).
    static var requestHandler: ((URLRequest) throws -> (Int, Data))?
    /// Captures the most recently intercepted request so tests can assert on
    /// what was actually sent (URL, headers, body) without a real server.
    static var lastRequest: URLRequest?
    /// `URLRequest.httpBody` on the request `URLProtocol` sees can come back
    /// nil even when the caller set it — URLSession is free to move a POST
    /// body into `httpBodyStream` instead. This normalizes both cases into
    /// one place so tests always find the body here.
    static var lastRequestBody: Data?

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        URLProtocolStub.lastRequest = request
        URLProtocolStub.lastRequestBody = Self.extractBody(from: request)

        guard let handler = URLProtocolStub.requestHandler else {
            client?.urlProtocol(self, didFailWithError: StubError())
            return
        }

        do {
            let (statusCode, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func extractBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}
