import Foundation
import SwiftUI

struct MessageTextHighlight: Equatable {
    let messageID: String
    let query: String
}

func highlightedAttributedString(_ text: String, query: String?) -> AttributedString {
    highlightedAttributedString(AttributedString(text), query: query)
}

func highlightedAttributedString(_ source: AttributedString, query: String?) -> AttributedString {
    guard let query else { return source }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return source }

    var result = source
    let plainText = String(result.characters)
    var searchStart = plainText.startIndex
    while searchStart < plainText.endIndex,
          let match = plainText.range(
              of: trimmed,
              options: [.caseInsensitive, .diacriticInsensitive],
              range: searchStart..<plainText.endIndex
          ) {
        guard let lower = AttributedString.Index(match.lowerBound, within: result),
              let upper = AttributedString.Index(match.upperBound, within: result) else { break }
        result[lower..<upper].foregroundColor = .white
        result[lower..<upper].backgroundColor = .blue
        searchStart = match.upperBound
    }
    return result
}

enum ConnectionMode: String, CaseIterable, Identifiable, Codable {
    case automatic
    case lan
    case tailscale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .lan: return "局域网"
        case .tailscale: return "Tailscale"
        }
    }
}

struct HealthResponse: Codable {
    let ok: Bool
    let codexConnected: Bool?
}

struct ConnectionHistoryItem: Codable, Identifiable, Equatable {
    let id: String
    let serverURL: String
    let token: String
    let connectionMode: ConnectionMode
    var lastUsedAt: Double

    init(serverURL: String, token: String, connectionMode: ConnectionMode, lastUsedAt: Double = Date().timeIntervalSince1970) {
        self.id = "\(serverURL)|\(token)"
        self.serverURL = serverURL
        self.token = token
        self.connectionMode = connectionMode
        self.lastUsedAt = lastUsedAt
    }

    var maskedToken: String {
        let characters = Array(token)
        guard characters.count > 8 else {
            guard characters.count > 4 else { return String(repeating: "•", count: max(4, characters.count)) }
            return "\(String(characters.prefix(4)))••••\(String(characters.suffix(4)))"
        }
        return "\(token.prefix(4))••••\(token.suffix(4))"
    }
}

struct ProjectsResponse: Codable {
    let data: [CloudexProject]
    let total: Int?
}

struct ProjectSnapshot: Codable {
    let projects: [CloudexProject]
}

struct ApprovalsResponse: Codable {
    let data: [ApprovalRequest]
}

struct ApprovalResolvedEvent: Codable {
    let id: String
    let threadId: String?
    let decision: String?
    let approval: ApprovalRequest?
}

enum ApprovalDecision: String {
    case accept
    case acceptForSession
    case decline

    var systemTitle: String {
        switch self {
        case .accept: return "用户已允许操作"
        case .acceptForSession: return "用户已永久允许当前会话"
        case .decline: return "用户已禁止操作"
        }
    }
}

struct ApprovalRequest: Codable, Identifiable, Equatable {
    let id: String
    let method: String
    let threadId: String?
    let turnId: String?
    let itemId: String?
    let reason: String?
    let command: String?
    let cwd: String?
    let grantRoot: String?
    let networkApprovalContext: NetworkApprovalContext?
    let availableDecisions: [String]?
    let permissionSummary: String?
    let requestedAt: Double?

    var isFileChange: Bool { method == "item/fileChange/requestApproval" }
    var isPermissionRequest: Bool { method == "item/permissions/requestApproval" }

    func supports(_ decision: ApprovalDecision) -> Bool {
        // Cloudex exposes the complete approval policy even when Codex omits
        // optional decisions from availableDecisions for a specific request.
        // Keep all three actions tappable; the server remains authoritative.
        return true
    }
}

struct NetworkApprovalContext: Codable, Equatable {
    let host: String?
    let protocolName: String?
    let port: Int?

    private enum CodingKeys: String, CodingKey {
        case host
        case protocolName = "protocol"
        case port
    }
}

struct CloudexProject: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let cwd: String
    let threads: [CloudexThread]
    let updatedAt: Double?

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let components = cwd.split(separator: "/").map(String.init)
        if let last = components.last { return last }
        if components.count >= 2 {
            return "\(components[components.count - 2]) / \(components[components.count - 1])"
        }
        return trimmed.isEmpty ? "未命名项目" : trimmed
    }

    var isNoProjectLike: Bool {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "未指定项目目录" { return true }
        if trimmed.contains("/Documents/Codex/") || trimmed.hasSuffix("/Documents/Codex") { return true }
        if trimmed.contains("/.codex/") { return true }
        return false
    }
}

struct CloudexThread: Codable, Identifiable, Equatable {
    let id: String
    let name: String?
    let preview: String?
    let cwd: String?
    let status: ThreadStatus?
    let model: String?
    let createdAt: Double?
    let updatedAt: Double?
    let usage: CloudexUsage?

    var title: String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty, !Self.isNoiseTitle(value) { return value }
        let fallback = preview?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty { return fallback }
        return "未命名对话"
    }

    var isActive: Bool { status?.type == "active" }

    private static func isNoiseTitle(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["exec", "apply_patch", "tool", "command"].contains(normalized)
    }
}

struct CloudexUsage: Codable, Equatable {
    let total: TokenUsage?
    let last: TokenUsage?
    let modelContextWindow: Int?
    let updatedAt: Double?

    private enum CodingKeys: String, CodingKey {
        case total
        case last
        case modelContextWindow
        case modelContextWindowSnake = "model_context_window"
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decodeIfPresent(TokenUsage.self, forKey: .total)
        last = try container.decodeIfPresent(TokenUsage.self, forKey: .last)
        let camelContextWindow = try container.decodeIfPresent(Int.self, forKey: .modelContextWindow)
        let snakeContextWindow = try container.decodeIfPresent(Int.self, forKey: .modelContextWindowSnake)
        modelContextWindow = camelContextWindow ?? snakeContextWindow
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(total, forKey: .total)
        try container.encodeIfPresent(last, forKey: .last)
        try container.encodeIfPresent(modelContextWindow, forKey: .modelContextWindow)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

struct TokenUsage: Codable, Equatable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?
    let totalTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case cachedInputTokens
        case outputTokens
        case reasoningOutputTokens
        case totalTokens
        case inputTokensSnake = "input_tokens"
        case cachedInputTokensSnake = "cached_input_tokens"
        case outputTokensSnake = "output_tokens"
        case reasoningOutputTokensSnake = "reasoning_output_tokens"
        case totalTokensSnake = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let camelInput = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        let snakeInput = try container.decodeIfPresent(Int.self, forKey: .inputTokensSnake)
        inputTokens = camelInput ?? snakeInput
        let camelCachedInput = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens)
        let snakeCachedInput = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokensSnake)
        cachedInputTokens = camelCachedInput ?? snakeCachedInput
        let camelOutput = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        let snakeOutput = try container.decodeIfPresent(Int.self, forKey: .outputTokensSnake)
        outputTokens = camelOutput ?? snakeOutput
        let camelReasoningOutput = try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens)
        let snakeReasoningOutput = try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokensSnake)
        reasoningOutputTokens = camelReasoningOutput ?? snakeReasoningOutput
        let camelTotal = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        let snakeTotal = try container.decodeIfPresent(Int.self, forKey: .totalTokensSnake)
        totalTokens = camelTotal ?? snakeTotal
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try container.encodeIfPresent(cachedInputTokens, forKey: .cachedInputTokens)
        try container.encodeIfPresent(outputTokens, forKey: .outputTokens)
        try container.encodeIfPresent(reasoningOutputTokens, forKey: .reasoningOutputTokens)
        try container.encodeIfPresent(totalTokens, forKey: .totalTokens)
    }
}

struct ThreadStatus: Codable, Equatable {
    let type: String?
    let activeFlags: [String]?
}

struct ThreadDetail: Codable, Equatable {
    let thread: CloudexThread
    let turns: [CloudexTurn]
    var hasMoreBefore: Bool? = nil
    var nextBefore: String? = nil
}

struct MessageIndexResponse: Codable {
    let data: [MessageIndexItem]
}

struct MessageIndexItem: Codable, Identifiable, Equatable {
    let id: String
    let turnId: String
    let role: String
    let text: String
    let createdAt: Double?
}

struct ConversationSearchResponse: Codable {
    let data: [ConversationSearchMatch]
}

struct ConversationSearchMatch: Codable, Identifiable, Equatable {
    let id: String
    let threadId: String
    let messageId: String
    let turnId: String
    let role: String
    let text: String
    let snippet: String
    let createdAt: Double?
}

struct PendingMessageJump: Equatable {
    let threadID: String
    let messageID: String
    let turnID: String
    let query: String
}

struct ThreadNavigationRequest: Equatable {
    let id = UUID()
    let threadID: String
}

struct CloudexTurn: Codable, Equatable {
    let id: String
    let items: [TurnItem]?
    let status: String?
    let error: TurnErrorPayload?
    let startedAt: Double?
    let completedAt: Double?
    let durationMs: Double?
    let compressed: Bool?
    let itemsView: String?
    var processItemCount: Int? = nil
    var detailsLoaded: Bool? = nil

    var processDetailsAreLoaded: Bool {
        if let detailsLoaded { return detailsLoaded }
        switch itemsView?.lowercased() {
        case "full": return true
        case "compact": return false
        default: return (processItemCount ?? 0) == 0
        }
    }
}

struct TurnDetailResponse: Codable {
    let turn: CloudexTurn
}

struct TurnItem: Codable, Equatable {
    let type: String
    let id: String?
    let text: String?
    let content: [TurnContent]?
    let command: String?
    let activity: String?
    let status: String?
    let exitCode: Int?
    let duration: String?
    let phase: String?
    let createdAt: Double?
    let compressed: Bool?
    let diff: [EditDiffPayload]?

    var renderedText: String {
        if type == "userMessage" {
            return (content ?? []).compactMap { $0.text ?? $0.value }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let textValue = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !textValue.isEmpty { return textValue }
        return (content ?? []).compactMap { $0.text ?? $0.value }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isCompressed: Bool {
        if compressed == true { return true }
        let normalized = type.lowercased()
        return normalized.contains("compressed") || normalized.contains("compaction") || normalized.contains("compact")
    }
}

struct EditDiffPayload: Codable, Equatable, Sendable {
    let name: String
    let additions: Int?
    let deletions: Int?
    let lines: [EditDiffLinePayload]?
}

struct EditDiffLinePayload: Codable, Equatable, Identifiable, Sendable {
    let kind: String
    let text: String
    let lineNumber: Int?

    var id: String { "\(kind)-\(lineNumber ?? -1)-\(text)" }
}

struct TurnContent: Codable, Equatable {
    let type: String?
    let text: String?
    let value: String?
}

struct TurnErrorPayload: Codable, Equatable {
    let message: String
    let code: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case codexErrorInfo
        case codexErrorInfoSnake = "codex_error_info"
        case code
        case type
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            message = value
            code = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = (try? container.decode(String.self, forKey: .message)) ?? "任务执行失败"
        code = (try? container.decode(String.self, forKey: .codexErrorInfo))
            ?? (try? container.decode(String.self, forKey: .codexErrorInfoSnake))
            ?? (try? container.decode(String.self, forKey: .code))
            ?? (try? container.decode(String.self, forKey: .type))
    }

    var displayText: String {
        [message, code.map { "错误代码：\($0)" }].compactMap { $0 }.joined(separator: "\n")
    }

    private enum EncodingKeys: String, CodingKey {
        case message
        case codexErrorInfo = "codexErrorInfo"
        case codexErrorInfoSnake = "codex_error_info"
        case code
        case type
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EncodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(code, forKey: .codexErrorInfo)
    }
}

struct ModelsResponse: Codable {
    let data: [CodexModel]
}

struct CodexModel: Codable, Equatable {
    let rawID: String?
    let model: String?
    let displayName: String?
    let hidden: Bool?
    let isDefault: Bool?
    let supportedReasoningEfforts: [ReasoningEffortOption]?
    let defaultReasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case rawID = "id"
        case model
        case displayName
        case hidden
        case isDefault
        case supportedReasoningEfforts
        case supportedReasoningLevels
        case supportedReasoningLevelsSnake = "supported_reasoning_levels"
        case defaultReasoningEffort
        case defaultReasoningLevel
        case defaultReasoningLevelSnake = "default_reasoning_level"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawID = try container.decodeIfPresent(String.self, forKey: .rawID)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault)
        let nativeEfforts = try container.decodeIfPresent([ReasoningEffortOption].self, forKey: .supportedReasoningEfforts)
        let camelLevels = try container.decodeIfPresent([ReasoningEffortOption].self, forKey: .supportedReasoningLevels)
        let snakeLevels = try container.decodeIfPresent([ReasoningEffortOption].self, forKey: .supportedReasoningLevelsSnake)
        supportedReasoningEfforts = nativeEfforts ?? camelLevels ?? snakeLevels
        let nativeDefault = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
        let camelDefault = try container.decodeIfPresent(String.self, forKey: .defaultReasoningLevel)
        let snakeDefault = try container.decodeIfPresent(String.self, forKey: .defaultReasoningLevelSnake)
        defaultReasoningEffort = nativeDefault ?? camelDefault ?? snakeDefault
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rawID, forKey: .rawID)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(hidden, forKey: .hidden)
        try container.encodeIfPresent(isDefault, forKey: .isDefault)
        try container.encodeIfPresent(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
        try container.encodeIfPresent(defaultReasoningEffort, forKey: .defaultReasoningEffort)
    }

    var identifier: String { rawID ?? model ?? displayName ?? "unknown" }
    var title: String { displayName ?? model ?? rawID ?? "未知模型" }
}

struct ReasoningEffortOption: Codable, Equatable, Identifiable {
    let reasoningEffort: String
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case reasoningEffort
        case effort
        case reasoningLevel = "reasoning_level"
        case level
        case description
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let value = try? single.decode(String.self) {
            reasoningEffort = value
            description = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let native = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        let effort = try container.decodeIfPresent(String.self, forKey: .effort)
        let snakeLevel = try container.decodeIfPresent(String.self, forKey: .reasoningLevel)
        let level = try container.decodeIfPresent(String.self, forKey: .level)
        guard let reasoningEffort = native ?? effort ?? snakeLevel ?? level else {
            throw DecodingError.dataCorruptedError(forKey: .reasoningEffort, in: container,
                                                   debugDescription: "Missing reasoning effort")
        }
        self.reasoningEffort = reasoningEffort
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(description, forKey: .description)
    }

    var id: String { reasoningEffort }

    var title: String {
        switch reasoningEffort {
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "超高"
        case "max": return "最大"
        case "ultra": return "极限"
        default: return reasoningEffort
        }
    }
}

struct CreateThreadResponse: Codable {
    let thread: CloudexThread
}

struct ForkThreadResponse: Codable {
    let thread: CloudexThread
}

struct EmptyResponse: Codable {}

struct ApprovalResponse: Codable {
    let ok: Bool
}

struct RemoteFilesResponse: Codable {
    let path: String
    let entries: [RemoteFileEntry]
}

struct RemoteFileEntry: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let type: String
    let size: Double?
    let modifiedAt: String?
    let selectable: Bool?

    var id: String { path }
    var isDirectory: Bool { type == "directory" }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
        case error
        case system
        case execution
        case processSummary
        case compressed
        case taskSummary
    }

    let id: String
    let role: Role
    let text: String
    var executionStatus: String? = nil
    var executionDuration: String? = nil
    var executionExitCode: Int? = nil
    var executionKind: String? = nil
    var editDiff: [EditDiffPayload]? = nil
    var processItems: [ChatMessage]? = nil
    var createdAt: Double? = nil
    var isCompressed: Bool = false
    var threadID: String? = nil
    var sourceTurnID: String? = nil
    var processItemCount: Int? = nil
    var processDetailsLoaded: Bool = true
}

struct SSEEvent {
    let id: String?
    let name: String
    let data: Data
}

enum DateFormatting {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static let messageFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func string(from timestamp: Double?) -> String {
        guard let timestamp, timestamp > 0 else { return "" }
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func messageTime(from timestamp: Double?) -> String {
        guard let timestamp, timestamp > 0 else { return "" }
        return messageFormatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func duration(fromMilliseconds milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds >= 0 else { return "" }
        return duration(fromSeconds: milliseconds / 1000)
    }

    static func duration(fromSeconds seconds: Double?) -> String {
        guard let seconds, seconds >= 0 else { return "" }
        let rounded = Int(seconds.rounded())
        if rounded < 60 { return "\(rounded)秒" }
        let minutes = rounded / 60
        let remainingSeconds = rounded % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes)分" : "\(minutes)分\(remainingSeconds)秒"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 { return "\(hours)小时" }
        return "\(hours)小时\(remainingMinutes)分"
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
