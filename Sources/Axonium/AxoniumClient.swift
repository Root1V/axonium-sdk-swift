import Foundation

/// A client for the Prometheus inference platform.
///
/// **Which credential it may hold depends on whose it is, not on where it runs.** Guide §2.7 was
/// rewritten at revision `2026-10-01` and the criterion moved: a credential identifies *whoever
/// pays for consumption*. Model grants and billing rows are keyed to a `client_id`, so a credential
/// is an account rather than a key.
///
/// - **Your own credential must never ship inside your app.** A copy on every user's device is a
///   copy of the identity that holds your grants and pays your invoice, and one leak exposes all of
///   it. Hand this client a ``TokenProvider`` backed by a service you run.
/// - **Your user's own credential may live on their device, Keychain included.** The principal, the
///   grants and the bill are theirs; a leak costs them their own account and nothing else. This is
///   the "bring your own key" shape and it is supported, not tolerated.
///
/// ```swift
/// // Your credential, your backend: the app never sees a secret.
/// let client = try AxoniumClient(
///     configuration: .init(gatewayBaseURL: "https://gateway.example"),
///     tokenProvider: MyBackendTokenProvider())
///
/// let answer = try await client.chat(.init(model: "qwen3-0.6b", messages: [.user("hola")]))
/// print(answer.content ?? "")
/// ```
///
/// ```swift
/// // The user's own credential, out of their Keychain. Also correct, and also an App Store app.
/// let client = try AxoniumClient(configuration: .init(
///     gatewayBaseURL: "https://gateway.example",
///     clientID: theirID, clientSecret: theirSecret))
/// ```
///
/// **One credential per client, not per device**, so the same secret on their Mac and their iPhone
/// is the normal case rather than a leak. Revocation is per client.
///
/// **And credentials are issued by a human administrator, always** — there is no registration
/// endpoint and none planned, because issuing one opens a billing account. So *no credential yet*
/// is where every new user starts: treat it as a first-class state in the app, not an error.
///
/// ``TokenProvider`` is the whole seam, and it is why nothing about how a token was obtained can
/// become a breaking change to this package's API later.
///
/// `Sendable` and safe to share. One instance per process is the intended shape: the token is
/// cached inside it, and a second client means a second token and a second refresh.
public final class AxoniumClient: Sendable {
    public let configuration: AxoniumConfiguration
    private let session: URLSession
    private let tokens: any TokenProvider

    /// - Parameter tokenProvider: supply one to run in governed mode, where this SDK never sees
    ///   a client secret. Omit it and credentials from the configuration are used.
    public init(
        configuration: AxoniumConfiguration, tokenProvider: (any TokenProvider)? = nil
    ) throws {
        try configuration.validate(hasExternalTokenProvider: tokenProvider != nil)
        self.configuration = configuration
        let session = Transport.makeSession(configuration)
        self.session = session
        self.tokens =
            tokenProvider
            ?? ClientCredentialsTokenProvider(configuration: configuration, session: session)
    }

    /// The scope the platform actually granted, once a token has been obtained.
    public var grantedScope: [String] {
        get async { await tokens.grantedScope }
    }

    // MARK: - catalog

    /// The models this token may call.
    ///
    /// **Not "every deployed model", and not since `PRM-167`.** This was the platform's one
    /// public route and returned the whole catalog. It now requires a token and answers exactly
    /// what ``modelsMine()`` answers — the two are aliases, and neither is preferable.
    ///
    /// **An empty list means this token holds no `model:<id>` grants, not that the platform has
    /// no models.** Those are different facts and only an operator can tell them apart: ask for
    /// the grant rather than concluding the deployment is empty. Access was always
    /// deny-by-default; what changed is that discovery stopped being allow-all.
    ///
    /// This doc used to call it the public catalog and the honest connectivity check. Neither is
    /// true now: the platform closed it on 2026-09-29, and ``modelsMine()`` is what belongs
    /// behind a "test connection" button — it proves the gateway answers, the credential works,
    /// and there is something this caller may actually send. `GET /health` proves only that a
    /// process replied.
    public func models() async throws -> ModelList {
        let response = try await send(method: "GET", path: "/v1/models", body: nil, options: .init())
        return ModelList.decode(response.body ?? [:], meta: response.meta)
    }

    /// The models this token may call. An alias of ``models()`` since `PRM-167`.
    ///
    /// Kept because it is documented and callers use it. It exists because ``models()`` used to
    /// be the full public catalog and a token had no other way to find out what it could call.
    ///
    /// Worth calling once at startup and caching, rather than discovering access model by model
    /// through failed requests — and it is what lets a `403` say which scope is missing.
    public func modelsMine() async throws -> ModelList {
        let response = try await send(
            method: "GET", path: "/v1/models/mine", body: nil, options: .init())
        return ModelList.decode(response.body ?? [:], meta: response.meta)
    }

    // MARK: - chat

    /// A chat completion.
    public func chat(
        _ request: ChatRequest, idempotencyKey: String? = nil, instance: String? = nil
    ) async throws -> ChatCompletion {
        try request.validate()
        var options = CallOptions()
        options.idempotencyKey = idempotencyKey
        options.instance = instance
        options.model = request.model
        let response = try await send(
            method: "POST", path: "/v1/chat/completions",
            body: request.wireForm(stream: false), options: options)
        return ChatCompletion.decode(response.body ?? [:], meta: response.meta)
    }

    /// A streamed chat completion.
    ///
    /// Cancelling the enclosing `Task`, or simply stopping iteration, tears down the HTTP request.
    ///
    /// **A rejection arriving instead of the `200` is thrown before the first frame**, as an
    /// ordinary ``AxoniumError/api(_:)``. Setting `stream: true` does not change the error
    /// contract, and the gateway reads the engine's status before committing the stream headers —
    /// so an SDK must not assume streaming implies success. A failure *after* the stream has
    /// begun cannot use a status and arrives as ``AxoniumError/streamInterrupted(message:partialContent:requestID:traceID:)``.
    public func chatStream(
        _ request: ChatRequest, idempotencyKey: String? = nil, instance: String? = nil
    ) async throws -> ChatStream {
        try request.validate()
        var options = CallOptions()
        options.idempotencyKey = idempotencyKey
        options.instance = instance
        options.model = request.model
        options.streaming = true
        return try await openStream(
            path: "/v1/chat/completions", body: request.wireForm(stream: true), options: options)
    }

    // MARK: - the rest of the surface

    /// Embeddings for a batch of texts.
    public func embeddings(_ request: EmbeddingRequest, idempotencyKey: String? = nil) async throws
        -> EmbeddingList
    {
        try request.validate()
        var options = CallOptions()
        options.idempotencyKey = idempotencyKey
        options.model = request.model
        let response = try await send(
            method: "POST", path: "/v1/embeddings", body: request.wireForm, options: options)
        return EmbeddingList.decode(response.body ?? [:], meta: response.meta)
    }

    /// Generated images, returned as base64 rather than links.
    public func images(_ request: ImageRequest, idempotencyKey: String? = nil) async throws
        -> ImageList
    {
        try request.validate()
        var options = CallOptions()
        options.idempotencyKey = idempotencyKey
        options.model = request.model
        let response = try await send(
            method: "POST", path: "/v1/images/generations", body: request.wireForm,
            options: options)
        return ImageList.decode(response.body ?? [:], meta: response.meta)
    }

    /// Documents scored against a query, most relevant first.
    public func rerank(_ request: RerankRequest, idempotencyKey: String? = nil) async throws
        -> RerankList
    {
        try request.validate()
        var options = CallOptions()
        options.idempotencyKey = idempotencyKey
        options.model = request.model
        let response = try await send(
            method: "POST", path: "/v1/rerank", body: request.wireForm, options: options)
        return RerankList.decode(response.body ?? [:], meta: response.meta)
    }

    /// The accounting row for one request.
    ///
    /// A `404` here has three causes and the common one is not an error: a replayed request
    /// reached no model, so it was never billed and has no row. Read
    /// ``ResponseMeta/idempotentReplayOf`` on the original response to find the id that was.
    public func usage(requestID: String) async throws -> UsageRow {
        guard !requestID.isEmpty else {
            throw AxoniumError.invalidRequest("requestID is required")
        }
        let escaped =
            requestID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestID
        let response = try await send(
            method: "GET", path: "/v1/usage/\(escaped)", body: nil, options: .init())
        return UsageRow.decode(response.body ?? [:], meta: response.meta)
    }

    // MARK: - plumbing

    struct CallOptions: Sendable {
        var idempotencyKey: String?
        var instance: String?
        var model: String = ""
        var streaming = false
    }

    struct Decoded: Sendable {
        var body: [String: JSONValue]?
        var meta: ResponseMeta
    }

    /// A response whose body is any top-level JSON, for the pass-through route.
    struct DecodedValue: Sendable {
        var value: JSONValue?
        var meta: ResponseMeta
    }

    /// Sends a buffered request and narrows the body to a JSON object, which every modelled
    /// endpoint returns.
    private func send(
        method: String, path: String, body: [String: Any]?, options: CallOptions
    ) async throws -> Decoded {
        let raw = try await sendRaw(method: method, path: path, body: body, options: options)
        return Decoded(body: raw.value?.objectValue, meta: raw.meta)
    }

    /// Sends a buffered request, retrying where the platform says retrying can help.
    ///
    /// Returns the body as any top-level JSON rather than as an object, because the pass-through
    /// route returns whatever its engine returns and one live shape is an array. ``send`` narrows
    /// it for the endpoints whose shape this SDK does model — one retry loop, two readings.
    func sendRaw(
        method: String, path: String, body: [String: Any]?, options: CallOptions
    ) async throws -> DecodedValue {
        if let key = options.idempotencyKey, key.count > 255 {
            throw AxoniumError.invalidRequest(
                "idempotencyKey is \(key.count) characters; the gateway accepts at most 255")
        }

        var waited: TimeInterval = 0
        var attempt = 1
        while true {
            let raw: RawResponse
            do {
                raw = try await perform(method: method, path: path, body: body, options: options)
            } catch let error as AxoniumError {
                throw error
            }

            var meta = ResponseMeta.from(headers: raw.headers)
            // Stamped on every exit, success or failure. A call that failed after three attempts
            // and ninety seconds of waiting is precisely the one whose duration needs explaining.
            meta.waitedFor = waited
            meta.attempts = attempt

            if raw.status < 400 { return DecodedValue(value: raw.value, meta: meta) }

            let apiError = makeError(raw)
            guard
                let delay = configuration.retry.delay(
                    for: apiError, attempt: attempt,
                    hasIdempotencyKey: options.idempotencyKey != nil)
            else {
                throw AxoniumError.api(apiError)
            }
            try await Task.sleep(for: .seconds(delay))
            waited += delay
            attempt += 1
        }
    }

    private func makeError(_ raw: RawResponse) -> APIError {
        let body = raw.rawBody
        let rateLimit = RateLimitSnapshot.fromHeaders(raw.headers).withScope(from: body)
        var error = ProblemDetails.apiError(
            status: raw.status, body: body, headers: raw.headers,
            retryAfter: Transport.retryAfter(headers: raw.headers, body: body),
            rateLimit: rateLimit.isEmpty ? nil : rateLimit)
        error.hint = hint(for: error)
        return error
    }

    /// Says what the gateway's `detail` cannot: which scope is actually missing.
    ///
    /// Streaming is where this trips people up, because `inference:stream` is a different scope
    /// from `inference:read` and a `403` on a stream looks identical to one on a model.
    private func hint(for error: APIError) -> String {
        guard error.kind == .forbidden else { return "" }
        return
            "Access is deny-by-default and granted per model. Check that the token holds "
            + "model:<id> for the model you asked for, and note that streaming needs "
            + "inference:stream, which is a different scope from inference:read. "
            + "`await client.modelsMine()` lists what this token actually has."
    }

    private func perform(
        method: String, path: String, body: [String: Any]?, options: CallOptions
    ) async throws -> RawResponse {
        let token = try await tokens.token()
        var request = try buildRequest(
            method: method, path: path, body: body, options: options, token: token)

        var (data, response) = try await run(request)
        // Reactive fallback for a token revoked mid-flight, or an expiry the refresh-ahead
        // missed. Replayed once and only once: a second 401 is the gateway saying the credential
        // itself is the problem, and repeating it would only lock an account faster.
        if response.statusCode == 401 {
            let fresh = try await tokens.refresh(rejected: token)
            request = try buildRequest(
                method: method, path: path, body: body, options: options, token: fresh)
            (data, response) = try await run(request)
        }
        return RawResponse(
            status: response.statusCode, headers: Transport.headers(response), data: data)
    }

    private func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AxoniumError.transport("the gateway returned a non-HTTP response")
            }
            return (data, http)
        } catch let error as AxoniumError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AxoniumError.timeout(
                "the request timed out. The backend may still be generating, so retrying without "
                    + "an Idempotency-Key would start a second billable generation rather than "
                    + "resuming this one.")
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AxoniumError.transport("the request never reached the gateway: \(error)")
        }
    }

    private func buildRequest(
        method: String, path: String, body: [String: Any]?, options: CallOptions, token: String
    ) throws -> URLRequest {
        guard let url = URL(string: configuration.normalizedBaseURL + path) else {
            throw AxoniumError.configuration("could not build a URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // The header is the only accepted transport for a token; the gateway rejects one passed
        // as a query parameter outright, to keep credentials out of server and proxy logs.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            options.streaming ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let instance = options.instance, !instance.isEmpty {
            request.setValue(instance, forHTTPHeaderField: "X-Prometheus-Instance")
        }
        if let key = options.idempotencyKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        // A long generation is not a stalled one, so a stream gets no whole-request deadline.
        request.timeoutInterval =
            options.streaming ? configuration.timeouts.streamRead : configuration.timeouts.request
        return request
    }

    /// Opens a stream, reopening it when the gateway refuses before the stream begins.
    ///
    /// **A stream is retried before it starts and never after**, and the line between the two is
    /// not a judgement call: on a stream an error can only be observed from the status line,
    /// before a single byte of body exists. A `4xx` or `5xx` here therefore means nothing was
    /// generated and nothing was billed, so reopening is not a second generation. Once the `200`
    /// is committed the only failure channel left is in-band, and by then output has been
    /// delivered and charged — that one is never retried, and ``ChatStream`` has no path that
    /// would.
    ///
    /// It also matters that the gateway performs **no internal retries at all** for streams, so
    /// here the client is not one retry too many — it is the only one there is.
    ///
    /// This was reachable only once the platform stopped answering a pre-start refusal with a
    /// `200` carrying nothing but the terminal frame. Before that there was no rejection visible
    /// to reopen against.
    private func openStream(path: String, body: [String: Any], options: CallOptions) async throws
        -> ChatStream
    {
        var waited: TimeInterval = 0
        var attempt = 1

        while true {
            let token = try await tokens.token()
            var request = try buildRequest(
                method: "POST", path: path, body: body, options: options, token: token)

            var (byteStream, response) = try await openBytes(request)
            // Reactive fallback for a token revoked mid-flight, once and only once per attempt.
            if response.statusCode == 401 {
                let fresh = try await tokens.refresh(rejected: token)
                request = try buildRequest(
                    method: "POST", path: path, body: body, options: options, token: fresh)
                (byteStream, response) = try await openBytes(request)
            }

            let headers = Transport.headers(response)

            if response.statusCode < 400 {
                var meta = ResponseMeta.from(headers: headers)
                meta.waitedFor = waited
                meta.attempts = attempt
                return ChatStream(bytes: byteStream, meta: meta)
            }

            // An error response is an ordinary buffered body, so it has to be drained before it
            // can be typed.
            var data = Data()
            for try await byte in byteStream { data.append(byte) }
            let error = makeError(
                RawResponse(status: response.statusCode, headers: headers, data: data))

            guard
                let delay = configuration.retry.delay(
                    for: error, attempt: attempt,
                    hasIdempotencyKey: options.idempotencyKey != nil)
            else {
                throw AxoniumError.api(error)
            }
            try await Task.sleep(for: .seconds(delay))
            waited += delay
            attempt += 1
        }
    }

    private func openBytes(_ request: URLRequest) async throws -> (
        URLSession.AsyncBytes, HTTPURLResponse
    ) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AxoniumError.transport("the gateway returned a non-HTTP response")
            }
            return (bytes, http)
        } catch let error as AxoniumError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AxoniumError.transport("the stream never opened: \(error)")
        }
    }
}
