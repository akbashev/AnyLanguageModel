import Foundation
import Testing

@testable import AnyLanguageModel

/// A response says whether the model stopped because it reached its token limit,
/// as each provider reports why its answer ended,
/// streamed or not.
@Suite("Response token limit")
struct ResponseTokenLimitTests {
    /// Why a provider's answer ended.
    enum Ending: CaseIterable {
        /// The model finished its answer.
        case finished
        /// The answer reached its token limit.
        case limit
        /// The provider stopped the answer for a reason other than its length.
        case other
    }

    enum Provider: CaseIterable {
        case ollama, openAIChat, openAIResponses, openResponses, anthropic, gemini
    }

    @Test(
        "a response says it reached its token limit only when the provider says so",
        arguments: Provider.allCases,
        Ending.allCases
    )
    func aResponseSaysItReachedItsTokenLimit(provider: Provider, ending: Ending) async throws {
        for streaming in [false, true] {
            let transport = FakeTransport(replies: [Self.reply(provider, ending: ending, streaming: streaming)])
            let session = LanguageModelSession(model: Self.model(provider, transport: transport))

            let response =
                streaming
                ? try await session.streamResponse(to: "Question").collect()
                : try await session.respond(to: "Question")

            #expect(response.content == "Now I'll", "\(provider), streaming: \(streaming)")
            #expect(response.reachedTokenLimit == (ending == .limit), "\(provider), streaming: \(streaming)")
        }
    }

    @Test("a streamed response's last snapshot says it reached its token limit", arguments: Provider.allCases)
    func aStreamsLastSnapshotSaysItReachedItsTokenLimit(provider: Provider) async throws {
        let transport = FakeTransport(replies: [Self.reply(provider, ending: .limit, streaming: true)])
        let session = LanguageModelSession(model: Self.model(provider, transport: transport))

        var last: LanguageModelSession.ResponseStream<String>.Snapshot?
        for try await snapshot in session.streamResponse(to: "Question") { last = snapshot }

        #expect(last?.reachedTokenLimit == true, "\(provider)")
    }

    // MARK: Models

    private static func model(_ provider: Provider, transport: FakeTransport) -> any LanguageModel {
        switch provider {
        case .ollama:
            OllamaLanguageModel(model: "m", transport: transport)
        case .openAIChat:
            OpenAILanguageModel(apiKey: "k", model: "m", apiVariant: .chatCompletions, transport: transport)
        case .openAIResponses:
            OpenAILanguageModel(apiKey: "k", model: "m", apiVariant: .responses, transport: transport)
        case .openResponses:
            OpenResponsesLanguageModel(
                baseURL: URL(string: "http://localhost:8000/v1")!,
                apiKey: "k",
                model: "m",
                transport: transport
            )
        case .anthropic:
            AnthropicLanguageModel(apiKey: "k", model: "m", transport: transport)
        case .gemini:
            GeminiLanguageModel(apiKey: "k", model: "m", transport: transport)
        }
    }

    // MARK: Replies

    /// The answer "Now I'll", ended as `ending` says, in the provider's own words.
    private static func reply(_ provider: Provider, ending: Ending, streaming: Bool) -> FakeTransport.Reply {
        switch provider {
        case .ollama:
            let reason = ["finished": "stop", "limit": "length", "other": "load"]["\(ending)"]!
            let done =
                #"{"model":"m","created_at":"2026-11-19T10:00:00.000Z","message":{"role":"assistant","content":""},"#
                + #""done":true,"done_reason":"\#(reason)","prompt_eval_count":1,"eval_count":2}"#
            guard streaming else {
                return .init(chunks: [done.replacingOccurrences(of: #""content":"""#, with: #""content":"Now I'll""#)])
            }
            return .init(chunks: [
                #"{"model":"m","created_at":"2026-11-19T10:00:00.000Z","message":{"role":"assistant","content":"Now I'll"},"done":false}"#
                    + "\n",
                done + "\n",
            ])
        case .openAIChat:
            let reason = ["finished": "stop", "limit": "length", "other": "content_filter"]["\(ending)"]!
            guard streaming else {
                return .init(chunks: [
                    #"{"id":"c","choices":[{"index":0,"message":{"role":"assistant","content":"Now I'll"},"finish_reason":"\#(reason)"}]}"#
                ])
            }
            return .init(chunks: [
                #"data: {"id":"c","choices":[{"index":0,"delta":{"content":"Now I'll"},"finish_reason":null}]}"#
                    + "\n\n",
                #"data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"\#(reason)"}]}"# + "\n\n",
                "data: [DONE]\n\n",
            ])
        case .openAIResponses, .openResponses:
            let message =
                #"{"type":"message","id":"msg_1","role":"assistant","status":"completed","#
                + #""content":[{"type":"output_text","text":"Now I'll","annotations":[]}]}"#
            let (status, details, event) =
                switch ending {
                case .finished: ("completed", "null", "response.completed")
                case .limit: ("incomplete", #"{"reason":"max_output_tokens"}"#, "response.incomplete")
                case .other: ("incomplete", #"{"reason":"content_filter"}"#, "response.incomplete")
                }
            let response =
                #"{"id":"resp_1","status":"\#(status)","incomplete_details":\#(details),"output":[\#(message)]}"#
            guard streaming else { return .init(chunks: [response]) }
            return .init(chunks: [
                #"data: {"type":"response.output_text.delta","delta":"Now I'll"}"# + "\n\n",
                #"data: {"type":"\#(event)","response":\#(response)}"# + "\n\n",
            ])
        case .anthropic:
            let reason = ["finished": "end_turn", "limit": "max_tokens", "other": "refusal"]["\(ending)"]!
            guard streaming else {
                return .init(chunks: [
                    #"{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"Now I'll"}],"#
                        + #""model":"m","stop_reason":"\#(reason)","usage":{"input_tokens":1,"output_tokens":2}}"#
                ])
            }
            return .init(chunks: [
                [
                    #"{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"m","usage":{"input_tokens":1,"output_tokens":0}}}"#,
                    #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                    #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Now I'll"}}"#,
                    #"{"type":"content_block_stop","index":0}"#,
                    #"{"type":"message_delta","delta":{"stop_reason":"\#(reason)"},"usage":{"output_tokens":2}}"#,
                    #"{"type":"message_stop"}"#,
                ].map { "data: \($0)\n\n" }.joined()
            ])
        case .gemini:
            let reason = ["finished": "STOP", "limit": "MAX_TOKENS", "other": "SAFETY"]["\(ending)"]!
            let candidate =
                #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Now I'll"}]},"finishReason":"\#(reason)"}]}"#
            return .init(chunks: [streaming ? "data: \(candidate)\n\n" : candidate])
        }
    }
}
