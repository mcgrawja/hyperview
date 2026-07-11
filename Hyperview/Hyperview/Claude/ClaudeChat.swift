//
//  ClaudeChat.swift
//  Hyperview
//
//  Phase 5 — the in-app Claude chat (§7.1): Anthropic Messages API over plain
//  URLSession (no SDK exists for Swift), streaming SSE, adaptive thinking, and
//  a tool-use loop over the SAME MCPToolExecutor the MCP server uses — so
//  in-app Claude has every Hyperview capability, and every tool call lands in
//  the same audit log.
//
//  API notes (per current Anthropic docs):
//  • Default model claude-opus-4-8; adaptive thinking set explicitly (omitting
//    it runs without thinking on Opus 4.8); no sampling params (400 on 4.8).
//  • system + tools carry a cache_control breakpoint so multi-turn chats hit
//    the prompt cache; the date is fixed per conversation to keep bytes stable.
//  • Assistant content blocks (including thinking blocks) are echoed back
//    VERBATIM on subsequent turns — required for multi-turn with thinking.
//  • Parallel tool_use blocks all return in ONE user message, is_error on
//    failures; stop_reason "refusal" is handled before reading content.
//

import Foundation
import Observation

/// One rendered chat entry (UI model; the raw API history is kept separately).
struct ChatEntry: Identifiable {
    enum Kind {
        case user
        case assistant
        case toolCall(name: String)
        case notice
    }

    let id = UUID()
    let kind: Kind
    var text: String
}

@MainActor
@Observable
final class ClaudeChatController {
    enum Phase: Equatable {
        case idle
        case streaming
        case runningTools(String)
        case error(String)
    }

    var entries: [ChatEntry] = []
    var phase: Phase = .idle
    var hasKey: Bool = ClaudeAuth.apiKey() != nil
    var inputTokens = 0
    var outputTokens = 0

    var model: String {
        get { UserDefaults.standard.string(forKey: "claude.model") ?? "claude-sonnet-5" }
        set { UserDefaults.standard.set(newValue, forKey: "claude.model") }
    }

    static let models: [(id: String, label: String)] = [
        ("claude-sonnet-5", "Sonnet 5 — fast, near-Opus quality (default)"),
        ("claude-opus-4-8", "Opus 4.8 — most capable, 5× Sonnet's price"),
        ("claude-haiku-4-5", "Haiku 4.5 — fastest, cheapest"),
    ]

    init() {
        // 2026-07-11: the app previously defaulted to Opus 4.8 (which is why
        // Opus dominated the first cost reports). Jason wants Sonnet as the
        // Hyperview default — switch the stored value once; the Settings
        // picker still allows Opus per-conversation.
        if !UserDefaults.standard.bool(forKey: "claude.model.sonnetDefaultMigrated") {
            UserDefaults.standard.set("claude-sonnet-5", forKey: "claude.model")
            UserDefaults.standard.set(true, forKey: "claude.model.sonnetDefaultMigrated")
        }
    }

    /// Raw API message history: [{role, content}] echoed verbatim.
    @ObservationIgnored private var apiMessages: [[String: Any]] = []
    /// Fixed per conversation so the cached system prefix stays byte-stable.
    @ObservationIgnored private var conversationDate = ""
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private weak var mcp: MCPController?

    func attach(mcp: MCPController) {
        self.mcp = mcp
    }

    func refreshKeyState() {
        hasKey = ClaudeAuth.apiKey() != nil
    }

    func clearConversation() {
        currentTask?.cancel()
        entries = []
        apiMessages = []
        conversationDate = ""
        inputTokens = 0
        outputTokens = 0
        phase = .idle
    }

    func stop() {
        currentTask?.cancel()
        phase = .idle
    }

    // MARK: - Send

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .idle || isErrorPhase else { return }
        guard ClaudeAuth.apiKey() != nil else {
            phase = .error("Add your Anthropic API key in settings first.")
            return
        }
        if conversationDate.isEmpty {
            conversationDate = Date().formatted(date: .complete, time: .shortened)
        }
        entries.append(ChatEntry(kind: .user, text: trimmed))
        apiMessages.append(["role": "user", "content": trimmed])

        currentTask = Task { await runLoop() }
    }

    private var isErrorPhase: Bool {
        if case .error = phase { return true }
        return false
    }

    // MARK: - The agentic loop

    private func runLoop() async {
        guard let apiKey = ClaudeAuth.apiKey() else { return }

        for _ in 0..<12 { // hard cap on tool iterations per user turn
            phase = .streaming
            entries.append(ChatEntry(kind: .assistant, text: ""))
            let entryIndex = entries.count - 1

            let turn: StreamedTurn
            do {
                turn = try await streamOnce(apiKey: apiKey) { [weak self] delta in
                    self?.entries[entryIndex].text += delta
                }
            } catch is CancellationError {
                phase = .idle
                return
            } catch {
                entries.removeLast() // drop the empty bubble
                phase = .error(Self.describe(error))
                return
            }

            if entries[entryIndex].text.isEmpty { entries.remove(at: entryIndex) }
            inputTokens += turn.inputTokens
            outputTokens += turn.outputTokens
            UsageLedger.record(
                model: model,
                input: turn.inputTokens,
                output: turn.outputTokens,
                cacheRead: turn.cacheReadTokens,
                cacheWrite: turn.cacheWriteTokens,
                source: "chat"
            )

            // Echo assistant content back verbatim (thinking blocks included).
            apiMessages.append(["role": "assistant", "content": turn.contentBlocks])

            switch turn.stopReason {
            case "tool_use":
                let toolUses = turn.contentBlocks.filter { ($0["type"] as? String) == "tool_use" }
                var results: [[String: Any]] = []
                for use in toolUses {
                    guard let name = use["name"] as? String,
                          let id = use["id"] as? String else { continue }
                    phase = .runningTools(name)
                    entries.append(ChatEntry(kind: .toolCall(name: name), text: ""))
                    let arguments = (use["input"] as? [String: Any]) ?? [:]
                    let outcome = await runTool(name: name, arguments: arguments)
                    results.append([
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": String(outcome.content.prefix(40_000)),
                        "is_error": !outcome.ok,
                    ])
                }
                // ALL tool results go back in a single user message.
                apiMessages.append(["role": "user", "content": results])
                continue

            case "refusal":
                entries.append(ChatEntry(kind: .notice, text: "Claude declined this request."))
                phase = .idle
                return

            case "max_tokens":
                entries.append(ChatEntry(kind: .notice, text: "Response hit the length limit."))
                phase = .idle
                return

            default: // end_turn
                phase = .idle
                return
            }
        }
        entries.append(ChatEntry(kind: .notice, text: "Stopped after the maximum number of tool steps."))
        phase = .idle
    }

    private func runTool(name: String, arguments: [String: Any]) async -> (ok: Bool, content: String) {
        guard let executor = mcp?.executor else {
            return (false, "Hyperview's tool layer is unavailable.")
        }
        return await executor.execute(name: name, arguments: arguments)
    }

    // MARK: - One streaming request

    private struct StreamedTurn {
        var contentBlocks: [[String: Any]]
        var stopReason: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
    }

    private func streamOnce(
        apiKey: String,
        onTextDelta: @escaping (String) -> Void
    ) async throws -> StreamedTurn {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 600

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 64000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "system": [[
                "type": "text",
                "text": systemPrompt,
                "cache_control": ["type": "ephemeral"],
            ]],
            "tools": Self.apiTools,
            "messages": apiMessages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeChatError.transport }
        guard http.statusCode == 200 else {
            var errorBody = Data()
            for try await byte in bytes { errorBody.append(byte); if errorBody.count > 8192 { break } }
            throw ClaudeChatError.api(status: http.statusCode, body: String(decoding: errorBody, as: UTF8.self))
        }

        // SSE parse + content-block reconstruction (thinking/signature/tool
        // input deltas all captured so blocks echo back complete).
        var blocks: [[String: Any]] = []
        var partialToolJSON: [Int: String] = [:]
        var stopReason = "end_turn"
        var inTokens = 0
        var outTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = Data(line.dropFirst(6).utf8)
            guard let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "message_start":
                if let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    inTokens = (usage["input_tokens"] as? Int) ?? 0
                    cacheReadTokens = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    cacheWriteTokens = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                }

            case "content_block_start":
                guard let index = event["index"] as? Int,
                      let block = event["content_block"] as? [String: Any] else { continue }
                while blocks.count <= index { blocks.append([:]) }
                blocks[index] = block

            case "content_block_delta":
                guard let index = event["index"] as? Int, index < blocks.count,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { continue }
                switch deltaType {
                case "text_delta":
                    let text = (delta["text"] as? String) ?? ""
                    blocks[index]["text"] = ((blocks[index]["text"] as? String) ?? "") + text
                    onTextDelta(text)
                case "thinking_delta":
                    let text = (delta["thinking"] as? String) ?? ""
                    blocks[index]["thinking"] = ((blocks[index]["thinking"] as? String) ?? "") + text
                case "signature_delta":
                    blocks[index]["signature"] = (delta["signature"] as? String) ?? ""
                case "input_json_delta":
                    partialToolJSON[index, default: ""] += (delta["partial_json"] as? String) ?? ""
                default:
                    break
                }

            case "content_block_stop":
                if let index = event["index"] as? Int,
                   let json = partialToolJSON[index],
                   let input = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                    blocks[index]["input"] = input
                }

            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
                if let usage = event["usage"] as? [String: Any] {
                    outTokens = (usage["output_tokens"] as? Int) ?? outTokens
                }

            case "error":
                let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "stream error"
                throw ClaudeChatError.api(status: 200, body: message)

            case "message_stop":
                break

            default:
                break
            }
        }

        return StreamedTurn(
            contentBlocks: blocks.filter { !$0.isEmpty },
            stopReason: stopReason,
            inputTokens: inTokens,
            outputTokens: outTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens
        )
    }

    // MARK: - Prompt & tools

    private var systemPrompt: String {
        """
        You are Claude, embedded inside Hyperview — the user's personal data \
        app on their Mac. You have tools for their notes, mail (multiple \
        accounts), calendar, reminders, contacts, and photos. Use them freely \
        to answer questions and take actions; prefer fetching real data over \
        guessing. Mail can only be drafted, never sent — the user reviews and \
        sends in the app. Be concise and lead with the answer. The user's \
        name is Jason. Conversation started: \(conversationDate).
        """
    }

    /// The MCP registry converted to Messages-API tool definitions.
    private static let apiTools: [[String: Any]] = MCPToolRegistry.tools.map { tool in
        [
            "name": tool.name,
            "description": tool.description,
            "input_schema": MCPValue.object(tool.schema).jsonObject,
        ]
    }

    // MARK: - Errors

    private static func describe(_ error: Error) -> String {
        if let chatError = error as? ClaudeChatError {
            switch chatError {
            case .transport:
                return "Couldn't reach the Anthropic API — check your connection."
            case .api(let status, let body):
                if status == 401 { return "The API key was rejected — check it in settings." }
                if status == 429 { return "Rate limited — wait a moment and try again." }
                if status == 529 { return "The API is overloaded — try again shortly." }
                if let data = body.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let inner = parsed["error"] as? [String: Any],
                   let message = inner["message"] as? String {
                    return message
                }
                return "API error (\(status))."
            }
        }
        return error.localizedDescription
    }
}

nonisolated enum ClaudeChatError: Error {
    case transport
    case api(status: Int, body: String)
}
