import Foundation

/// One part of a multi-part message.
///
/// Images go as **bytes, never a link.** The gateway refuses `http(s)://` in `image_url` as an
/// SSRF mitigation, so an API that accepted a URL would accept something that always fails. This
/// type cannot express one, which is the difference between a rule you have to remember and a
/// rule you cannot break.
public enum ContentPart: Sendable, Hashable {
    case text(String)
    /// An image as raw bytes plus its media type, serialised as a `data:` URI.
    ///
    /// Base64 inflates by about a third and the result travels inside the JSON body, so send a
    /// thumbnail rather than an original photograph.
    case image(Data, mediaType: String)

    var wireForm: [String: Any] {
        switch self {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let data, let mediaType):
            let encoded = data.base64EncodedString()
            return [
                "type": "image_url",
                "image_url": ["url": "data:\(mediaType);base64,\(encoded)"],
            ]
        }
    }
}

/// What a message carries: text, or an ordered mix of text and images.
///
/// **One field with two shapes, which is what the wire has and what every SDK in this family
/// does.** `content` is a string or an array of parts in the OpenAI format, and Python, Go and
/// Rust each model it as one field that accepts either. This package shipped `String?` and was
/// the only one of the four that could not send an image.
///
/// An enum rather than two optional fields — `content` plus a `parts` beside it — because two
/// fields admit a state that means nothing, both set at once, which then has to be rejected at
/// runtime. Here it cannot be written down. That difference is the whole reason to prefer the
/// union in a language that has one.
///
/// Conforms to `ExpressibleByStringLiteral`, so the ordinary case is unchanged:
///
/// ```swift
/// Message(role: "user", content: "hola")
/// Message(role: "user", content: .parts([
///     .text("¿Qué hay en esta foto?"),
///     .image(thumbnailJPEG, mediaType: "image/jpeg"),
/// ]))
/// ```
public enum MessageContent: Sendable, Hashable, ExpressibleByStringLiteral {
    case text(String)
    case parts([ContentPart])

    public init(stringLiteral value: String) { self = .text(value) }

    /// The text, when this is text. `nil` for a multi-part message — deliberately, rather than
    /// joining the text parts: a caller asking for "the text" of a message holding an image and a
    /// question would get something that reads complete and is not.
    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var wireForm: Any {
        switch self {
        case .text(let value): return value
        case .parts(let parts): return parts.map(\.wireForm)
        }
    }

    /// Catches the one mistake this type cannot prevent structurally: an empty part list, which
    /// the gateway answers with a validation error after a round trip.
    func validate() throws {
        if case .parts(let parts) = self, parts.isEmpty {
            throw AxoniumError.invalidRequest(
                "a message's parts list is empty; use .text(\"\") for an empty message")
        }
    }
}
