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
    @Published var codexMode: CodexExecutionMode
    @Published private(set) var pinnedThreadIDs: Set<String>
    @Published var projects: [CloudexProject] = []
    @Published var renderedMessages: [ChatMessage] = []
    @Published var models: [CodexModel] = []
    @Published var selectedProjectCWD: String?
    @Published var selectedThreadID: String?
    @Published var detail: ThreadDetail? { didSet { rebuildRenderedMessages() } }
    @Published var draft = "" {
        didSet {
            UserDefaults.standard.set(draft, forKey: "cloudex.draft")
        }
    }
    @Published var pendingSteerDraft = "" {
        didSet {
            UserDefaults.standard.set(pendingSteerDraft, forKey: "cloudex.pendingSteerDraft")
        }
    }
    @Published var status = "未连接"
    @Published var isServerReachable = false
    @Published var isBusy = false
    @Published var isOpeningThread = false
    @Published var isCreatingNew = false
    @Published var liveMessages: [ChatMessage] = [] { didSet { rebuildRenderedMessages() } }
    @Published var liveRunning = false
    @Published var localError: String? { didSet { rebuildRenderedMessages() } }
    @Published var attachedFiles: [RemoteFileEntry] = []
    @Published var pendingApprovals: [ApprovalRequest] = []
    @Published var systemMessages: [ChatMessage] = [] { didSet { rebuildRenderedMessages() } }
    @Published var messageIndex: [MessageIndexItem] = []
    @Published var pendingMessageJump: PendingMessageJump?
    @Published var threadNavigationRequest: ThreadNavigationRequest?
    @Published var notifyApprovals: Bool
    @Published var notifyTaskSuccess: Bool
    @Published var notifyTaskFailure: Bool
    @Published private(set) var connectionHistory: [ConnectionHistoryItem] = []

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
    private var threadStreamReplaying = false
    private var detailLoadGeneration = 0
    private var liveMessageTurnIDs: [String: String] = [:]
    private var suppressedCompactionMessageIDs = Set<String>()
    private var liveOrderingClock: Double = 0
    private var activeTurnNotificationKeys: [String: String] = [:]
    private var sentTaskResultNotificationKeys = Set<String>()
    private var pendingSteerAutoSendInFlight = false

    init() {
        let defaults = UserDefaults.standard
        let savedLANURL = defaults.string(forKey: "cloudex.lanServerURL") ?? ""
        let savedTailscaleURL = defaults.string(forKey: "cloudex.tailscaleServerURL") ?? ""
        let savedToken = defaults.string(forKey: "cloudex.authToken") ?? ""
        // 不内置任何开发机地址：默认只指向本机回环地址，
        // 真实服务器地址通过设置页填写或扫描配对二维码获取。
        let defaultServerURL = "http://127.0.0.1:8890"
        let initialLANURL = savedLANURL.isEmpty ? defaultServerURL : savedLANURL
        let initialTailscaleURL = savedTailscaleURL.isEmpty ? defaultServerURL : savedTailscaleURL
        let initialConnectionMode = ConnectionMode(rawValue: defaults.string(forKey: "cloudex.connectionMode") ?? "") ?? .automatic
        lanServerURL = initialLANURL
        tailscaleServerURL = initialTailscaleURL
        connectionMode = initialConnectionMode
        serverURL = initialConnectionMode == .tailscale ? initialTailscaleURL : initialLANURL
        // 不内置任何开发期 Token：认证信息只来自已保存值或扫码配对。
        authToken = savedToken
        // The Codex CLI config is authoritative on each launch. An in-app
        // selection still applies for the current run and subsequent turns.
        selectedModelID = ""
        selectedEffortID = defaults.string(forKey: "cloudex.effort") ?? ""
        draft = defaults.string(forKey: "cloudex.draft") ?? ""
        pendingSteerDraft = defaults.string(forKey: "cloudex.pendingSteerDraft") ?? ""
        codexMode = CodexExecutionMode(
            rawValue: defaults.string(forKey: "cloudex.codexMode") ?? ""
        ) ?? .requestApproval
        pinnedThreadIDs = Set(defaults.stringArray(forKey: "cloudex.pinnedThreadIDs") ?? [])
        notifyApprovals = defaults.object(forKey: "cloudex.notifyApprovals") as? Bool ?? true
        notifyTaskSuccess = defaults.object(forKey: "cloudex.notifyTaskSuccess") as? Bool ?? true
        notifyTaskFailure = defaults.object(forKey: "cloudex.notifyTaskFailure") as? Bool ?? true
        defaults.set(lanServerURL, forKey: "cloudex.serverURL")
        defaults.set(lanServerURL, forKey: "cloudex.lanServerURL")
        defaults.set(tailscaleServerURL, forKey: "cloudex.tailscaleServerURL")
        defaults.set(connectionMode.rawValue, forKey: "cloudex.connectionMode")
        defaults.set(authToken, forKey: "cloudex.authToken")
        projects = conversationCache.loadProjects() ?? []
        connectionHistory = Self.loadConnectionHistory(defaults: defaults)
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
        let title = selectedModel?.title
            ?? (!selectedModelID.isEmpty ? selectedModelID : (modelsLoading ? "读取中" : "模型"))
        return title
            .replacingOccurrences(of: "GPT-", with: "")
            .replacingOccurrences(of: "gpt-", with: "")
    }
    var visibleApprovals: [ApprovalRequest] {
        guard let selectedThreadID else { return pendingApprovals }
        return pendingApprovals
            .filter { approval in
                approval.threadId == nil || approval.threadId == selectedThreadID
            }
            .sorted { left, right in
                (left.requestedAt ?? 0) < (right.requestedAt ?? 0)
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

    private func isTurnInProgress(_ turn: CloudexTurn) -> Bool {
        guard let status = turn.status?.lowercased() else { return liveRunning }
        return ["inprogress", "in_progress", "active", "running"].contains(status)
    }

    private func buildMessages() -> [ChatMessage] {
        var result: [ChatMessage] = []
        for turn in detail?.turns ?? [] {
            let items = turn.items ?? []
            let shouldFoldProcess = turn.status != nil && !isTurnInProgress(turn)
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
                processItems = mergeSemanticExecutionItems(processItems)

                if !processItems.isEmpty || (turn.processItemCount ?? 0) > 0 {
                    result.append(ChatMessage(
                        id: "\(turn.id)-process-summary",
                        role: .processSummary,
                        text: processSummaryText(durationMessage?.text),
                        processItems: processItems,
                        createdAt: processItems.compactMap(\.createdAt).min(),
                        sourceTurnID: turn.id,
                        processItemCount: turn.processItemCount,
                        processDetailsLoaded: turn.processDetailsAreLoaded
                    ))
                }
                if let finalMessage { result.append(finalMessage) }
            } else {
                for (index, item) in items.enumerated() {
                    if let message = timelineMessage(from: item, turnID: turn.id, fallbackIndex: index) {
                        result.append(message)
                    }
                }
                // Keep the original live presentation for an active turn:
                // each execution row and assistant bubble stays directly in
                // the timeline. Only the command semantic classification is
                // shared with the completed-turn process view.
                let liveForTurn = liveMessages.filter { liveMessageTurnIDs[$0.id] == turn.id }
                let existingMessageIDs = Set(result.map(\.id))
                result.append(contentsOf: liveForTurn.filter {
                    !existingMessageIDs.contains($0.id)
                })
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
        // A new chat has no turn yet, so retain live messages until its first
        // server snapshot arrives. Existing turns render live items above.
        if detail?.turns.isEmpty == true {
            result.append(contentsOf: liveMessages)
        }
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
        if item.type == "commandExecution" || item.command != nil || item.activity == "edited" || item.diff != nil {
            let command = item.command?.trimmingCharacters(in: .whitespacesAndNewlines)
            let execution = command.map { semanticExecution(command: $0, activity: item.activity, status: item.status) }
            let text = item.activity == "edited"
                ? editSummary(from: item.diff) ?? execution?.text ?? "Edited files"
                : execution?.text ?? item.renderedText
            let kind = execution?.kind ?? (item.activity == "edited" ? "edit" : "run")
            return ChatMessage(
                id: item.id ?? "\(turnID)-command-\(fallbackIndex)",
                role: .execution,
                text: text,
                executionStatus: item.status,
                executionDuration: DateFormatting.wholeSecondDuration(from: item.duration),
                executionExitCode: item.exitCode,
                executionKind: kind,
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
            createdAt: item.createdAt,
            sourceTurnID: turnID
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
        if let search = searchDisplay(from: trimmed) {
            return ("Search \(search.query) in \(joinedTargets(search.targets))", "search")
        }
        if activity == "approval" {
            return (trimmed, "approval")
        }
        if activity == "edited" {
            return ("Edited \(editedDisplay(from: trimmed))", "edit")
        }
        if activity == "explored" {
            return ("Explored \(joinedTargets(fileTargets(from: trimmed), fallback: trimmed))", "explore")
        }
        return ("\(status == "inProgress" ? "Running" : "Ran") \(unwrappedShellCommand(trimmed))", "run")
    }

    private func editedDisplay(from command: String) -> String {
        if command.contains("\n") { return command }
        return joinedTargets(fileTargets(from: command), fallback: command)
    }

    private func readTargets(from command: String) -> [String]? {
        guard containsCommand(command, names: ["sed", "cat", "head", "tail"]) else { return nil }
        let targets = fileTargets(from: command)
        return targets.isEmpty ? ["files"] : targets
    }

    private func searchDisplay(from command: String) -> (query: String, targets: [String])? {
        let searchCommands = Set(["rg", "grep", "find", "fd"])
        let tokens = semanticCommandTokens(command)
        guard let commandIndex = tokens.firstIndex(where: {
            searchCommands.contains(($0 as NSString).lastPathComponent.lowercased())
        }) else { return nil }

        let commandName = (tokens[commandIndex] as NSString).lastPathComponent.lowercased()
        let arguments = Array(tokens.dropFirst(commandIndex + 1))
        var query: String?
        var pathTokens: [String] = []

        if commandName == "find" {
            var index = 0
            while index < arguments.count {
                let token = arguments[index]
                if ["-name", "-iname", "-path", "-ipath", "-regex", "-iregex"].contains(token),
                   index + 1 < arguments.count {
                    query = arguments[index + 1]
                    index += 2
                    continue
                }
                if !token.hasPrefix("-") && query == nil {
                    pathTokens.append(token)
                }
                index += 1
            }
        } else {
            let optionsWithValue = Set([
                "-f", "--file", "-g", "--glob", "-t", "--type", "--type-add",
                "-m", "--max-count", "-A", "-B", "-C", "--after-context",
                "--before-context", "--context", "--encoding", "--engine"
            ])
            var index = 0
            while index < arguments.count {
                let token = arguments[index]
                if ["-e", "--regexp"].contains(token), index + 1 < arguments.count {
                    query = arguments[index + 1]
                    index += 2
                    continue
                }
                if optionsWithValue.contains(token) {
                    index += min(2, arguments.count - index)
                    continue
                }
                if token.hasPrefix("-") {
                    index += 1
                    continue
                }
                if query == nil {
                    query = token
                } else {
                    pathTokens.append(token)
                }
                index += 1
            }
        }

        let cleanedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleanedQuery, !cleanedQuery.isEmpty else { return nil }
        let targets = displayTargets(from: pathTokens)
        return (cleanedQuery, targets.isEmpty ? ["workspace"] : targets)
    }

    private func semanticCommandTokens(_ command: String) -> [String] {
        let tokens = shellLikeTokens(command)
        let shells = Set(["sh", "bash", "zsh", "fish"])
        guard let first = tokens.first,
              shells.contains((first as NSString).lastPathComponent.lowercased()),
              let commandFlagIndex = tokens.firstIndex(where: { $0 == "-c" || $0 == "-lc" }),
              commandFlagIndex + 1 < tokens.count else { return tokens }
        return shellLikeTokens(tokens[commandFlagIndex + 1])
    }

    private func unwrappedShellCommand(_ command: String) -> String {
        let tokens = shellLikeTokens(command)
        let shells = Set(["sh", "bash", "zsh", "fish"])
        guard let first = tokens.first,
              shells.contains((first as NSString).lastPathComponent.lowercased()),
              let commandFlagIndex = tokens.firstIndex(where: { $0 == "-c" || $0 == "-lc" }),
              commandFlagIndex + 1 < tokens.count else { return command }
        return tokens.dropFirst(commandFlagIndex + 1).joined(separator: " ")
    }

    private func displayTargets(from tokens: [String]) -> [String] {
        tokens.reduce(into: [String]()) { result, token in
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ","))
            guard !cleaned.isEmpty else { return }
            let display: String
            if cleaned == "." || cleaned == "./" {
                display = "workspace"
            } else {
                let name = (cleaned as NSString).lastPathComponent
                display = name.isEmpty ? cleaned : name
            }
            if !result.contains(display) { result.append(display) }
        }
    }

    private func containsCommand(_ command: String, names: [String]) -> Bool {
        let escaped = names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "(?:^|[;&|()]\\s*|\\b)(?:" + escaped + ")(?:\\s|$)"
        return command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func firstCommandName(_ command: String) -> String {
        let sanitized = command.replacingOccurrences(of: #"^\s*(?:[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'[^']*'|\S+)\s+)*"#, with: "", options: .regularExpression)
        let tokens = shellLikeTokens(sanitized)
        guard let first = tokens.first else { return "" }
        let name = (first as NSString).lastPathComponent
        return name.lowercased()
    }

    private func fileTargets(from command: String) -> [String] {
        let tokens = semanticCommandTokens(command)
        let ignoredCommands = Set(["sed", "cat", "head", "tail", "rg", "grep", "find", "fd", "git", "ps", "aux", "ls", "pwd", "wc", "stat", "which", "sh", "bash", "zsh", "fish", "env"])
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
            let executableName = (bare as NSString).lastPathComponent.lowercased()
            if ignoredCommands.contains(bare.lowercased()) || ignoredCommands.contains(executableName) { continue }
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
        // Preserve every fine-grained execution item. Time-bucket merging made
        // rapid live Read/Search events collapse across intervening messages,
        // which looked like missing commands and also changed their order.
        items
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

    private func processSummaryText(_ taskSummary: String?) -> String {
        guard let taskSummary, !taskSummary.isEmpty else { return "查看过程" }
        return "查看过程 · \(taskSummary)"
    }

    private func shouldHidePersistedLiveMessage(_ item: TurnItem, turnID: String) -> Bool {
        guard !liveMessages.isEmpty else { return false }
        if let id = item.id, liveMessages.contains(where: { $0.id == id }) { return true }
        let persisted = normalizedMessageText(item.renderedText)
        guard !persisted.isEmpty else { return false }
        return liveMessages.contains { message in
            guard liveMessageTurnIDs[message.id] == turnID else { return false }
            let streaming = normalizedMessageText(message.text)
            return !streaming.isEmpty && (streaming == persisted || streaming.hasPrefix(persisted))
        }
    }

    private func normalizedMessageText(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nextLiveCreatedAt() -> Double {
        liveOrderingClock = max(Date().timeIntervalSince1970, liveOrderingClock + 0.000_001)
        return liveOrderingClock
    }

    private func liveTurnID(
        from params: [String: Any],
        item: [String: Any]? = nil,
        threadID: String
    ) -> String? {
        params["turnId"] as? String
            ?? (params["turn"] as? [String: Any])?["id"] as? String
            ?? item?["turnId"] as? String
            ?? activeTurnNotificationKeys[threadID]
    }

    private func liveText(from item: [String: Any]?) -> String {
        guard let item else { return "" }
        if let text = item["text"] as? String, !text.isEmpty { return text }
        if let message = item["message"] as? String, !message.isEmpty { return message }
        guard let content = item["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { part in
            part["text"] as? String ?? part["value"] as? String
        }.joined()
    }

    private func isCompactionSummary(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.range(
            of: #"^(?:#+\s*|\*\*)?handoff summary\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func isCompactionItem(_ item: [String: Any]) -> Bool {
        let type = (item["type"] as? String ?? "").lowercased()
        return type.contains("compact") || type.contains("compress")
    }

    private func recordLiveCompaction(turnID: String?) {
        liveMessages.removeAll { message in
            guard message.role == .assistant, isCompactionSummary(message.text) else { return false }
            suppressedCompactionMessageIDs.insert(message.id)
            liveMessageTurnIDs.removeValue(forKey: message.id)
            return true
        }
        guard let turnID else { return }
        let id = "\(turnID)-live-compacted"
        guard !liveMessages.contains(where: { $0.id == id }) else { return }
        liveMessageTurnIDs[id] = turnID
        liveMessages.append(ChatMessage(
            id: id,
            role: .compressed,
            text: "上下文已压缩",
            createdAt: nextLiveCreatedAt(),
            isCompressed: true
        ))
    }

    private func beginLiveMessage(id: String, turnID: String?, text: String = "") {
        if isCompactionSummary(text) {
            suppressedCompactionMessageIDs.insert(id)
            liveMessages.removeAll { $0.id == id }
            liveMessageTurnIDs.removeValue(forKey: id)
            return
        }
        guard !suppressedCompactionMessageIDs.contains(id) else { return }
        liveMessageTurnIDs[id] = turnID
        if let index = liveMessages.firstIndex(where: { $0.id == id }) {
            let previous = liveMessages[index]
            liveMessages[index] = ChatMessage(id: id, role: .assistant, text: text, createdAt: previous.createdAt, sourceTurnID: turnID)
        } else {
            liveMessages.append(ChatMessage(id: id, role: .assistant, text: text, createdAt: nextLiveCreatedAt(), sourceTurnID: turnID))
        }
    }

    private func appendLiveDelta(id: String, turnID: String?, delta: String) {
        guard !suppressedCompactionMessageIDs.contains(id) else { return }
        let combinedText = (liveMessages.first(where: { $0.id == id })?.text ?? "") + delta
        if isCompactionSummary(combinedText) {
            suppressedCompactionMessageIDs.insert(id)
            liveMessages.removeAll { $0.id == id }
            liveMessageTurnIDs.removeValue(forKey: id)
            return
        }
        liveMessageTurnIDs[id] = turnID
        if let index = liveMessages.firstIndex(where: { $0.id == id }) {
            let previous = liveMessages[index]
            liveMessages[index] = ChatMessage(id: id, role: .assistant, text: previous.text + delta, createdAt: previous.createdAt, sourceTurnID: turnID)
        } else {
            liveMessages.append(ChatMessage(id: id, role: .assistant, text: delta, createdAt: nextLiveCreatedAt(), sourceTurnID: turnID))
        }
    }

    private func liveEditDiff(from item: [String: Any]) -> [EditDiffPayload]? {
        if let existing = item["diff"] as? [[String: Any]] {
            let decoded = existing.compactMap { payload -> EditDiffPayload? in
                guard let name = payload["name"] as? String else { return nil }
                let lines = (payload["lines"] as? [[String: Any]] ?? []).compactMap { line -> EditDiffLinePayload? in
                    guard let kind = line["kind"] as? String,
                          let text = line["text"] as? String else { return nil }
                    return EditDiffLinePayload(kind: kind, text: text, lineNumber: (line["lineNumber"] as? NSNumber)?.intValue)
                }
                return EditDiffPayload(
                    name: name,
                    additions: (payload["additions"] as? NSNumber)?.intValue,
                    deletions: (payload["deletions"] as? NSNumber)?.intValue,
                    lines: lines.isEmpty ? nil : lines
                )
            }
            if !decoded.isEmpty { return decoded }
        }
        guard let changes = item["changes"] as? [[String: Any]] else { return nil }
        let payloads = changes.compactMap { change -> EditDiffPayload? in
            guard let name = editPath(from: change) else { return nil }
            let diff = change["diff"] as? String
            var oldLine = 1
            var newLine = 1
            var additions = 0
            var deletions = 0
            var lines: [EditDiffLinePayload] = []
            for raw in (diff ?? "").replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if raw.hasPrefix("@@") {
                    lines.append(EditDiffLinePayload(kind: "header", text: raw.trimmingCharacters(in: .whitespaces), lineNumber: nil))
                    let ranges = raw.split(whereSeparator: { $0.isWhitespace })
                    if ranges.count >= 3 {
                        oldLine = Int(ranges[1].dropFirst().split(separator: ",").first ?? "1") ?? oldLine
                        newLine = Int(ranges[2].dropFirst().split(separator: ",").first ?? "1") ?? newLine
                    }
                    continue
                }
                if raw.hasPrefix("+++") || raw.hasPrefix("---") { continue }
                if raw.hasPrefix("+") {
                    lines.append(EditDiffLinePayload(kind: "addition", text: String(raw.dropFirst()), lineNumber: newLine))
                    additions += 1
                    newLine += 1
                } else if raw.hasPrefix("-") {
                    lines.append(EditDiffLinePayload(kind: "deletion", text: String(raw.dropFirst()), lineNumber: oldLine))
                    deletions += 1
                    oldLine += 1
                } else if raw.hasPrefix(" ") {
                    lines.append(EditDiffLinePayload(kind: "context", text: String(raw.dropFirst()), lineNumber: newLine))
                    oldLine += 1
                    newLine += 1
                }
            }
            if lines.isEmpty {
                additions = editCount(from: change, keys: ["additions", "added", "addedLines", "insertions"])
                deletions = editCount(from: change, keys: ["deletions", "deleted", "deletedLines", "removals"])
            }
            guard !lines.isEmpty || additions > 0 || deletions > 0 else { return nil }
            return EditDiffPayload(name: name, additions: additions, deletions: deletions, lines: lines)
        }
        return payloads.isEmpty ? nil : payloads
    }

    private func editSummary(from payloads: [EditDiffPayload]?) -> String? {
        let summaries = (payloads ?? []).compactMap { payload -> String? in
            let name = editDisplayName(payload.name)
            guard !name.isEmpty else { return nil }
            let additions = payload.additions ?? payload.lines?.filter { $0.kind == "addition" }.count ?? 0
            let deletions = payload.deletions ?? payload.lines?.filter { $0.kind == "deletion" }.count ?? 0
            return "\(name) +\(additions) -\(deletions)"
        }
        return summaries.isEmpty ? nil : summaries.joined(separator: "\n")
    }

    private func editPath(from change: [String: Any]) -> String? {
        ["path", "filePath", "relativePath", "name", "file"]
            .compactMap { change[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func editCount(from change: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let value = change[key] as? NSNumber { return max(value.intValue, 0) }
            if let value = change[key] as? Int { return max(value, 0) }
        }
        return 0
    }

    private func editDisplayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).lastPathComponent
    }

    private func upsertLiveExecution(
        item: [String: Any],
        fallbackID: String? = nil,
        turnID: String?,
        status: String
    ) {
        guard let id = item["id"] as? String ?? fallbackID else { return }
        let type = (item["type"] as? String ?? "").lowercased()
        let activity = item["activity"] as? String
            ?? (type.contains("filechange") ? "edited" : nil)
        let changedPaths = (item["changes"] as? [[String: Any]] ?? []).compactMap { change in
            editPath(from: change)
        }
        let existingIndex = liveMessages.firstIndex(where: { $0.id == id })
        let previous = existingIndex.map { liveMessages[$0] }
        let editDiff = activity == "edited" ? liveEditDiff(from: item) : nil
        let editText = activity == "edited" ? editSummary(from: editDiff) : nil
        // Codex uses different payload shapes for shell exploration and file
        // edits. Edits may not have a command at all, so do not discard them.
        let rawCommand = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (item["path"] as? String)
            ?? (!changedPaths.isEmpty ? changedPaths.joined(separator: ", ") : nil)
        let execution = rawCommand.map { semanticExecution(command: $0, activity: activity, status: status) }
        let duration: String? = {
            guard let milliseconds = (item["durationMs"] as? NSNumber)?.doubleValue else { return nil }
            return DateFormatting.duration(fromMilliseconds: milliseconds)
        }()
        let createdAt = existingIndex.flatMap { liveMessages[$0].createdAt } ?? nextLiveCreatedAt()
        let message = ChatMessage(
            id: id,
            role: .execution,
            text: editText
                ?? execution?.text
                ?? previous?.text
                ?? (activity == "edited" ? "Edited files" : activity == "explored" ? "Explored workspace" : "Ran tool"),
            executionStatus: status,
            executionDuration: duration ?? previous?.executionDuration,
            executionExitCode: (item["exitCode"] as? NSNumber)?.intValue ?? previous?.executionExitCode,
            executionKind: execution?.kind ?? previous?.executionKind ?? (activity == "edited" ? "edit" : "run"),
            editDiff: editDiff ?? previous?.editDiff,
            createdAt: createdAt
        )
        liveMessageTurnIDs[id] = turnID
        if let index = existingIndex {
            liveMessages[index] = message
        } else {
            liveMessages.append(message)
        }
    }

    private func isLiveExecutionItem(_ item: [String: Any]) -> Bool {
        let type = (item["type"] as? String ?? "").lowercased()
        return type == "commandexecution"
            || type.contains("commandexecution")
            || type.contains("filechange")
            || type.contains("toolcall")
            || item["command"] != nil
            || item["activity"] != nil
            || item["diff"] != nil
    }

    private func clearLiveMessages() {
        liveMessages = []
        liveMessageTurnIDs = [:]
        suppressedCompactionMessageIDs = []
        liveOrderingClock = 0
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

    func resumeFromForeground() async {
        guard started else { return }
        await refresh()
        guard let threadID = selectedThreadID else { return }
        guard active else {
            // Completed conversations are immutable from the chat viewport's
            // perspective; avoid replacing their snapshot on foregrounding.
            threadSSE.stop()
            pollTask?.cancel()
            pollTask = nil
            return
        }
        // URLSession can be suspended while the app is in the background.
        // Restore an authoritative active-turn snapshot before replaying live
        // events so missed commands and intermediate messages are not lost.
        await loadThread(threadID, force: true)
        connectThreadStream(threadID: threadID)
        startPolling(threadID: threadID)
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
        saveConnectionHistory(serverURL: serverURL, token: authToken, mode: connectionMode)
        globalSSE.stop()
        threadSSE.stop()
        streamsStarted = false
        startHealthMonitor()
        await refresh()
        streamsStarted = true
        connectGlobalStream()
        if let selectedThreadID { connectThreadStream(threadID: selectedThreadID) }
    }

    func switchToConnection(_ item: ConnectionHistoryItem) async {
        let lanURL = item.connectionMode == .tailscale ? lanServerURL : item.serverURL
        let tailscaleURL = item.connectionMode == .tailscale ? item.serverURL : tailscaleServerURL
        await applySettings(
            lanServerURL: lanURL,
            tailscaleServerURL: tailscaleURL,
            connectionMode: item.connectionMode,
            token: item.token
        )
    }

    func removeConnectionHistory(at offsets: IndexSet) {
        connectionHistory.remove(atOffsets: offsets)
        if let data = try? JSONEncoder().encode(connectionHistory) {
            UserDefaults.standard.set(data, forKey: "cloudex.connectionHistory")
        }
    }

    private func saveConnectionHistory(serverURL: String, token: String, mode: ConnectionMode) {
        let url = normalizedURL(serverURL)
        guard !url.isEmpty, !token.isEmpty else { return }
        var items = connectionHistory.filter { $0.serverURL != url || $0.token != token }
        items.append(ConnectionHistoryItem(serverURL: url, token: token, connectionMode: mode))
        items.sort { $0.lastUsedAt > $1.lastUsedAt }
        connectionHistory = Array(items.prefix(12))
        if let data = try? JSONEncoder().encode(connectionHistory) {
            UserDefaults.standard.set(data, forKey: "cloudex.connectionHistory")
        }
    }

    private static func loadConnectionHistory(defaults: UserDefaults) -> [ConnectionHistoryItem] {
        guard let data = defaults.data(forKey: "cloudex.connectionHistory"),
              let items = try? JSONDecoder().decode([ConnectionHistoryItem].self, from: data) else { return [] }
        return items.sorted { $0.lastUsedAt > $1.lastUsedAt }
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
                await synchronizeSelectedThreadIfNeeded(from: projectResponse.data)
                if let approvalsResponse { pendingApprovals = approvalsResponse.data }
                status = "已连接 · \(activeConnectionTitle) · \(Date().formatted(date: .omitted, time: .standard))"
                if switchedConnection && streamsStarted {
                    connectGlobalStream()
                    if let selectedThreadID { connectThreadStream(threadID: selectedThreadID) }
                }
            return
            } catch {
                lastError = error
            }
        }
        isServerReachable = false
        status = "连接失败：\(lastError?.localizedDescription ?? "无法访问局域网或 Tailscale 地址")"
    }

    func reconnect() async {
        globalSSE.stop()
        threadSSE.stop()
        streamsStarted = false
        await refresh()
        guard isServerReachable else { return }
        streamsStarted = true
        connectGlobalStream()
        if let selectedThreadID { connectThreadStream(threadID: selectedThreadID) }
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
                let fallbackModelID = visibleModels.first(where: { $0.isDefault == true })?.identifier
                    ?? visibleModels.first?.identifier
                    ?? ""
                if !visibleModels.contains(where: { $0.identifier == selectedModelID }) {
                    selectedModelID = fallbackModelID
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
        isOpeningThread = true
        defer { isOpeningThread = false }
        selectedProjectCWD = projectCWD
        selectedThreadID = thread.id
        isCreatingNew = false
        clearLiveMessages()
        localError = nil
        attachedFiles = []
        detail = ThreadDetail(thread: thread, turns: [])
        // Do not carry the previous conversation's model into this one while
        // the authoritative Codex model list is being refreshed.
        selectedModelID = ""
        selectedEffortID = ""
        await refreshModelsForConversation()
        guard selectedThreadID == thread.id else { return }
        applyConversationModel(thread.model)
        liveRunning = thread.isActive
        messageIndex = []
        let cache = conversationCache
        let cachedDetail = await Task.detached(priority: .userInitiated) {
            cache.loadThreadDetail(threadID: thread.id)
        }.value
        guard selectedThreadID == thread.id else { return }
        if let cachedDetail {
            detail = cachedDetail
            applyConversationModel(cachedDetail.thread.model)
            liveRunning = cachedDetail.thread.isActive
        }
        let cachedIndex = await Task.detached(priority: .utility) {
            cache.loadMessageIndex(threadID: thread.id)
        }.value
        guard selectedThreadID == thread.id else { return }
        if let cachedIndex { messageIndex = cachedIndex }
        await loadThread(thread.id, force: true, replacingHistory: true)
        connectThreadStream(threadID: thread.id)
        if liveRunning {
            startPolling(threadID: thread.id)
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func refreshModelsForConversation() async {
        while modelsLoading {
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { return }
        }
        await loadModelsIfNeeded(force: true)
    }

    private func applyConversationModel(_ modelValue: String?) {
        guard let model = modelValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              models.contains(where: { $0.identifier == model }) else {
            if !models.contains(where: { $0.identifier == selectedModelID }) {
                selectedModelID = models.first(where: { $0.isDefault == true })?.identifier
                    ?? models.first?.identifier
                    ?? ""
            }
            normalizeEffortForSelectedModel()
            return
        }
        selectedModelID = model
        normalizeEffortForSelectedModel()
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
        messageIndex = []
        threadSSE.stop()
        pollTask?.cancel()
    }

    func loadThread(_ threadID: String, force: Bool = false, replacingHistory: Bool = false) async {
        if liveRunning && !force { return }
        detailLoadGeneration += 1
        let generation = detailLoadGeneration
        let wasActive = active
        do {
            let result: ThreadDetail = try await client.get(
                client.threadPath(threadID),
                // Load the complete timeline before the first layout pass.
                // Expanding a process row must not trigger a second response
                // that changes the scrollable content height.
                queryItems: []
            )
            guard selectedThreadID == threadID, generation == detailLoadGeneration else { return }
            let updatedDetail = replacingHistory ? result : mergingLatestPage(result, into: detail)
            if detail != updatedDetail {
                detail = updatedDetail
                let cache = conversationCache
                Task.detached(priority: .utility) {
                    cache.saveThreadDetail(result, threadID: threadID)
                }
            }
            rebuildMessageIndex(from: updatedDetail, threadID: threadID)
            removePersistedLiveMessages(from: result)
            liveRunning = result.thread.isActive
            if let error = result.turns.last(where: { $0.error != nil })?.error {
                status = "任务失败：\(error.displayText)"
            }
            if wasActive && !active {
                schedulePendingSteerAutoSend()
            }
        } catch {
            status = "读取会话失败：\(error.localizedDescription)"
        }
    }

    func loadMessageFromIndex(messageID: String, turnID: String) async -> Bool {
        renderedMessages.contains { $0.id == messageID }
    }

    func loadTurnDetails(turnID: String) async -> Bool {
        guard let threadID = selectedThreadID,
              let current = detail,
              let index = current.turns.firstIndex(where: { $0.id == turnID }) else { return false }
        if current.turns[index].processDetailsAreLoaded { return true }
        do {
            let result: TurnDetailResponse = try await client.get(client.threadTurnPath(threadID, turnID: turnID))
            guard selectedThreadID == threadID, let latest = detail,
                  let latestIndex = latest.turns.firstIndex(where: { $0.id == turnID }) else { return false }
            var turns = latest.turns
            turns[latestIndex] = result.turn
            detail = ThreadDetail(
                thread: latest.thread,
                turns: turns,
                hasMoreBefore: false,
                nextBefore: nil
            )
            return true
        } catch {
            status = "读取过程详情失败：\(error.localizedDescription)"
            return false
        }
    }

    private func mergingLatestPage(_ latest: ThreadDetail, into current: ThreadDetail?) -> ThreadDetail {
        guard let current, !current.turns.isEmpty else { return latest }
        let currentByID = Dictionary(uniqueKeysWithValues: current.turns.map { ($0.id, $0) })
        let turns = latest.turns.map { compactTurn in
            guard let existing = currentByID[compactTurn.id], existing.processDetailsAreLoaded else { return compactTurn }
            // Active compact responses intentionally contain the complete,
            // growing timeline and are marked detailsLoaded. Reusing the
            // first loaded object here would discard every later desktop
            // polling snapshot until the conversation is reopened.
            if isTurnInProgress(compactTurn) || isTurnInProgress(existing) {
                return compactTurn
            }
            // Preserve an explicitly loaded full timeline only after the turn
            // is stable; completed compact snapshots omit process details.
            return existing
        }
        return ThreadDetail(
            thread: latest.thread,
            turns: turns,
            hasMoreBefore: false,
            nextBefore: nil
        )
    }

    private func rebuildMessageIndex(from detail: ThreadDetail, threadID: String) {
        let items = detail.turns.flatMap { turn in
            let turnItems = turn.items ?? []
            let finalAgentIndex = turnItems.lastIndex { $0.type == "agentMessage" && $0.phase == "final_answer" }
                ?? turnItems.lastIndex { $0.type == "agentMessage" }
            return turnItems.enumerated().compactMap { index, item -> MessageIndexItem? in
                guard item.type == "userMessage" || index == finalAgentIndex else { return nil }
                let text = item.renderedText
                    .prefix(240)
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                guard !text.isEmpty else { return nil }
                return MessageIndexItem(
                    id: item.id ?? "\(turn.id)-\(item.type)-\(index)",
                    turnId: turn.id,
                    role: item.type == "userMessage" ? "user" : "assistant",
                    text: text,
                    createdAt: item.createdAt ?? turn.startedAt
                )
            }
        }
        guard items != messageIndex else { return }
        messageIndex = items
        let cache = conversationCache
        Task.detached(priority: .utility) {
            cache.saveMessageIndex(items, threadID: threadID)
        }
    }

    func send() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard !active else {
            queueSteerDraft()
            return
        }
        _ = await submitPrompt(prompt, steering: false)
    }

    func queueSteerDraft() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !prompt.isEmpty else { return }
        if pendingSteerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingSteerDraft = draft
        } else {
            pendingSteerDraft += "\n\n\(draft)"
        }
        draft = ""
    }

    func editPendingSteer() {
        let prompt = pendingSteerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        pendingSteerDraft = ""
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = prompt
        } else {
            draft += "\n\n\(prompt)"
        }
    }

    func deletePendingSteer() {
        pendingSteerDraft = ""
    }

    func sendPendingSteer() async {
        let prompt = pendingSteerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let steering = active
        guard await submitPrompt(prompt, steering: steering) else { return }
        if pendingSteerDraft.trimmingCharacters(in: .whitespacesAndNewlines) == prompt {
            pendingSteerDraft = ""
        }
    }

    private func schedulePendingSteerAutoSend() {
        guard !pendingSteerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pendingSteerAutoSendInFlight else { return }
        Task { @MainActor [weak self] in
            await self?.sendPendingSteerAfterTask()
        }
    }

    private func sendPendingSteerAfterTask() async {
        guard !pendingSteerAutoSendInFlight else { return }
        let prompt = pendingSteerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !active else { return }
        pendingSteerAutoSendInFlight = true
        defer { pendingSteerAutoSendInFlight = false }
        guard await submitPrompt(prompt, steering: false) else { return }
        if pendingSteerDraft.trimmingCharacters(in: .whitespacesAndNewlines) == prompt {
            pendingSteerDraft = ""
        }
    }

    private func submitPrompt(_ prompt: String, steering: Bool) async -> Bool {
        let wasRunning = active
        isBusy = true
        liveRunning = true
        clearLiveMessages()
        localError = nil
        var body: [String: Any] = [:]
        if !steering {
            if !selectedModelID.isEmpty { body["model"] = selectedModelID }
            if !selectedEffortID.isEmpty { body["effort"] = selectedEffortID }
            body.merge(codexModePayload) { _, new in new }
        }
        if !attachedFiles.isEmpty { body["files"] = attachedFiles.map { ["path": $0.path] } }
        do {
            if let selectedThreadID {
                body["message"] = prompt
                let action = steering ? "steer" : "message"
                let _: EmptyResponse = try await client.post(client.threadPath(selectedThreadID, action: action), json: body)
                draft = ""
                attachedFiles = []
                await loadThread(selectedThreadID)
                isBusy = false
                return true
            } else {
                guard !steering else {
                    status = "当前没有可引导的任务"
                    isBusy = false
                    return false
                }
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
                isBusy = false
                return true
            }
        } catch {
            liveRunning = wasRunning
            localError = error.localizedDescription
            status = "发送失败：\(error.localizedDescription)"
            isBusy = false
            return false
        }
    }

    func forkAssistantMessage(_ message: ChatMessage) async -> Bool {
        guard let threadID = selectedThreadID,
              let turnID = message.sourceTurnID else {
            status = "无法确定这条回复所属的对话轮次"
            return false
        }
        return await forkThread(
            threadID: threadID,
            turnID: turnID,
            position: "through",
            editedMessage: nil
        )
    }

    func editUserMessage(_ message: ChatMessage, replacement: String) async -> Bool {
        guard let threadID = selectedThreadID,
              let turnID = message.sourceTurnID else {
            status = "无法确定这条消息所属的对话轮次"
            return false
        }
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await forkThread(
            threadID: threadID,
            turnID: turnID,
            position: "before",
            editedMessage: trimmed
        )
    }

    private func forkThread(
        threadID: String,
        turnID: String,
        position: String,
        editedMessage: String?
    ) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        var payload: [String: Any] = [
            "turnId": turnID,
            "position": position,
        ]
        if let editedMessage { payload["message"] = editedMessage }
        if !selectedModelID.isEmpty { payload["model"] = selectedModelID }
        if !selectedEffortID.isEmpty { payload["effort"] = selectedEffortID }
        payload.merge(codexModePayload) { _, new in new }
        do {
            let result: ForkThreadResponse = try await client.post(
                client.threadPath(threadID, action: "fork"),
                json: payload
            )
            clearMessageJumpRequest()
            let projectCWD = selectedProjectCWD
            await openThread(result.thread, projectCWD: projectCWD)
            threadNavigationRequest = ThreadNavigationRequest(threadID: result.thread.id)
            await refresh()
            status = editedMessage == nil ? "已分叉对话" : "已从修改后的消息继续对话"
            return true
        } catch {
            status = "分叉对话失败：\(error.localizedDescription)"
            return false
        }
    }

    func clearThreadNavigationRequest() {
        threadNavigationRequest = nil
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

    func previewFile(path: String) async throws -> Data {
        try await client.download("/api/file", queryItems: [URLQueryItem(name: "path", value: path)])
    }

    func loadProjectReview(path: String) async throws -> ProjectReviewResponse {
        var lastError: Error?
        for candidate in connectionCandidates {
            do {
                let candidateClient = APIClient(serverURL: candidate, token: authToken)
                let response: ProjectReviewResponse = try await candidateClient.get(
                    "/api/review",
                    queryItems: [URLQueryItem(name: "path", value: path)]
                )
                if normalizedURL(serverURL) != candidate {
                    serverURL = candidate
                }
                return response
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIClientError.invalidServerURL
    }

    func searchConversationMessages(_ query: String) async -> [ConversationSearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        for candidate in connectionCandidates {
            do {
                let candidateClient = APIClient(serverURL: candidate, token: authToken)
                let response: ConversationSearchResponse = try await candidateClient.get(
                    "/api/search/messages",
                    queryItems: [URLQueryItem(name: "q", value: trimmed)]
                )
                if normalizedURL(serverURL) != candidate { serverURL = candidate }
                return response.data
            } catch {
                continue
            }
        }
        return []
    }

    func requestMessageJump(threadID: String, messageID: String, turnID: String, query: String) {
        pendingMessageJump = PendingMessageJump(
            threadID: threadID,
            messageID: messageID,
            turnID: turnID,
            query: query
        )
    }

    func clearMessageJumpRequest() {
        pendingMessageJump = nil
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

    func selectCodexMode(_ mode: CodexExecutionMode) {
        codexMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "cloudex.codexMode")
    }

    func isPinned(_ threadID: String) -> Bool {
        pinnedThreadIDs.contains(threadID)
    }

    func togglePinned(_ threadID: String) {
        if pinnedThreadIDs.contains(threadID) {
            pinnedThreadIDs.remove(threadID)
        } else {
            pinnedThreadIDs.insert(threadID)
        }
        UserDefaults.standard.set(Array(pinnedThreadIDs).sorted(), forKey: "cloudex.pinnedThreadIDs")
    }

    private var codexModePayload: [String: Any] {
        [
            "sandbox": codexMode.sandbox,
            "approvalPolicy": codexMode.approvalPolicy,
            "approvalsReviewer": codexMode.approvalsReviewer,
            "sandboxPolicy": ["type": codexMode.sandboxPolicyType],
        ]
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

    private func synchronizeSelectedThreadIfNeeded(from snapshotProjects: [CloudexProject]) async {
        guard let selectedThreadID,
              let snapshotThread = snapshotProjects
                .flatMap(\.threads)
                .first(where: { $0.id == selectedThreadID }),
              snapshotThread.isActive || active else { return }

        let wasActive = active
        guard self.selectedThreadID == selectedThreadID else { return }
        await loadThread(selectedThreadID, force: true)
        guard self.selectedThreadID == selectedThreadID else { return }

        if active, !wasActive {
            connectThreadStream(threadID: selectedThreadID)
            startPolling(threadID: selectedThreadID)
        } else if !active, wasActive {
            threadSSE.stop()
            pollTask?.cancel()
            pollTask = nil
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
        threadStreamReplaying = true
        do {
            let url = try client.makeURL(path: client.threadPath(threadID, action: "stream"))
            threadSSE.onEvent = { [weak self] event in
                Task { @MainActor in self?.handleThreadEvent(event, expectedThreadID: threadID) }
            }
            threadSSE.onOpen = { [weak self] in
                Task { @MainActor in self?.threadStreamReplaying = true }
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
           let resolved = try? JSONDecoder().decode(ApprovalResolvedEvent.self, from: event.data) {
            let approval = resolved.approval ?? pendingApprovals.first { $0.id == resolved.id }
            let threadID = resolved.threadId ?? approval?.threadId
            if let rawDecision = resolved.decision,
               let decision = ApprovalDecision(rawValue: rawDecision) {
                if let approval {
                    appendApprovalSystemMessage(approval: approval, decision: decision)
                } else {
                    appendApprovalSystemMessage(
                        approvalID: resolved.id,
                        threadID: threadID,
                        decision: decision,
                        requestedAt: nil
                    )
                }
            }
            pendingApprovals.removeAll { $0.id == resolved.id }
            CloudexAppDelegate.notifications.removeApproval(resolved.id)
            return
        }
        if event.name == "threads/changed",
           let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: event.data) {
            applyProjects(snapshot.projects)
            Task { await synchronizeSelectedThreadIfNeeded(from: snapshot.projects) }
        }
    }

    private func appendApprovalSystemMessage(approval: ApprovalRequest, decision: ApprovalDecision) {
        let turnID = approval.turnId
            ?? approval.threadId.flatMap { activeTurnNotificationKeys[$0] }
        if approval.threadId == selectedThreadID, let turnID {
            let id = "approval-\(approval.id)-\(decision.rawValue)"
            let existingIndex = liveMessages.firstIndex { $0.id == id }
            let createdAt = existingIndex.flatMap { liveMessages[$0].createdAt } ?? nextLiveCreatedAt()
            let message = ChatMessage(
                id: id,
                role: .execution,
                text: approvalConfirmationText(approval: approval, decision: decision),
                executionStatus: decision == .decline ? "declined" : "completed",
                executionKind: "approval",
                createdAt: createdAt,
                threadID: approval.threadId
            )
            liveMessageTurnIDs[id] = turnID
            systemMessages.removeAll { $0.id == id }
            if let existingIndex {
                liveMessages[existingIndex] = message
            } else {
                liveMessages.append(message)
            }
            return
        }
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
        if let reason = approval.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            details.append("说明：\(reason)")
        }
        if let context = approval.networkApprovalContext, let host = context.host, !host.isEmpty {
            let scheme = context.protocolName.map { "\($0)://" } ?? ""
            let port = context.port.map { ":\($0)" } ?? ""
            details.append("网络：\(scheme)\(host)\(port)")
        }
        if let permissionSummary = approval.permissionSummary, !permissionSummary.isEmpty {
            details.append("权限：\(permissionSummary)")
        }
        if let command = approval.command, !command.isEmpty {
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
        if event.name == "replay-complete" {
            threadStreamReplaying = false
            return
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
            let turnID = params["turnId"] as? String
                ?? (params["turn"] as? [String: Any])?["id"] as? String
                ?? UUID().uuidString
            let previousTurnID = activeTurnNotificationKeys[expectedThreadID]
            activeTurnNotificationKeys[expectedThreadID] = turnID
            // Compaction resumes the same logical turn and can emit another
            // turn/started. Preserve everything already shown for that turn.
            if previousTurnID != turnID { clearLiveMessages() }
            localError = nil
        } else if method == "item/started" {
            let item = params["item"] as? [String: Any]
            let turnID = liveTurnID(from: params, item: item, threadID: expectedThreadID)
            if let item, isCompactionItem(item) {
                recordLiveCompaction(turnID: turnID)
                return
            }
            if let item, isLiveExecutionItem(item) {
                upsertLiveExecution(
                    item: item,
                    fallbackID: params["itemId"] as? String,
                    turnID: turnID,
                    status: "inProgress"
                )
                liveRunning = true
                return
            }
            guard item?["type"] as? String == "agentMessage" else { return }
            liveRunning = true
            guard let itemID = item?["id"] as? String else { return }
            beginLiveMessage(
                id: itemID,
                turnID: turnID,
                text: liveText(from: item)
            )
        } else if method == "item/agentMessage/delta" {
            liveRunning = true
            guard let itemID = params["itemId"] as? String else { return }
            appendLiveDelta(
                id: itemID,
                turnID: liveTurnID(from: params, threadID: expectedThreadID),
                delta: params["delta"] as? String ?? ""
            )
        } else if method == "item/completed" || method == "item/updated" {
            let item = params["item"] as? [String: Any]
            let turnID = liveTurnID(from: params, item: item, threadID: expectedThreadID)
            if let item, isCompactionItem(item) {
                recordLiveCompaction(turnID: turnID)
                return
            }
            if let item, isLiveExecutionItem(item) {
                upsertLiveExecution(
                    item: item,
                    fallbackID: params["itemId"] as? String,
                    turnID: turnID,
                    status: item["status"] as? String ?? "completed"
                )
                return
            }
            guard item?["type"] as? String == "agentMessage" else { return }
            let text = liveText(from: item)
            if let completedID = item?["id"] as? String, !text.isEmpty {
                beginLiveMessage(id: completedID, turnID: turnID, text: text)
            }
        } else if method.lowercased().contains("compact") || method.lowercased().contains("compress") {
            recordLiveCompaction(turnID: liveTurnID(from: params, threadID: expectedThreadID))
        } else if ["turn/failed", "turn/interrupted", "turn/cancelled", "turn/canceled"].contains(method) {
            liveRunning = false
            if let errorText = notificationErrorText(params) {
                localError = errorText
                status = "任务失败：\(errorText)"
                notifyTaskResultOnce(threadID: expectedThreadID, params: params, success: false, detail: errorText)
            } else {
                notifyTaskResultOnce(threadID: expectedThreadID, params: params, success: false)
            }
            reloadAfterEvent(expectedThreadID, waitForTerminalSnapshot: true)
        } else if method == "turn/completed" {
            liveRunning = false
            if let errorText = notificationErrorText(params) {
                localError = errorText
                status = "任务失败：\(errorText)"
                notifyTaskResultOnce(threadID: expectedThreadID, params: params, success: false, detail: errorText)
            } else {
                localError = nil
                notifyTaskResultOnce(threadID: expectedThreadID, params: params, success: true)
            }
            reloadAfterEvent(expectedThreadID, waitForTerminalSnapshot: true)
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

    private func notifyTaskResultOnce(
        threadID: String,
        params: [String: Any],
        success: Bool,
        detail: String? = nil
    ) {
        guard !threadStreamReplaying else { return }
        let turnID = params["turnId"] as? String
            ?? (params["turn"] as? [String: Any])?["id"] as? String
        let key = activeTurnNotificationKeys[threadID]
            ?? turnID
            ?? "thread-\(threadID)"
        guard sentTaskResultNotificationKeys.insert("\(threadID):\(key)").inserted else { return }
        CloudexAppDelegate.notifications.scheduleTaskResult(
            threadID: threadID,
            title: selectedThread?.title ?? "当前对话",
            success: success,
            detail: detail
        )
    }

    private func reloadAfterEvent(_ threadID: String, waitForTerminalSnapshot: Bool = false) {
        Task { [weak self] in
            let delays: [Duration] = waitForTerminalSnapshot
                ? [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2)]
                : [.milliseconds(250)]
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let self, self.selectedThreadID == threadID else { return }
                await self.loadThread(threadID, force: true)
                if !waitForTerminalSnapshot || self.hasTerminalSnapshot(for: threadID) {
                    break
                }
            }
            guard let self else { return }
            await self.refresh()
        }
    }

    private func hasTerminalSnapshot(for threadID: String) -> Bool {
        guard selectedThreadID == threadID,
              !liveRunning,
              selectedThread?.isActive != true,
              let lastTurn = detail?.turns.last,
              lastTurn.status != nil else { return false }
        return !isTurnInProgress(lastTurn)
    }

    private func startPolling(threadID: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.selectedThreadID == threadID else { return }
                guard self.active else { return }
                // Desktop-started turns can update the persisted session
                // without emitting notifications on this app-server stream.
                // Keep the selected conversation current with a snapshot
                // fallback. ContentView merges these rows without issuing a
                // scroll request when the user is not following the bottom.
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
