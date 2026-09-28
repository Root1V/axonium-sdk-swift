import Foundation

/// Serves the corpus's recorded bytes to the real `URLSession`.
///
/// A `URLProtocol` rather than a fake session, so what is under test is the actual client: its
/// real request building, its real header reading, its real `URLSession.bytes` streaming. A stub
/// injected below `URLSession` would skip exactly the layer most likely to be wrong.
///
/// **Every stub belongs to a session, and sessions do not see each other.** A `URLProtocol`
/// subclass is a type, so its storage is inevitably global — and Swift Testing runs suites in
/// parallel. The first version keyed stubs by path alone, and two suites promptly answered each
/// other's requests: a stream test read another suite's fixture and failed for a reason that had
/// nothing to do with it. Each session now carries an id in a header and can only reach its own
/// stubs, which removes the race rather than hiding it behind serialisation.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let sessionHeader = "X-Stub-Session"

    struct Stub: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
        /// Sent a frame at a time, so the client's SSE parsing meets a stream and not one blob.
        var isEventStream = false
    }

    /// One test's stubs and the requests it received.
    final class Session: @unchecked Sendable {
        let id: String
        private let lock = NSLock()
        private var stubs: [String: Stub] = [:]
        private var recorded: [Recorded] = []

        struct Recorded: Sendable {
            var path: String
            var headers: [String: String]
            var body: Data?
        }

        init() {
            id = UUID().uuidString
            StubProtocol.register(self)
        }

        deinit { StubProtocol.unregister(id) }

        func stub(path: String, _ stub: Stub) {
            lock.lock()
            defer { lock.unlock() }
            stubs[path] = stub
        }

        /// A token response good enough for any test that is not about tokens.
        func stubToken() {
            stub(
                path: "/oauth2/token",
                .init(
                    status: 200, headers: [:],
                    body: Data(
                        #"{"access_token":"h.e30.s","token_type":"Bearer","expires_in":300}"#.utf8)
                ))
        }

        func lookup(_ path: String) -> Stub? {
            lock.lock()
            defer { lock.unlock() }
            return stubs[path]
        }

        func record(_ entry: Recorded) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(entry)
        }

        var requests: [Recorded] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func requests(to path: String) -> [Recorded] { requests.filter { $0.path == path } }

        /// A `URLSessionConfiguration` wired to this session and no other.
        var configuration: URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            configuration.httpAdditionalHeaders = [StubProtocol.sessionHeader: id]
            return configuration
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: Session] = [:]

    fileprivate static func register(_ session: Session) {
        lock.lock()
        defer { lock.unlock() }
        sessions[session.id] = session
    }

    fileprivate static func unregister(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions[id] = nil
    }

    private static func session(for request: URLRequest) -> Session? {
        guard let id = request.value(forHTTPHeaderField: sessionHeader) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        // httpBody is nil for a body set via a stream, which URLSession does for larger uploads;
        // reading both keeps the recorded request honest.
        let body = request.httpBody ?? request.httpBodyStream.map(Self.drain)

        guard let session = Self.session(for: request) else {
            return fail("the request carried no \(Self.sessionHeader), so no stubs could be found")
        }
        session.record(.init(path: path, headers: request.allHTTPHeaderFields ?? [:], body: body))

        guard let stub = session.lookup(path) else {
            return fail("no stub registered for \(path)")
        }

        var headers = stub.headers
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = stub.isEventStream ? "text/event-stream" : "application/json"
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if stub.isEventStream {
            for frame in Self.frames(stub.body) {
                client?.urlProtocol(self, didLoad: frame)
            }
        } else {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fail(_ message: String) {
        client?.urlProtocol(
            self,
            didFailWithError: NSError(
                domain: "StubProtocol", code: 404,
                userInfo: [NSLocalizedDescriptionKey: message]))
    }

    /// Splits an SSE body on the blank-line separator, keeping it, so each `data:` arrives as its
    /// own delivery rather than the whole file at once.
    private static func frames(_ data: Data) -> [Data] {
        let separator = Data("\n\n".utf8)
        var frames: [Data] = []
        var rest = data
        while let range = rest.range(of: separator) {
            frames.append(rest[..<range.upperBound])
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { frames.append(rest) }
        return frames
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(contentsOf: buffer[..<read])
        }
        return data
    }
}
