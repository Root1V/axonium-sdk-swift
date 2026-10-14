import Foundation
import Testing

@testable import Axonium

/// Does a reasoning model's own analysis go back **out**, or only come in?
///
/// `PRM-VRT-003`, 2026-10-13. Prometheus found their gateway **deleting `reasoning_content` from
/// every message of every client** — their internal message model did not name the field, Pydantic
/// dropped what it did not name, and the serializer wrote the rest to the engine. Fixed on their
/// side, and then they asked the three frameworks the one question they could not answer
/// themselves: does that field survive *your* serialization?
///
/// **Not cosmetic.** llama.cpp issue #27720 is closed as not fixable in the parser and the thread
/// measures the cost: **7 failed turns out of 120** with the reasoning withheld, **0 of 120** with
/// it returned. A reasoning model continuing from its own tool call, without its analysis channel,
/// emits malformed headers that lose the whole turn. On models that do not use Harmony it is not an
/// error at all — it is quietly worse answers, which is harder to notice and worse to diagnose.
///
/// **This package was the worst of the five.** `ChatCompletion` had exposed `reasoningContent`
/// since `0.2.0`, and `Message.wireForm` built the payload field by field with no field for it and
/// no escape hatch — so a Swift caller running a tool loop on a reasoning model had **no way** to
/// return what the model had just told them. Python, Go and Rust already worked; TypeScript's
/// runtime passed it but its `Message` interface refused it at compile time.
///
/// **And the hole was never the field, it was that nothing looked.** Synaptum and Aeon each
/// reported the same shape in their own words: their suites asserted what *arrived* and none
/// asserted what was *sent back*. A field that enters and does not leave breaks nothing visible —
/// the model answers worse, or one turn in seventeen fails, and nobody attributes it to this.
@Suite("Reasoning goes back out")
struct ReasoningReturnsTests {

    static let reasoning = "The user wants weather. I should call get_weather."

    /// The shape the measurement is about: an assistant turn carrying reasoning *and* a tool call,
    /// with no text content.
    static func turnThatCalledATool() -> Message {
        Message(
            role: "assistant",
            toolCalls: [
                ToolCall(
                    id: "c1", name: "get_weather", arguments: #"{"city":"Quito"}"#)
            ],
            reasoningContent: reasoning)
    }

    @Test("reasoning_content leaves on an assistant turn")
    func itLeaves() throws {
        let payload = Self.turnThatCalledATool().wireForm

        #expect(payload["reasoning_content"] as? String == Self.reasoning)
        // The tool call has to survive beside it: the measured turn carries both, and a fix that
        // sent the reasoning while dropping the call would satisfy a weaker assertion.
        let calls = payload["tool_calls"] as? [[String: Any]]
        #expect(calls?.count == 1)
        #expect(calls?.first?["id"] as? String == "c1")
    }

    /// Never `""`. Absent and empty are different assertions, and the second one claims the model
    /// thought about nothing. Aeon and Synaptum fixed this field in the same week and both wrote
    /// down this rule, so it is pinned here rather than left to whatever `wireForm` happens to do.
    @Test("the key is absent, not empty, when the model reported none")
    func absentIsNotEmpty() throws {
        let payload = Message.assistant("hi").wireForm

        #expect(payload["reasoning_content"] == nil)
    }

    /// The round trip, which is what a tool-use loop actually does.
    ///
    /// End to end rather than field by field, because the failure lives in the join: the response
    /// type carried the reasoning and the request type could not send it, and each half looked
    /// right on its own.
    @Test("a completion's reasoning can be handed straight back")
    func roundTrip() throws {
        let body = """
            {"id":"c","object":"chat.completion","created":0,"model":"gpt-oss-20b-mxfp4",
             "choices":[{"index":0,"finish_reason":"tool_calls","message":{
               "role":"assistant","content":null,
               "reasoning_content":"thinking out loud",
               "tool_calls":[{"id":"c1","type":"function",
                              "function":{"name":"f","arguments":"{}"}}]}}]}
            """
        let decoded = try JSONSerialization.jsonObject(with: Data(body.utf8))
        let object = try #require(JSONValue(decoded).objectValue)
        let completion = ChatCompletion.decode(object, meta: ResponseMeta())
        #expect(completion.reasoningContent == "thinking out loud")

        let handedBack = Message(
            role: "assistant", content: nil, reasoningContent: completion.reasoningContent)
        #expect(handedBack.wireForm["reasoning_content"] as? String == "thinking out loud")
    }
}
