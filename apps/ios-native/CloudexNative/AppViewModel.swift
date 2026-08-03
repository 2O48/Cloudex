import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var serverURL: String
    @Published var lanServerURL: String
    @Published var tailscaleServerURL: String
    @Published var connectionMode: ConnectionMode
    @Published var authToken: String
    @Published var selectedModelID: String
    @Published var selectedEffortID: String
    @Published var projects: [CloudexProject] = []
    @Published var renderedMessages: [ChatMessage] = []
    @Published var models: [CodexModel] = []
    @Published var selectedProjectCWD: String?
    @Published var selectedThreadID: String?
    @Published var detail: ThreadDetail? { didSet { rebuildRenderedMessages() } }
    @Published var draft = ""
    @Published var status = "未连接"
    @Published var isServerReachable = false
    @Published var isBusy = false
    @Published var isCreatingNew = false
    @Published var liveMessages: [ChatMessage] = [] { didSet { rebuildRenderedMessages() } }
    @Published var liveRunning = false
    @Published var localError: String? { didSet { rebuildRenderedMessages() } }
    @Published var attachedFiles: [RemoteFileEntry] = []
    @Published var pendingApprovals: [ApprovalRequest] = []
    @Published var systemMessages: [ChatMessage] = [] { didSet { rebuildRenderedMessages() } }
    @Published var notifyApprovals: Bool
    @Published var notifyTaskSuccess: Bool
    @Published var notifyTaskFailure: Bool

    private let globalSSE = SSEClient()
    private let threadSSE = SSEClient()
    private let conversationCache = LocalConversationCache.shared
    private var pollTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var modelsLoaded = false
    private var modelsLoading = false
    private var started = false
    private var streamsStarted = false
    private var lastThreadEventID = 0
    private var detailLoadGeneration = 0
    private var liveMessageTurnIDs: [String: String] = [:]

    init() {
        let defaults = UserDefaults.standard
        let savedServerURL = defaults.string(forKey: "cloudex.serverURL") ?? ""
        let savedLANURL = defaults.string(forKey: "cloudex.lanServerURL") ?? ""
        let savedTailscaleURL = defaults.string(forKey: "cloudex.tailscaleServerURL") ?? ""
        let savedToken = defaults.string(forKey: "cloudex.authToken") ?? ""
#if targetEnvironment(simulator)
        let defaultLANURL = "http://127.0.0.1:8787"
#else
        let defaultLANURL = savedServerURL.isEmpty || savedServerURL.contains("127.0.0.1") || savedServerURL.contains("localhost")
            ? "http://192.168.31.104:8787"
            : savedServerURL
#endif
        let initialLANURL = savedLANURL.isEmpty ? defaultLANURL : savedLANURL
        let initialTailscaleURL = savedTailscaleURL.isEmpty || savedTailscaleURL.contains("2o48demac-mini.tail83d612.ts.net")
            ? "http://100.68.96.121:8787"
            : savedTailscaleURL
        let initialConnectionMode = ConnectionMode(rawValue: defaults.string(forKey: "cloudex.connectionMode") ?? "") ?? .automatic
        lanServerURL = initialLANURL
        tailscaleServerURL = initialTailscaleURL
        connectionMode = initialConnectionMode
        serverURL = initialConnectionMode == .tailscale ? initialTailscaleURL : initialLANURL
        authToken = savedToken.isEmpty || savedToken == "lW0FcVb_finDkfBpW0wHKtGh6lmAXw1t"
            ? "GASPMZC_06BAFN2o0T9rY3BNTtAhsVTu"
            : savedToken
        selectedModelID = defaults.string(forKey: "cloudex.model") ?? ""
        selectedEffortID = defaults.string(forKey: "cloudex.effort") ?? ""
        notifyApprovals = defaults.object(forKey: "cloudex.notifyApprovals") as? Bool ?? true
        notifyTaskSuccess = defaults.object(forKey: "cloudex.notifyTaskSuccess") as? Bool ?? true
        notifyTaskFailure = defaults.object(forKey: "cloudex.notifyTaskFailure") as? Bool ?? true
        defaults.set(lanServerURL, forKey: "cloudex.serverURL")
        defaults.set(lanServerURL, forKey: "cloudex.lanServerURL")
        defaults.set(tailscaleServerURL, forKey: "cloudex.tailscaleServerURL")
        defaults.set(connectionMode.rawValue, forKey: "cloudex.connectionMode")
        defaults.set(authToken, forKey: "cloudex.authToken")
        projects = conversationCache.loadProjects() ?? []
        rebuildRenderedMessages()
    }

    var client: APIClient { APIClient(serverURL: serverURL, token: authToken) }
    var activeConnectionTitle: String {
        serverURL == normalizedURL(tailscaleServerURL) ? "Tailscale" : "局域网"
    }
    var selectedProject: CloudexProject? { projects.first { $0.cwd == selectedProjectCWD } }
    var selectedThread: CloudexThread? { detail?.thread }
    var allThreads: [CloudexThread] { projects.flatMap(\.threads) }
    var isConnected: Bool { isServerReachable }
    var active: Bool { liveRunning || selectedThread?.isActive == true }
    var selectedModel: CodexModel? { models.first { $0.identifier == selectedModelID } }
    var availableEfforts: [ReasoningEffortOption] { selectedModel?.supportedReasoningEfforts ?? [] }
    var selectedEffortTitle: String {
        availableEfforts.first { $0.reasoningEffort == selectedEffortID }?.title ?? "默认"
    }
    var compactModelTitle: String {
        let title = selectedModel?.title ?? (modelsLoading ? "读取中" : "模型")
        return title
            .replacingOccurrences(of: "GPT-", with: "")
            .replacingOccurrences(of: "gpt-", with: "")
    }
    var visibleApprovals: [ApprovalRequest] {
        guard let selectedThreadID else { return pendingApprovals }
        return pendingApprovals.sorted { left, right in
            let leftMatches = left.threadId == nil || left.threadId == selectedThreadID
            let rightMatches = right.threadId == nil || right.threadId == selectedThreadID
            if leftMatches != rightMatches { return leftMatches }
            return (left.requestedAt ?? 0) < (right.requestedAt ?? 0)
        }
    }

    var navigationTitle: String {
        if isCreatingNew { return "新对话" }
        return selectedThread?.title ?? "Cloudex"
    }

    var projectTitle: String { selectedProject?.displayName ?? "选择项目" }

    var messages: [ChatMessage] {
        renderedMessages
    }

    private func buildMessages() -> [ChatMessage] {
        var result: [ChatMessage] = []
        for turn in detail?.turns ?? [] {
            let items = turn.items ?? []
            let shouldFoldProcess = turn.status != nil && turn.status != "inProgress"
            let durationMessage = taskDurationMessage(for: turn)
            let compressedMessage = compressedMessage(for: turn)
            if shouldFoldProcess {
                let finalAgentIndex = items.lastIndex(where: { $0.type == "agentMessage" && $0.phase == "final_answer" })
                    ?? items.lastIndex(where: { $0.type == "agentMessage" })
                var processItems: [ChatMessage] = []
                var finalMessage: ChatMessage?

                for (index, item) in items.enumerated() {
                    guard let message = timelineMessage(from: item, turnID: turn.id, fallbackIndex: index) else { continue }
                    if item.type == "userMessage" {
                        result.append(message)
                    } else if index == finalAgentIndex {
                        finalMessage = message
                    } else {
                        processItems.append(message)
                    }
                }
                // Keep the fine-grained execution rows captured from the live
                // event stream even when the persisted session omits them.
                let existingProcessIDs = Set(processItems.map(\.id))
                processItems.append(contentsOf: liveMessages.filter {
                    $0.role == .execution
                        && liveMessageTurnIDs[$0.id] == turn.id
                        && !existingProcessIDs.contains($0.id)
                })
                if let compressedMessage { processItems.append(compressedMessage) }
                if let durationMessage { processItems.append(durationMessage) }
                processItems = mergeSemanticExecutionItems(processItems)

                if !processItems.isEmpty {
                    result.append(ChatMessage(
                        id: "\(turn.id)-process-summary",
                        role: .processSummary,
                        text: processSummaryText(processItems),
                        processItems: processItems,
                        createdAt: processItems.compactMap(\.createdAt).min()
                    ))
                }
                if let finalMessage { result.append(finalMessage) }
            } else {
                for (index, item) in items.enumerated() {
                    if let message = timelineMessage(from: item, turnID: turn.id, fallbackIndex: index) {
                        result.append(message)
                    }
                }
                if let durationMessage { result.append(durationMessage) }
                if let compressedMessage { result.append(compressedMessage) }
            }
            if let error = turn.error {
                result.append(ChatMessage(
                    id: "\(turn.id)-error",
                    role: .error,
                    text: error.displayText,
                    createdAt: turn.completedAt ?? turn.startedAt
                ))
            }
        }
        if let localError, !localError.isEmpty {
            result.append(ChatMessage(
                id: "local-error",
                role: .error,
                text: localError,
                createdAt: Date().timeIntervalSince1970
            ))
        }
        result.append(contentsOf: systemMessages.filter { $0.threadID == nil || $0.threadID == selectedThreadID })
        result.append(contentsOf: liveMessages.filter { message in
            guard message.role == .execution,
                  let turnID = liveMessageTurnIDs[message.id],
                  let turn = detail?.turns.first(where: { $0.id == turnID }) else { return true }
            return turn.status == "inProgress"
        })
        return mergeSemanticExecutionItems(result).enumerated().sorted { lhs, rhs in
            switch (lhs.element.createdAt, rhs.element.createdAt) {
            case let (left?, right?):
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func rebuildRenderedMessages() {
        renderedMessages = buildMessages()
    }

    private func timelineMessage(from item: TurnItem, turnID: String, fallbackIndex: Int) -> ChatMessage? {
        if item.isCompressed {
            return ChatMessage(
                id: item.id ?? "\(turnID)-compressed-\(fallbackIndex)",
                role: .compressed,
                text: item.renderedText.isEmpty ? "上下文已压缩" : item.renderedText,
                createdAt: item.createdAt,
                isCompressed: true
            )
        }
        if item.type == "commandExecution" || item.command != nil {
            guard let command = item.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
            let execution = semanticExecution(command: command, activity: item.activity, status: item.status)
            return ChatMessage(
                id: item.id ?? "\(turnID)-command-\(fallbackIndex)",
                role: .execution,
                text: execution.text,
                executionStatus: item.status,
                executionDuration: item.duration,
                executionExitCode: item.exitCode,
                executionKind: execution.kind,
                editDiff: item.diff,
                createdAt: item.createdAt
            )
        }
        guard item.type == "userMessage" || item.type == "agentMessage" else { return nil }
        if item.type == "agentMessage", shouldHidePersistedLiveMessage(item, turnID: turnID) { return nil }
        let text = item.renderedText
        guard !text.isEmpty else { return nil }
        return ChatMessage(
            id: item.id ?? "\(turnID)-\(item.type)-\(fallbackIndex)",
            role: item.type == "userMessage" ? .user : .assistant,
            text: text,
            createdAt: item.createdAt
        )
    }

    private func taskDurationMessage(for turn: CloudexTurn) -> ChatMessage? {
        guard turn.status != nil && turn.status != "inProgress" else { return nil }
        let duration = DateFormatting.duration(fromMilliseconds: turn.durationMs)
            .nilIfEmpty
            ?? DateFormatting.duration(fromSeconds: durationSeconds(for: turn)).nilIfEmpty
        guard let duration else { return nil }
        let statusText: String
        switch turn.status {
        case "failed": statusText = "任务失败"
        case "interrupted": statusText = "任务已中断"
        case "cancelled", "canceled": statusText = "任务已取消"
        default: statusText = "任务完成"
        }
        return ChatMessage(
            id: "\(turn.id)-duration",
            role: .taskSummary,
            text: "\(statusText) · 用时 \(duration)",
            createdAt: (turn.completedAt ?? turn.startedAt).map { $0 + 0.0001 }
        )
    }

    private func compressedMessage(for turn: CloudexTurn) -> ChatMessage? {
        guard turn.compressed == true || turn.itemsView == "compressed" else { return nil }
        return ChatMessage(
            id: "\(turn.id)-compressed",
            role: .compressed,
            text: "上下文已压缩",
            createdAt: turn.completedAt ?? turn.startedAt,
            isCompressed: true
        )
    }

    private func durationSeconds(for turn: CloudexTurn) -> Double? {
        guard let startedAt = turn.startedAt,
              let completedAt = turn.completedAt,
              completedAt >= startedAt else { return nil }
        return completedAt - startedAt
    }

    private func semanticExecution(command: String, activity: String?, status: String?) -> (text: String, kind: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let readTargets = readTargets(from: trimmed) {
            return ("Read \(joinedTargets(readTargets))", "read")
        }
        if let searchTargets = searchTargets(from: trimmed) {
            return ("Search \(joinedTargets(searchTargets))", "search")
        }
        if activity == "edited" {
            return ("Edited \(editedDisplay(from: trimmed))", "edit")
        }
        if activity == "explored" {
            return ("Explored \(joinedTargets(fileTargets(from: trimmed), fallback: trimmed))", "explore")
        }
        return ("\(status == "inProgress" ? "Running" : "Ran") \(trimmed)", "run")
    }

    private func editedDisplay(from command: String) -> String {
        if command.contains("\n") { return command }
        return joinedTargets(fileTargets(from: command), fallback: command)
    }

    private func readTargets(from command: String) -> [String]? {
        let first = firstCommandName(command)
        guard ["sed", "cat", "head", "tail"].contains(first) else { return nil }
        let targets = fileTargets(from: command)
        return targets.isEmpty ? ["files"] : targets
    }

    private func searchTargets(from command: String) -> [String]? {
        let first = firstCommandName(command)
        guard ["rg", "grep", "find", "fd"].contains(first) else { return nil }
        let targets = fileTargets(from: command)
        return targets.isEmpty ? ["workspace"] : targets
    }

    private func firstCommandName(_ command: String) -> String {
        let sanitized = command.replacingOccurrences(of: #"^\s*(?:[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'[^']*'|\S+)\s+)*"#, with: "", options: .regularExpression)
        let tokens = shellLikeTokens(sanitized)
        guard let first = tokens.first else { return "" }
        let name = (first as NSString).lastPathComponent
        return name.lowercased()
    }

    private func fileTargets(from command: String) -> [String] {
        let tokens = shellLikeTokens(command)
        let ignoredCommands = Set(["sed", "cat", "head", "tail", "rg", "grep", "find", "fd", "git", "ps", "aux", "ls", "pwd", "wc", "stat", "which"])
        let ignoredOptionArguments = Set(["-n", "-e", "-f", "-m", "-A", "-B", "-C", "--max-count", "--after-context", "--before-context", "--context", "--glob", "-g", "--type", "-t"])
        var values: [String] = []
        var skipNext = false
        for token in tokens {
            if skipNext {
                skipNext = false
                continue
            }
            if ignoredOptionArguments.contains(token) {
                skipNext = true
                continue
            }
            if token.hasPrefix("-") { continue }
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: ","))
            if bare.isEmpty { continue }
            if ignoredCommands.contains(bare.lowercased()) { continue }
            if bare.range(of: #"^\d+,\d+p$"#, options: .regularExpression) != nil { continue }
            if bare.range(of: #"^\d+p$"#, options: .regularExpression) != nil { continue }
            if bare.contains("/") || bare.contains(".") {
                let name = (bare as NSString).lastPathComponent
                if !name.isEmpty && !values.contains(name) { values.append(name) }
            }
        }
        return values
    }

    private func shellLikeTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace || character == "|" || character == ";" || character == "&" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private func joinedTargets(_ targets: [String], fallback: String? = nil) -> String {
        let cleaned = targets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = cleaned.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
        let values = unique.isEmpty ? fallback.map { [$0] } ?? [] : unique
        guard !values.isEmpty else { return "" }
        if values.count <= 4 { return values.joined(separator: ", ") }
        return "\(values.prefix(3).joined(separator: ", ")) and \(values.count - 3) more"
    }

    private func mergeSemanticExecutionItems(_ items: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var groupIndexes: [String: Int] = [:]
        for item in items {
            guard item.role == .execution,
                  let kind = item.executionKind,
                  ["read", "search"].contains(kind),
                  let createdAt = item.createdAt else {
                result.append(item)
                continue
            }
            let key = "\(kind)-\(Int((createdAt * 10).rounded()))"
            if let index = groupIndexes[key] {
                result[index] = mergedExecutionItem(result[index], with: item, kind: kind)
            } else {
                groupIndexes[key] = result.count
                result.append(item)
            }
        }
        return result
    }

    private func mergedExecutionItem(_ first: ChatMessage, with second: ChatMessage, kind: String) -> ChatMessage {
        let prefix = kind == "read" ? "Read " : "Search "
        let targets = (targetsText(from: first.text, prefix: prefix) + targetsText(from: second.text, prefix: prefix))
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        let status = first.executionStatus == "failed" || second.executionStatus == "failed"
            ? "failed"
            : (first.executionStatus == "inProgress" || second.executionStatus == "inProgress" ? "inProgress" : first.executionStatus ?? second.executionStatus)
        return ChatMessage(
            id: "\(first.id)-merged-\(second.id)",
            role: .execution,
            text: "\(prefix)\(joinedTargets(targets))",
            executionStatus: status,
            executionDuration: first.executionDuration ?? second.executionDuration,
            executionExitCode: first.executionExitCode ?? second.executionExitCode,
            executionKind: kind,
            createdAt: minTimestamp(first.createdAt, second.createdAt)
        )
    }

    private func targetsText(from text: String, prefix: String) -> [String] {
        guard text.hasPrefix(prefix) else { return [] }
        return text.dropFirst(prefix.count)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func minTimestamp(_ first: Double?, _ second: Double?) -> Double? {
        switch (first, second) {
        case let (left?, right?): return min(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func processSummaryText(_ items: [ChatMessage]) -> String {
        let read = items.filter { $0.role == .execution && $0.executionKind == "read" }.count
        let search = items.filter { $0.role == .execution && $0.executionKind == "search" }.count
        let explored = items.filter { $0.role == .execution && $0.executionKind == "explore" }.count
        let edited = items.filter { $0.role == .execution && $0.executionKind == "edit" }.count
        let ran = items.filter { $0.role == .execution && $0.executionKind == "run" }.count
        let messages = items.filter { $0.role == .assistant }.count
        let compressed = items.filter { $0.role == .compressed }.count
        let taskSummary = items.last { $0.role == .taskSummary }?.text
        var parts: [String] = []
        if read > 0 { parts.append("Read \(read)") }
        if search > 0 { parts.append("Search \(search)") }
        if explored > 0 { parts.append("Explored \(explored)") }
        if edited > 0 { parts.append("Edited \(edited)") }
        if ran > 0 { parts.append("Ran \(ran)") }
        if messages > 0 { parts.append("消息 \(messages)") }
        if compressed > 0 { parts.append("Compressed \(compressed)") }
        if let taskSummary, !taskSummary.isEmpty { parts.append(taskSummary) }
        return "查看过程（\(items.count)）" + (parts.isEmpty ? "" : " · \(parts.joined(separator: " · "))")
    }

    private func shouldHidePersistedLiveMessage(_ item: TurnItem, turnID: String) -> Bool {
        guard !liveMessages.isEmpty else { return false }
        if let id = item.id, liveMessages.contains(where: { $0.id == id }) { return true }
        let persisted = normalizedMessageText(item.renderedText)
        guard !persisted.isEmpty else { return false }
        return liveMessages.contains { message in
            guard liveMessageTurnIDs[message.id] == nil || liveMessageTurnIDs[message.id] == turnID else { return false }
            let streaming = normalizedMessageText(message.text)
            return !streaming.isEmpty && (streaming == persisted || streaming.hasPrefix(persisted))
        }
    }

    private func normalizedMessageText(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginLiveMessage(id: String, turnID: String?, text: String = "", createdAt: Double? = nil) {
        liveMessageTurnIDs[id] = turnID
        if let index = liveMessages.firstIndex(where: { $0.id == id }) {
            let previous = liveMessages[index]
            liveMessages[index] = ChatMessage(id: id, role: .assistant, text: text, createdAt: createdAt ?? previous.createdAt)
        } else {
            liveMessages.append(ChatMessage(id: id, role: .assistant, text: text, createdAt: createdAt ?? Date().timeIntervalSince1970))
        }
    }

    private func appendLiveDelta(id: String, turnID: String?, delta: String) {
        liveMessageTurnIDs[id] = turnID
        if let index = liveMessages.firstIndex(where: { $0.id == id }) {
            let previous = liveMessages[index]
            liveMessages[index] = ChatMessage(id: id, role: .assistant, text: previous.text + delta, createdAt: previous.createdAt)
        } else {
            liveMessages.append(ChatMessage(id: id, role: .assistant, text: delta, createdAt: Date().timeIntervalSince1970))
        }
    }

    private func upsertLiveExecution(item: [String: Any], turnID: String?, status: String) {
        guard let id = item["id"] as? String,
              let command = item["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let execution = semanticExecution(command: command, activity: nil, status: status)
        let duration: String? = {
            guard let milliseconds = (item["durationMs"] as? NSNumber)?.doubleValue else { return nil }
            return DateFormatting.duration(fromMilliseconds: milliseconds)
        }()
        let createdAt = ((item["startedAtMs"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000) / 1000
        let message = ChatMessage(
            id: id,
            role: .execution,
            text: execution.text,
            executionStatus: status,
            executionDuration: duration,
            executionExitCode: (item["exitCode"] as? NSNumber)?.intValue,
            executionKind: execution.kind,
            createdAt: createdAt
        )
        liveMessageTurnIDs[id] = turnID
        if let index = liveMessages.firstIndex(where: { $0.id == id }) {
            liveMessages[index] = message
        } else {
            liveMessages.append(message)
        }
    }

    private func clearLiveMessages() {
        liveMessages = []
        liveMessageTurnIDs = [:]
    }

    private func removePersistedLiveMessages(from result: ThreadDetail) {
        let persistedIDs = Set(result.turns.flatMap { turn in
            (turn.items ?? []).compactMap { $0.type == "agentMessage" ? $0.id : nil }
        })
        let completedTurnIDs = Set<String>(result.turns.compactMap { turn in
            guard turn.status != nil && turn.status != "inProgress" else { return nil }
            return turn.id
        })
        guard !persistedIDs.isEmpty || !completedTurnIDs.isEmpty else { return }
        liveMessages.removeAll { message in
            if persistedIDs.contains(message.id) {
                liveMessageTurnIDs.removeValue(forKey: message.id)
                return true
            }
            if message.role == .assistant,
               let turnID = liveMessageTurnIDs[message.id], completedTurnIDs.contains(turnID) {
                liveMessageTurnIDs.removeValue(forKey: message.id)
                return true
            }
            return false
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        startHealthMonitor()
        await refresh()
        streamsStarted = true
        connectGlobalStream()
    }

    func applySettings(
        lanServerURL: String,
        tailscaleServerURL: String,
        connectionMode: ConnectionMode,
        token: String
    ) async {
        self.lanServerURL = normalizedURL(lanServerURL)
        self.tailscaleServerURL = normalizedURL(tailscaleServerURL)
        self.connectionMode = connectionMode
        serverURL = connectionMode == .tailscale ? self.tailscaleServerURL : self.lanServerURL
        authToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        models = []
        modelsLoaded = false
        selectedEffortID = ""
        let defaults = UserDefaults.standard
        defaults.set(self.lanServerURL, forKey: "cloudex.serverURL")
        defaults.set(self.lanServerURL, forKey: "cloudex.lanServerURL")
        defaults.set(self.tailscaleServerURL, forKey: "cloudex.tailscaleServerURL")
        defaults.set(connectionMode.rawValue, forKey: "cloudex.connectionMode")
        defaults.set(authToken, forKey: "cloudex.authToken")
        globalSSE.stop()
        threadSSE.stop()
        streamsStarted = false
        startHealthMonitor()
        await refresh()
        streamsStarted = true
        connectGlobalStream()
        if let selectedThreadID { connectThreadStream(threadID: selectedThreadID) }
    }

    func refresh() async {
        isBusy = true
        defer { isBusy = false }
        var lastError: Error?
        for candidate in connectionCandidates {
            do {
                let candidateClient = APIClient(serverURL: candidate, token: authToken)
                let _: HealthResponse = try await candidateClient.get("/api/health")
                let projectResponse: ProjectsResponse = try await candidateClient.get("/api/projects")
                let approvalsResponse: ApprovalsResponse? = try? await candidateClient.get("/api/approvals")
                let switchedConnection = normalizedURL(serverURL) != candidate
                serverURL = candidate
                isServerReachable = true
                applyProjects(projectResponse.data)
                if let approvalsResponse { pendingApprovals = approvalsResponse.data }
                status = "已连接 · \(activeConnectionTitle) · \(Date().formatted(date: .omitted, time: .standard))"
                if switchedConnection && streamsStarted {
                    connectGlobalStream()
                    if let selectedThreadID { connectThreadStream(threadID: selectedThreadID) }
                }
            if selectedThreadID == nil, !isCreatingNew, let first = allThreads.first {
                await openThread(first, projectCWD: first.cwd)
            }
                return
            } catch {
                lastError = error
            }
        }
        isServerReachable = false
        status = "连接失败：\(lastError?.localizedDescription ?? "无法访问局域网或 Tailscale 地址")"
    }

    func loadModelsIfNeeded(force: Bool = false) async {
        if modelsLoading { return }
        if modelsLoaded && !force { return }
        modelsLoading = true
        defer { modelsLoading = false }
        var lastError: Error?
        for candidate in connectionCandidates {
            do {
                let candidateClient = APIClient(serverURL: candidate, token: authToken)
                let response: ModelsResponse = try await candidateClient.get("/api/models")
                let visibleModels = response.data.filter { $0.hidden != true }
                models = visibleModels
                modelsLoaded = true
                if normalizedURL(serverURL) != candidate { serverURL = candidate }
                if selectedModelID.isEmpty {
                    selectedModelID = visibleModels.first(where: { $0.isDefault == true })?.identifier
                        ?? visibleModels.first?.identifier
                        ?? ""
                    UserDefaults.standard.set(selectedModelID, forKey: "cloudex.model")
                }
                normalizeEffortForSelectedModel()
                return
            } catch {
                lastError = error
            }
        }
        status = "读取模型列表失败：\(lastError?.localizedDescription ?? "无法访问本地服务器")"
    }

    private func startHealthMonitor() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshServerReachability()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refreshServerReachability() async {
        var reachableCandidate: String?
        for candidate in connectionCandidates {
            do {
                let candidateClient = APIClient(serverURL: candidate, token: authToken)
                let _: HealthResponse = try await candidateClient.get("/api/health")
                reachableCandidate = candidate
                break
            } catch {
                continue
            }
        }
        if let reachableCandidate {
            isServerReachable = true
            if connectionMode == .automatic, normalizedURL(serverURL) != reachableCandidate {
                serverURL = reachableCandidate
            }
            let candidateClient = APIClient(serverURL: reachableCandidate, token: authToken)
            if let approvalsResponse: ApprovalsResponse = try? await candidateClient.get("/api/approvals") {
                pendingApprovals = approvalsResponse.data
            }
        } else {
            isServerReachable = false
        }
    }

    private var connectionCandidates: [String] {
        let values: [String]
        switch connectionMode {
        case .automatic: values = [lanServerURL, tailscaleServerURL]
        case .lan: values = [lanServerURL]
        case .tailscale: values = [tailscaleServerURL]
        }
        var seen = Set<String>()
        return values.map(normalizedURL).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func normalizedURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func selectProject(_ cwd: String?) {
        selectedProjectCWD = cwd
    }

    func openThread(_ thread: CloudexThread, projectCWD: String?) async {
        selectedProjectCWD = projectCWD
        selectedThreadID = thread.id
        isCreatingNew = false
        clearLiveMessages()
        localError = nil
        attachedFiles = []
        if let cached = conversationCache.loadThreadDetail(threadID: thread.id) {
            detail = cached
            liveRunning = cached.thread.isActive
        } else {
            detail = ThreadDetail(thread: thread, turns: [])
            liveRunning = thread.isActive
        }
        await loadThread(thread.id, force: true)
        connectThreadStream(threadID: thread.id)
        startPolling(threadID: thread.id)
    }

    func startNewChat(projectCWD: String? = nil) {
        selectedProjectCWD = projectCWD ?? selectedProjectCWD
        selectedThreadID = nil
        detail = nil
        draft = ""
        clearLiveMessages()
        liveRunning = false
        localError = nil
        attachedFiles = []
        isCreatingNew = true
        threadSSE.stop()
        pollTask?.cancel()
    }

    func loadThread(_ threadID: String, force: Bool = false) async {
        if liveRunning && !force { return }
        detailLoadGeneration += 1
        let generation = detailLoadGeneration
        do {
            let result: ThreadDetail = try await client.get(client.threadPath(threadID))
            guard selectedThreadID == threadID, generation == detailLoadGeneration else { return }
            detail = result
            conversationCache.saveThreadDetail(result, threadID: threadID)
            removePersistedLiveMessages(from: result)
            liveRunning = result.thread.isActive
            if let error = result.turns.last(where: { $0.error != nil })?.error {
                status = "任务失败：\(error.displayText)"
            }
        } catch {
            status = "读取会话失败：\(error.localizedDescription)"
        }
    }

    func send() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isBusy = true
        liveRunning = true
        clearLiveMessages()
        localError = nil
        var body: [String: Any] = [:]
        if !selectedModelID.isEmpty { body["model"] = selectedModelID }
        if !selectedEffortID.isEmpty { body["effort"] = selectedEffortID }
        if !attachedFiles.isEmpty { body["files"] = attachedFiles.map { ["path": $0.path] } }
        do {
            if let selectedThreadID {
                body["message"] = prompt
                let _: EmptyResponse = try await client.post(client.threadPath(selectedThreadID, action: "message"), json: body)
                draft = ""
                attachedFiles = []
                await loadThread(selectedThreadID)
            } else {
                body["prompt"] = prompt
                if let selectedProjectCWD { body["cwd"] = selectedProjectCWD }
                let result: CreateThreadResponse = try await client.post("/api/threads", json: body)
                draft = ""
                attachedFiles = []
                isCreatingNew = false
                selectedThreadID = result.thread.id
                detail = ThreadDetail(thread: result.thread, turns: [])
                connectThreadStream(threadID: result.thread.id)
                startPolling(threadID: result.thread.id)
                await refresh()
            }
        } catch {
            liveRunning = false
            localError = error.localizedDescription
            status = "发送失败：\(error.localizedDescription)"
        }
        isBusy = false
    }

    func stop() async {
        guard let selectedThreadID else { return }
        isBusy = true
        liveRunning = false
        clearLiveMessages()
        do {
            let _: EmptyResponse = try await client.post(client.threadPath(selectedThreadID, action: "stop"))
            status = "已请求停止当前任务"
        } catch {
            status = "停止失败：\(error.localizedDescription)"
        }
        await loadThread(selectedThreadID, force: true)
        await refresh()
        isBusy = false
    }

    func archive(_ threadID: String) async {
        do {
            let _: EmptyResponse = try await client.post(client.threadPath(threadID, action: "archive"))
            if selectedThreadID == threadID { startNewChat(projectCWD: selectedProjectCWD) }
            await refresh()
        } catch {
            status = "归档失败：\(error.localizedDescription)"
        }
    }

    func listFiles(path: String) async throws -> RemoteFilesResponse {
        try await client.get("/api/files", queryItems: [URLQueryItem(name: "path", value: path)])
    }

    func attach(_ file: RemoteFileEntry) {
        guard !attachedFiles.contains(where: { $0.path == file.path }) else { return }
        attachedFiles.append(file)
    }

    func removeAttachment(_ file: RemoteFileEntry) {
        attachedFiles.removeAll { $0.path == file.path }
    }

    func selectModel(_ modelID: String) {
        selectedModelID = modelID
        normalizeEffortForSelectedModel()
        UserDefaults.standard.set(selectedModelID, forKey: "cloudex.model")
        UserDefaults.standard.set(selectedEffortID, forKey: "cloudex.effort")
    }

    func selectEffort(_ effortID: String) {
        guard availableEfforts.contains(where: { $0.reasoningEffort == effortID }) else { return }
        selectedEffortID = effortID
        UserDefaults.standard.set(selectedEffortID, forKey: "cloudex.effort")
    }

    private func normalizeEffortForSelectedModel() {
        guard let model = models.first(where: { $0.identifier == selectedModelID }) else { return }
        let supported = model.supportedReasoningEfforts ?? []
        if !supported.contains(where: { $0.reasoningEffort == selectedEffortID }) {
            selectedEffortID = model.defaultReasoningEffort ?? supported.first?.reasoningEffort ?? ""
        }
    }

    func respondToApproval(_ approval: ApprovalRequest, decision: ApprovalDecision) async {
        guard approval.supports(decision) else {
            status = "当前审批不支持这个选项"
            return
        }
        do {
            let _: ApprovalResponse = try await client.post(
                client.approvalPath(approval.id),
                json: ["decision": decision.rawValue]
            )
            pendingApprovals.removeAll { $0.id == approval.id }
            CloudexAppDelegate.notifications.removeApproval(approval.id)
            appendApprovalSystemMessage(approval: approval, decision: decision)
            switch decision {
            case .accept: status = "已允许本次操作"
            case .acceptForSession: status = "已永久允许当前会话"
            case .decline: status = "已禁止操作"
            }
        } catch {
            if let apiError = error as? APIClientError,
               case let .server(status, _) = apiError,
               status == 409 {
                    pendingApprovals.removeAll { $0.id == approval.id }
            }
            status = "审批失败：\(error.localizedDescription)"
        }
    }

    func updateNotificationSettings(approvals: Bool, taskSuccess: Bool, taskFailure: Bool) {
        notifyApprovals = approvals
        notifyTaskSuccess = taskSuccess
        notifyTaskFailure = taskFailure
        let defaults = UserDefaults.standard
        defaults.set(approvals, forKey: "cloudex.notifyApprovals")
        defaults.set(taskSuccess, forKey: "cloudex.notifyTaskSuccess")
        defaults.set(taskFailure, forKey: "cloudex.notifyTaskFailure")
    }

    func respondToApproval(id: String, decision: ApprovalDecision) async {
        if let approval = pendingApprovals.first(where: { $0.id == id }) {
            await respondToApproval(approval, decision: decision)
            return
        }
        if let response: ApprovalsResponse = try? await client.get("/api/approvals"),
           let approval = response.data.first(where: { $0.id == id }) {
            pendingApprovals = response.data
            await respondToApproval(approval, decision: decision)
        }
    }

    private func applyProjects(_ value: [CloudexProject]) {
        if projects == value { return }
        projects = value
        conversationCache.saveProjects(value)
        if let selectedProjectCWD, !value.contains(where: { $0.cwd == selectedProjectCWD }) {
            self.selectedProjectCWD = nil
        }
    }

    private func connectGlobalStream() {
        do {
            let url = try client.makeURL(path: "/api/events")
            globalSSE.onOpen = { [weak self] in
                Task { @MainActor in self?.status = "已连接 · 实时同步" }
            }
            globalSSE.onEvent = { [weak self] event in
                Task { @MainActor in self?.handleGlobalEvent(event) }
            }
            globalSSE.onDisconnect = { [weak self] message in
                Task { @MainActor in
                    self?.status = message.contains("401") ? "实时总线认证失败：请确认 Token" : "实时总线断开：\(message)"
                }
            }
            globalSSE.start(url: url, token: authToken)
        } catch {
            status = "实时总线启动失败：\(error.localizedDescription)"
        }
    }

    private func connectThreadStream(threadID: String) {
        threadSSE.stop()
        lastThreadEventID = 0
        do {
            let url = try client.makeURL(path: client.threadPath(threadID, action: "stream"))
            threadSSE.onEvent = { [weak self] event in
                Task { @MainActor in self?.handleThreadEvent(event, expectedThreadID: threadID) }
            }
            threadSSE.onDisconnect = { [weak self] message in
                Task { @MainActor in
                    guard self?.selectedThreadID == threadID else { return }
                    self?.status = message.contains("401") ? "实时订阅认证失败：请确认 Token" : "实时连接断开：\(message)"
                }
            }
            threadSSE.start(url: url, token: authToken)
        } catch {
            status = "实时订阅启动失败：\(error.localizedDescription)"
        }
    }

    private func handleGlobalEvent(_ event: SSEEvent) {
        if event.name == "approval/requested",
           let approval = try? JSONDecoder().decode(ApprovalRequest.self, from: event.data) {
            pendingApprovals.removeAll { $0.id == approval.id }
            pendingApprovals.append(approval)
            CloudexAppDelegate.notifications.scheduleApproval(approval)
            status = "Codex 正在等待审批"
            return
        }
        if event.name == "approval/resolved",
           let object = (try? JSONSerialization.jsonObject(with: event.data)) as? [String: Any],
           let id = object["id"] as? String {
            let approval = pendingApprovals.first { $0.id == id }
            let threadID = object["threadId"] as? String ?? approval?.threadId
            if let rawDecision = object["decision"] as? String,
               let decision = ApprovalDecision(rawValue: rawDecision) {
                appendApprovalSystemMessage(
                    approvalID: id,
                    threadID: threadID,
                    decision: decision,
                    requestedAt: approval?.requestedAt
                )
            }
            pendingApprovals.removeAll { $0.id == id }
            CloudexAppDelegate.notifications.removeApproval(id)
            return
        }
        if event.name == "threads/changed",
           let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: event.data) {
            applyProjects(snapshot.projects)
            if let selectedThreadID,
               snapshot.projects.flatMap(\.threads).contains(where: { $0.id == selectedThreadID }) {
                Task { await loadThread(selectedThreadID, force: true) }
            }
        }
    }

    private func appendApprovalSystemMessage(approval: ApprovalRequest, decision: ApprovalDecision) {
        appendApprovalSystemMessage(
            approvalID: approval.id,
            threadID: approval.threadId,
            decision: decision,
            requestedAt: approval.requestedAt,
            text: approvalConfirmationText(approval: approval, decision: decision)
        )
    }

    private func appendApprovalSystemMessage(
        approvalID: String,
        threadID: String?,
        decision: ApprovalDecision,
        requestedAt: Double?,
        text: String? = nil
    ) {
        let id = "approval-\(approvalID)-\(decision.rawValue)"
        systemMessages.removeAll { $0.id == id }
        systemMessages.append(ChatMessage(
            id: id,
            role: .execution,
            text: text ?? decision.systemTitle,
            executionStatus: "completed",
            executionKind: "approval",
            createdAt: normalizedTimestamp(requestedAt) ?? Date().timeIntervalSince1970,
            threadID: threadID
        ))
    }

    private func approvalConfirmationText(approval: ApprovalRequest, decision: ApprovalDecision) -> String {
        var details: [String] = []
        if let context = approval.networkApprovalContext, let host = context.host, !host.isEmpty {
            let scheme = context.protocolName.map { "\($0)://" } ?? ""
            let port = context.port.map { ":\($0)" } ?? ""
            details.append("网络：\(scheme)\(host)\(port)")
        } else if let permissionSummary = approval.permissionSummary, !permissionSummary.isEmpty {
            details.append("权限：\(permissionSummary)")
        } else if let command = approval.command, !command.isEmpty {
            details.append("命令：\(command)")
        }
        if let path = approval.grantRoot ?? approval.cwd, !path.isEmpty {
            details.append("路径：\(path)")
        }
        guard !details.isEmpty else { return decision.systemTitle }
        return "\(decision.systemTitle)\n\(details.joined(separator: "\n"))"
    }

    private func normalizedTimestamp(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value > 10_000_000_000 ? value / 1000 : value
    }

    private func handleThreadEvent(_ event: SSEEvent, expectedThreadID: String) {
        guard selectedThreadID == expectedThreadID else { return }
        if let id = event.id.flatMap(Int.init) {
            guard id > lastThreadEventID else { return }
            lastThreadEventID = id
        }
        if event.name == "error" {
            let object = (try? JSONSerialization.jsonObject(with: event.data)) as? [String: Any]
            status = "实时订阅失败：\(object?["message"] as? String ?? "未知错误")"
            return
        }
        guard event.name == "notification",
              let object = (try? JSONSerialization.jsonObject(with: event.data)) as? [String: Any],
              let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any] ?? [:]

        if method == "turn/started" {
            liveRunning = true
            clearLiveMessages()
            localError = nil
        } else if method == "item/started" {
            let item = params["item"] as? [String: Any]
            if item?["type"] as? String == "commandExecution" {
                upsertLiveExecution(item: item ?? [:], turnID: params["turnId"] as? String, status: "inProgress")
                liveRunning = true
                return
            }
            guard item?["type"] as? String == "agentMessage" else { return }
            liveRunning = true
            guard let itemID = item?["id"] as? String else { return }
            let startedAt = (params["startedAtMs"] as? NSNumber)?.doubleValue
            beginLiveMessage(
                id: itemID,
                turnID: params["turnId"] as? String,
                text: item?["text"] as? String ?? "",
                createdAt: startedAt.map { $0 / 1000 }
            )
        } else if method == "item/agentMessage/delta" {
            liveRunning = true
            guard let itemID = params["itemId"] as? String else { return }
            appendLiveDelta(id: itemID, turnID: params["turnId"] as? String, delta: params["delta"] as? String ?? "")
        } else if method == "item/completed" {
            let item = params["item"] as? [String: Any]
            if item?["type"] as? String == "commandExecution" {
                upsertLiveExecution(
                    item: item ?? [:],
                    turnID: params["turnId"] as? String,
                    status: item?["status"] as? String ?? "completed"
                )
                return
            }
            guard item?["type"] as? String == "agentMessage" else { return }
            if let completedID = item?["id"] as? String,
               let text = item?["text"] as? String,
               !text.isEmpty {
                beginLiveMessage(id: completedID, turnID: params["turnId"] as? String, text: text)
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard let self else { return }
                await self.loadThread(expectedThreadID, force: true)
            }
        } else if ["turn/failed", "turn/interrupted", "turn/cancelled", "turn/canceled"].contains(method) {
            liveRunning = false
            if let errorText = notificationErrorText(params) {
                localError = errorText
                status = "任务失败：\(errorText)"
                CloudexAppDelegate.notifications.scheduleTaskResult(
                    threadID: expectedThreadID,
                    title: selectedThread?.title ?? "当前对话",
                    success: false,
                    detail: errorText
                )
            } else {
                CloudexAppDelegate.notifications.scheduleTaskResult(
                    threadID: expectedThreadID,
                    title: selectedThread?.title ?? "当前对话",
                    success: false
                )
            }
            reloadAfterEvent(expectedThreadID)
        } else if method == "turn/completed" {
            liveRunning = false
            if let errorText = notificationErrorText(params) {
                localError = errorText
                status = "任务失败：\(errorText)"
                CloudexAppDelegate.notifications.scheduleTaskResult(
                    threadID: expectedThreadID,
                    title: selectedThread?.title ?? "当前对话",
                    success: false,
                    detail: errorText
                )
            } else {
                localError = nil
                CloudexAppDelegate.notifications.scheduleTaskResult(
                    threadID: expectedThreadID,
                    title: selectedThread?.title ?? "当前对话",
                    success: true
                )
            }
            reloadAfterEvent(expectedThreadID)
        } else if method == "thread/archived" || method == "thread/name/updated" {
            reloadAfterEvent(expectedThreadID)
        }
    }

    private func notificationErrorText(_ params: [String: Any]) -> String? {
        let turn = params["turn"] as? [String: Any]
        let rawError = turn?["error"] ?? params["error"]
        if let text = rawError as? String, !text.isEmpty { return text }
        guard let error = rawError as? [String: Any] else { return nil }
        let message = error["message"] as? String ?? "任务执行失败"
        let code = error["codexErrorInfo"] ?? error["codex_error_info"] ?? error["code"] ?? error["type"]
        if let code = code as? String, !code.isEmpty { return "\(message)\n错误代码：\(code)" }
        return message
    }

    private func reloadAfterEvent(_ threadID: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            await self.loadThread(threadID, force: true)
            await self.refresh()
        }
    }

    private func startPolling(threadID: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.selectedThreadID == threadID else { return }
                await self.loadThread(threadID, force: true)
            }
        }
    }

    deinit {
        pollTask?.cancel()
        globalSSE.stop()
        threadSSE.stop()
    }
}
