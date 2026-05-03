import Foundation
import os

/// Observer that turns proxy traffic into accumulated stats. Owns one
/// `LLMStatsStore` and a per-in-flight-request scratchpad that decodes
/// SSE / JSON envelopes into `TokenUsage` and tool-use signatures.
///
/// All state is funnelled through this actor — the proxy's hot path
/// just spawns `Task { await observer.proxy(...) }` per chunk and lets
/// the actor serialize.
public actor LLMUsageObserver: LLMProxyObserver {
    private static let logger = Logger(subsystem: "app.openisland", category: "LLMUsage")

    public let store: LLMStatsStore
    private var inFlight: [UUID: RequestState] = [:]

    public init(store: LLMStatsStore) {
        self.store = store
    }

    /// Optional: when set, the pricing fallback path queries the
    /// active profile's `ProfileCostMetadata` for models not in the
    /// static `LLMPricing.table` (e.g. DeepSeek V4 Pro/Flash after
    /// body model rewrite produces `deepseek-v4-pro`). Nil for
    /// existing test setups that don't wire routing.
    public nonisolated(unsafe) var profileResolver: (any UpstreamProfileResolver)?

    // MARK: - LLMProxyObserver

    public func proxyWillForward(_ context: LLMProxyRequestContext) async {
        let client = LLMUsageHeuristics.clientFromUserAgent(context.userAgent)
        let model = LLMRequestParsing.extractModel(from: context.requestBody)
        // Read-only — `LLMRequestAnalyzer` never mutates the body.
        let declared = LLMRequestAnalyzer.analyzeDeclaredTools(in: context.requestBody)
        inFlight[context.id] = RequestState(
            client: client,
            model: model,
            upstream: context.upstream,
            path: context.path,
            declaredTools: declared
        )
    }

    public func proxy(
        _ context: LLMProxyRequestContext,
        didReceiveResponseStatus status: Int,
        headers: [String: String]
    ) async {
        guard var state = inFlight[context.id] else { return }
        state.httpStatus = status
        let contentType = headers["content-type"]?.lowercased() ?? ""
        state.isSSE = contentType.contains("text/event-stream")
        inFlight[context.id] = state
    }

    public func proxy(
        _ context: LLMProxyRequestContext,
        didReceiveResponseChunk chunk: Data
    ) async {
        guard var state = inFlight[context.id] else { return }
        if state.isSSE {
            for frame in state.sseSplitter.consume(chunk) {
                applyFrame(frame, to: &state)
            }
        } else {
            // Cap non-SSE accumulation at 8 MiB to bound memory in the
            // pathological case (a misbehaving server streaming JSON
            // without termination). Token-counting accuracy degrades
            // gracefully — we just stop parsing.
            if state.bodyAccumulator.count < 8 * 1024 * 1024 {
                state.bodyAccumulator.append(chunk)
            }
        }
        // Push context fill once per request, as soon as the first
        // usage envelope lands (message_start for Anthropic SSE,
        // initial usage block for OpenAI). Skipped silently when the
        // model isn't in `ModelContextLimits.table` — UI shows "—"
        // rather than a fabricated ratio.
        //
        // Order matters: flip the flag and write the state back into
        // `inFlight` BEFORE `await store.recordContextFill`. The
        // await yields the actor; if `didCompleteWithError` lands in
        // between (race observed in `LLMProxyServerIntegrationTests`)
        // it removes our entry from `inFlight` to do the final
        // `recordRequestCompletion` — and re-writing `state` after
        // the await would resurrect a stale copy and erase that
        // completion path's effect.
        var pendingPush: (LLMClient, Double)?
        if !state.contextFillPushed,
           let model = state.model,
           let limit = ModelContextLimits.maxContextTokens(forModel: model) {
            let totalIn = state.usage.input + state.usage.cacheWrite + state.usage.cacheRead
            if totalIn > 0 {
                let ratio = min(1.0, Double(totalIn) / Double(limit))
                state.contextFillPushed = true
                pendingPush = (state.client, ratio)
            }
        }
        inFlight[context.id] = state
        if let (client, ratio) = pendingPush {
            await store.recordContextFill(client: client, ratio: ratio)
        }
    }

    public func proxy(
        _ context: LLMProxyRequestContext,
        didCompleteWithError error: (any Error)?
    ) async {
        guard let state = inFlight.removeValue(forKey: context.id) else { return }
        guard error == nil, (200..<300).contains(state.httpStatus) else { return }

        var usage = state.usage
        var toolUses = state.toolUses

        if !state.isSSE, !state.bodyAccumulator.isEmpty {
            switch state.upstream {
            case .anthropic:
                if let extracted = AnthropicNonStreaming.extract(state.bodyAccumulator) {
                    usage = extracted.usage
                    toolUses += extracted.toolUses
                }
            case .openai:
                if state.path.hasPrefix("/v1/chat/completions") {
                    if let extracted = OpenAINonStreaming.extractChatCompletions(state.bodyAccumulator) {
                        usage = extracted.usage
                        toolUses += extracted.toolUses
                    }
                } else if state.path.hasPrefix("/v1/responses") {
                    if let envelope = OpenAINonStreaming.extractResponsesEnvelope(state.bodyAccumulator) {
                        usage = envelope
                    }
                }
            case .unknown:
                break
            }
        }

        let cost = LLMPricing.costUSD(
            model: state.model,
            usage: usage,
            profileResolver: profileResolver
        )
        // Compute waste: tools the model declared but never invoked
        // during the turn. Sum the per-tool estimate from the
        // analyzer pass at proxyWillForward time. Used names from
        // toolUses; declared from state.declaredTools.
        let usedNames = Set(toolUses.map(\.name))
        let unused = state.declaredTools.toolNames.subtracting(usedNames)
        let unusedTokensWasted = unused.reduce(0) { acc, name in
            acc + (state.declaredTools.estimatedTokensPerTool[name] ?? 0)
        }
        if usage != .zero || !toolUses.isEmpty {
            await store.recordRequestCompletion(
                date: context.receivedAt,
                client: state.client,
                usage: usage,
                costUsd: cost,
                unusedToolTokensWasted: unusedTokensWasted
            )
        }
        for (name, hash) in toolUses {
            let dup = await store.recordToolUse(
                client: state.client,
                name: name,
                inputHash: hash,
                at: context.receivedAt
            )
            if dup {
                await store.recordDuplicateWarning(
                    date: context.receivedAt,
                    client: state.client,
                    toolName: name
                )
            }
        }
    }

    // MARK: - Stream effects

    private func applyFrame(_ frame: SSEFrame, to state: inout RequestState) {
        switch state.upstream {
        case .anthropic:
            for effect in state.anthropicConsumer.process(frame) {
                switch effect {
                case let .usageInitial(input, cacheWrite, cacheRead, output):
                    state.usage.input = input
                    state.usage.cacheWrite = cacheWrite
                    state.usage.cacheRead = cacheRead
                    state.usage.output = max(state.usage.output, output)
                case let .usageOutputCumulative(output):
                    state.usage.output = output
                case let .toolUseComplete(name, hash):
                    state.toolUses.append((name: name, inputHash: hash))
                }
            }
        case .openai:
            // /v1/responses streams typed events (`response.completed` etc.)
            // — sniff those first; chat/completions falls through to the
            // generic OpenAI consumer which expects raw `data:` frames.
            if let event = frame.event, event.hasPrefix("response.") {
                if event == "response.completed" || event == "response.done" {
                    if let payload = frame.data.data(using: .utf8),
                       let envelope = OpenAINonStreaming.extractResponsesEnvelope(payload) {
                        state.usage = envelope
                    }
                }
                return
            }
            for effect in state.openAIConsumer.process(frame) {
                switch effect {
                case let .usageFinal(input, cacheRead, output):
                    state.usage.input = input
                    state.usage.cacheRead = cacheRead
                    state.usage.output = output
                case let .toolUseComplete(name, hash):
                    state.toolUses.append((name: name, inputHash: hash))
                }
            }
        case .unknown:
            break
        }
    }

    private struct RequestState {
        let client: LLMClient
        let model: String?
        let upstream: LLMUpstream
        let path: String
        let declaredTools: LLMRequestAnalyzer.Declaration
        var httpStatus: Int = 0
        var isSSE: Bool = false
        var sseSplitter = SSEEventSplitter()
        var anthropicConsumer = AnthropicStreamConsumer()
        var openAIConsumer = OpenAIStreamConsumer()
        var bodyAccumulator = Data()
        var usage = TokenUsage.zero
        var toolUses: [(name: String, inputHash: String)] = []
        /// Once-per-request flag so we push context fill exactly
        /// once — the first chunk that landed a usage envelope.
        var contextFillPushed = false
    }
}
