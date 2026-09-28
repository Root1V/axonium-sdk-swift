import Foundation

/// A model in the platform's catalog.
public struct Model: Sendable, Hashable {
    public var id: String = ""
    public var ownedBy: String = ""
    /// Optional, because a model can have none — an image model has no context window, and
    /// reporting `0` would read as a window of zero rather than as a question that does not
    /// apply.
    public var contextLength: Int?
    public var family: String = ""
    public var quantization: String = ""
    /// Which endpoint the model can be called on: `text`, `vision`, `embedding`, `image`,
    /// `rerank`, `classification`, `zero_shot` or `typed_decision`. An open set — three of those
    /// arrived after the first SDK shipped — so never enumerate it as closed.
    public var modality: String = ""
    /// How many replicas serve this model.
    public var servedBy: Int = 0
    /// A versioned identifier for the request body's contract. **Dispatch on this, not on
    /// ``modality``**: a pass-through model's body belongs to its engine, and two engines serving
    /// one modality can want different shapes.
    ///
    /// `nil` means "we cannot state a shape", not "there is no field". Treat it as do-not-guess.
    public var payloadSchema: String?
    public var raw: [String: JSONValue] = [:]

    static func decode(_ value: JSONValue) -> Model {
        var model = Model()
        model.id = value["id"]?.stringValue ?? ""
        model.ownedBy = value["owned_by"]?.stringValue ?? ""
        model.contextLength = value["context_length"]?.intValue
        model.family = value["family"]?.stringValue ?? ""
        model.quantization = value["quantization"]?.stringValue ?? ""
        model.modality = value["modality"]?.stringValue ?? ""
        model.servedBy = value["served_by"]?.intValue ?? 0
        model.payloadSchema = value["payload_schema"]?.stringValue
        model.raw = value.objectValue ?? [:]
        return model
    }
}

/// A list of models.
public struct ModelList: Sendable, Hashable {
    public var data: [Model] = []
    public var meta = ResponseMeta()

    /// The ids, which is what a picker or a scope check actually wants.
    public var ids: [String] { data.map(\.id) }

    static func decode(_ body: [String: JSONValue], meta: ResponseMeta) -> ModelList {
        var list = ModelList()
        list.data = (body["data"]?.arrayValue ?? []).map(Model.decode)
        list.meta = meta
        return list
    }
}
