import Foundation

/// A streamed chat completion.
///
/// ```swift
/// let stream = try await client.chatStream(request)
/// for try await chunk in stream {
///     print(chunk.content ?? "", terminator: "")
/// }
/// print(await stream.usage() ?? "no usage")
/// ```
///
/// Iterate it once. Stopping early, or cancelling the enclosing `Task`, tears the HTTP request
/// down — `URLSession.AsyncBytes` propagates the cancellation, so nothing keeps generating for a
/// reader that walked away.
public final class ChatStream: AsyncSequence, Sendable {
    public typealias Element = ChatChunk

    /// Correlation ids and rate-limit budget, available before the first frame.
    public let meta: ResponseMeta

    private let bytes: URLSession.AsyncBytes
    private let state = StreamState()

    init(bytes: URLSession.AsyncBytes, meta: ResponseMeta) {
        self.bytes = bytes
        self.meta = meta
    }

    /// Everything received so far.
    ///
    /// Populated as the stream runs, and **still populated on a stream that failed partway**,
    /// which is what makes a partial answer recoverable instead of lost.
    public func content() async -> String { await state.content }

    /// The chain of thought so far, assembled apart from ``content()``.
    public func reasoning() async -> String { await state.reasoning }

    /// The tool calls the model asked for, reassembled from fragments that are individually
    /// invalid JSON.
    ///
    /// Complete once the stream ends. A stream that stopped on `finish_reason == "length"`
    /// leaves `arguments` truncated and unparseable — check the finish reason before decoding.
    public func toolCalls() async -> [ToolCall] { await state.toolCalls }

    /// Why generation stopped, once it has.
    public func finishReason() async -> String? { await state.finishReason }

    /// Token accounting once the stream has ended.
    ///
    /// `nil` while running, and `nil` when the backend reported nothing to derive it from. A
    /// figure reconstructed from `timings` is marked ``Usage/estimated``.
    public func usage() async -> Usage? { await state.usage }

    public func makeAsyncIterator() -> Iterator {
        Iterator(lines: bytes.lines.makeAsyncIterator(), state: state, meta: meta)
    }

    public struct Iterator: AsyncIteratorProtocol {
        var lines: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator
        let state: StreamState
        let meta: ResponseMeta
        private var sawTerminator = false

        init(
            lines: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator, state: StreamState,
            meta: ResponseMeta
        ) {
            self.lines = lines
            self.state = state
            self.meta = meta
        }

        public mutating func next() async throws -> ChatChunk? {
            while let line = try await lines.next() {
                guard let event = SSE.decode(line: line) else { continue }
                if event.isDone {
                    sawTerminator = true
                    return nil
                }
                // Checked by the PRESENCE of a top-level `error` key, never by matching the
                // message text. The platform documents one string today and does not promise it
                // is the only one, so keying on the text would miss the next.
                if event.payload["error"] != nil {
                    let message =
                        event.payload["error"]?.stringValue
                        ?? String(describing: event.payload["error"]!)
                    throw AxoniumError.streamInterrupted(
                        message: message,
                        partialContent: await state.content,
                        requestID: meta.requestID,
                        traceID: meta.traceID)
                }
                return await state.absorb(event)
            }

            // The bytes ran out with no `[DONE]`. That is not a finished stream, it is a cut
            // one, and reporting it as a normal end would hand the caller a truncated answer
            // that looks complete.
            if !sawTerminator {
                throw AxoniumError.streamInterrupted(
                    message: "the stream ended without the [DONE] sentinel",
                    partialContent: await state.content,
                    requestID: meta.requestID,
                    traceID: meta.traceID)
            }
            return nil
        }
    }
}

/// The accumulator behind a stream, as an actor because the sequence is `Sendable` and a caller
/// may read `content()` from somewhere other than the loop consuming it.
public actor StreamState {
    private var accumulator = StreamAccumulator()

    var content: String { accumulator.content }
    var reasoning: String { accumulator.reasoning }
    var toolCalls: [ToolCall] { accumulator.toolCalls }
    var finishReason: String? { accumulator.finishReason }
    var usage: Usage? { accumulator.usage }

    func absorb(_ event: SSEEvent) -> ChatChunk { accumulator.absorb(event) }
}
