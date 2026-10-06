import Foundation

/// One embedding vector.
public struct Embedding: Sendable, Hashable {
    public var index: Int = 0
    public var embedding: [Double] = []
}

/// A batch of embeddings.
public struct EmbeddingList: Sendable, Hashable {
    public var model: String = ""
    public var data: [Embedding] = []
    public var usage: Usage?
    public var raw: [String: JSONValue] = [:]
    public var meta = ResponseMeta()

    static func decode(_ body: [String: JSONValue], meta: ResponseMeta) -> EmbeddingList {
        var list = EmbeddingList()
        list.model = body["model"]?.stringValue ?? ""
        list.raw = body
        list.meta = meta
        list.usage = Usage.from(body)
        list.data = (body["data"]?.arrayValue ?? []).enumerated().map { offset, entry in
            Embedding(
                index: entry["index"]?.intValue ?? offset,
                embedding: (entry["embedding"]?.arrayValue ?? []).compactMap(\.doubleValue))
        }
        return list
    }
}

/// One generated image.
public struct GeneratedImage: Sendable, Hashable {
    /// The image as base64. Decode it with ``data``.
    public var b64JSON: String = ""
    public var url: String?

    /// The decoded bytes, or `nil` when the payload is not valid base64.
    public var data: Data? { Data(base64Encoded: b64JSON) }
}

/// A set of generated images.
public struct ImageList: Sendable, Hashable {
    public var created: Int = 0
    public var data: [GeneratedImage] = []
    /// `png`, or whatever the backend produced. Backend-dependent.
    public var outputFormat: String = ""
    public var raw: [String: JSONValue] = [:]
    public var meta = ResponseMeta()

    static func decode(_ body: [String: JSONValue], meta: ResponseMeta) -> ImageList {
        var list = ImageList()
        list.created = body["created"]?.intValue ?? 0
        list.outputFormat = body["output_format"]?.stringValue ?? ""
        list.raw = body
        list.meta = meta
        list.data = (body["data"]?.arrayValue ?? []).map { entry in
            GeneratedImage(
                b64JSON: entry["b64_json"]?.stringValue ?? "", url: entry["url"]?.stringValue)
        }
        return list
    }
}

/// One reranked document.
public struct RerankResult: Sendable, Hashable {
    /// The document's position in the list that was **sent**, not in the ranking.
    ///
    /// The results arrive already sorted by relevance, so this is what maps a score back to the
    /// text it scored. Using the array position instead silently reorders the caller's data.
    public var index: Int = 0
    public var relevanceScore: Double = 0
}

/// Documents scored against a query.
public struct RerankList: Sendable, Hashable {
    public var model: String = ""
    public var results: [RerankResult] = []
    public var usage: Usage?
    public var raw: [String: JSONValue] = [:]
    public var meta = ResponseMeta()

    static func decode(_ body: [String: JSONValue], meta: ResponseMeta) -> RerankList {
        var list = RerankList()
        list.model = body["model"]?.stringValue ?? ""
        list.raw = body
        list.meta = meta
        list.usage = Usage.from(body)
        list.results = (body["results"]?.arrayValue ?? []).map { entry in
            RerankResult(
                index: entry["index"]?.intValue ?? 0,
                relevanceScore: entry["relevance_score"]?.doubleValue ?? 0)
        }
        return list
    }
}

/// The billing and accounting row for one request.
public struct UsageRow: Sendable, Hashable {
    public var requestID: String = ""
    public var model: String = ""
    /// `chat`, `embedding`, `image` or `predict`. **An open set**: `predict` is newer than the
    /// others, so anything treating this as closed breaks on it.
    public var requestKind: String = ""
    public var usage: Usage?
    public var imageCount: Int = 0
    /// True when generation stopped early. A stream that broke mid-answer is billed for what it
    /// produced, so an interrupted row is not a free one.
    public var interrupted: Bool = false
    public var terminationReason: String = ""
    /// `nil` means **no price was configured** for that model, not zero. The platform never
    /// reports an unpriced request as free.
    public var costUSD: Double?
    public var instanceID: String = ""
    public var createdAt: String = ""
    public var raw: [String: JSONValue] = [:]
    public var meta = ResponseMeta()

    static func decode(_ body: [String: JSONValue], meta: ResponseMeta) -> UsageRow {
        var row = UsageRow()
        row.requestID = body["request_id"]?.stringValue ?? ""
        row.model = body["model"]?.stringValue ?? ""
        row.requestKind = body["request_kind"]?.stringValue ?? ""
        row.usage = Usage.from(body)
        row.imageCount = body["image_count"]?.intValue ?? 0
        row.interrupted = body["interrupted"]?.boolValue ?? false
        row.terminationReason = body["termination_reason"]?.stringValue ?? ""
        row.costUSD = body["cost_usd"]?.doubleValue
        row.instanceID = body["instance_id"]?.stringValue ?? ""
        row.createdAt = body["created_at"]?.stringValue ?? ""
        row.raw = body
        row.meta = meta
        return row
    }
}

/// A request for embeddings.
public struct EmbeddingRequest: Sendable {
    public var model: String
    public var input: [String]

    public init(model: String, input: [String]) {
        self.model = model
        self.input = input
    }

    func validate() throws {
        if model.isEmpty { throw AxoniumError.invalidRequest("model is required") }
        if input.isEmpty { throw AxoniumError.invalidRequest("input must not be empty") }
    }

    var wireForm: [String: Any] { ["model": model, "input": input] }
}

/// A request to generate images.
public struct ImageRequest: Sendable {
    public var model: String
    public var prompt: String
    public var n: Int?
    public var size: String?

    public init(model: String, prompt: String, n: Int? = nil, size: String? = nil) {
        self.model = model
        self.prompt = prompt
        self.n = n
        self.size = size
    }

    func validate() throws {
        if model.isEmpty { throw AxoniumError.invalidRequest("model is required") }
        if prompt.isEmpty { throw AxoniumError.invalidRequest("prompt is required") }
    }

    var wireForm: [String: Any] {
        var payload: [String: Any] = ["model": model, "prompt": prompt]
        if let n { payload["n"] = n }
        if let size { payload["size"] = size }
        return payload
    }
}

/// A request to score documents against a query.
public struct RerankRequest: Sendable {
    public var model: String
    public var query: String
    public var documents: [String]
    public var topN: Int?
    /// Return each `relevanceScore` as the model's raw **logit** instead of a probability.
    ///
    /// A reranker's probabilities saturate near 1.0 — 0.99 was measured for a document only loosely
    /// related to the query — and a saturated probability cannot be calibrated while the logit
    /// behind it can.
    ///
    /// **Not every engine has it**, and that is safe: where it does not the request still succeeds
    /// and the field comes back named in `X-Prometheus-Ignored-Parameters`. Send it
    /// unconditionally; being dropped is discoverable rather than silent.
    public var rawScores: Bool?

    public init(
        model: String, query: String, documents: [String], topN: Int? = nil,
        rawScores: Bool? = nil
    ) {
        self.model = model
        self.query = query
        self.documents = documents
        self.topN = topN
        self.rawScores = rawScores
    }

    func validate() throws {
        if model.isEmpty { throw AxoniumError.invalidRequest("model is required") }
        if query.isEmpty { throw AxoniumError.invalidRequest("query is required") }
        if documents.isEmpty { throw AxoniumError.invalidRequest("documents must not be empty") }
    }

    var wireForm: [String: Any] {
        var payload: [String: Any] = ["model": model, "query": query, "documents": documents]
        if let topN { payload["top_n"] = topN }
        if let rawScores { payload["raw_scores"] = rawScores }
        return payload
    }
}
