import Foundation

/// The answer from a pass-through `predict` call, and the correlation metadata beside it.
///
/// ``value`` is whatever the engine returned, undecoded. **Not a dictionary**: one of the three
/// live shapes is a top-level array, measured against a deployment —
///
/// ```
/// sst2-clf     [{"label":"POSITIVE","score":0.978}]
/// von-decide   {"sequence":…,"labels":[…],"scores":[…]}
/// laya-decide  {"model":…,"answers":{…},"usage":{…},"routing":{…}}
/// ```
///
/// — so a type that assumed an object would have failed on the first of them.
public struct PredictResult: Sendable, Hashable {
    public var value: JSONValue
    public var meta: ResponseMeta
}

extension AxoniumClient {
    /// Calls a model on the pass-through route, interpreting nothing.
    ///
    /// `POST /v1/models/{model}/predict` is for the tasks OpenAI has no shape for:
    /// classification, zero-shot scoring, typed decisions. **The body goes to the engine verbatim
    /// and its answer comes back verbatim**, because every other route here is OpenAI-shaped only
    /// because every task it serves has an OpenAI endpoint to be shaped like. These do not, and
    /// inventing a body for them would be the gateway deciding what somebody else's API looks
    /// like.
    ///
    /// So this is deliberately **not** a `classify(text:)` typed per modality. That would promise
    /// a stability the endpoint does not have: the shape is the engine's, and two engines serving
    /// one modality can want different bodies. ``Model/payloadSchema`` in the catalog is what
    /// identifies the shape — dispatch on that, not on ``Model/modality``.
    ///
    /// What does *not* pass through is the policy: the model still resolves, `inference:read`
    /// plus the specific `model:<id>` scope is still required, and the request is still metered
    /// and still counts against a spend cap.
    ///
    /// ```swift
    /// let result = try await client.predict(
    ///     model: "sst2-clf",
    ///     body: .object(["inputs": .string("El servicio ha sido excelente")]))
    /// let label = result.value.arrayValue?.first?["label"]?.stringValue
    /// ```
    ///
    /// - Note: a model that *has* an OpenAI endpoint is refused here with `400 modality-mismatch`
    ///   — the inverse of every other handler's check. Without it the same model would be
    ///   reachable two ways, with two billing paths, and the one that billed correctly would be
    ///   whichever the caller did not use.
    public func predict(
        model: String, body: JSONValue, idempotencyKey: String? = nil, instance: String? = nil
    ) async throws -> PredictResult {
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AxoniumError.invalidRequest("model is required")
        }
        guard let wire = body.wireForm as? [String: Any] else {
            // The engines seen so far all take an object. A top-level array or scalar is not
            // refused because it is impossible — it is refused because nothing in the contract
            // describes one, and sending it would be guessing on the caller's behalf.
            throw AxoniumError.invalidRequest(
                "predict body must be a JSON object; got \(body). The engine's own contract is "
                    + "named by payload_schema in the catalog.")
        }
        let escaped =
            model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model

        var options = CallOptions()
        options.idempotencyKey = idempotencyKey
        options.instance = instance
        options.model = model

        let response = try await sendRaw(
            method: "POST", path: "/v1/models/\(escaped)/predict", body: wire, options: options)
        guard let value = response.value else {
            throw AxoniumError.api(
                APIError(
                    status: 200, kind: .otherServerError, typeSuffix: "", title: "",
                    detail: "the predict route returned a body that is not JSON",
                    instance: "", requestID: response.meta.requestID,
                    traceID: response.meta.traceID, retryAfter: nil, hint: ""))
        }
        return PredictResult(value: value, meta: response.meta)
    }
}
