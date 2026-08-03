import SwiftUI
import gitdiff

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showingSidebar = false
    @State private var showingSettings = false
    @State private var showingFilePicker = false
    @State private var isAtChatBottom = true
    @State private var scrollToBottomRequest = 0
    @State private var collapseProcessRequest = 0
    @State private var floatingCollapseVisible = false
    @State private var scrollTargetMessageID: String?
    @State private var suppressAutomaticScroll = false
    @State private var messageJumpSnapshot: [ChatMessage] = []

    var body: some View {
        ZStack {
            liquidBackground
            chat
            if floatingCollapseVisible {
                VStack {
                    HStack {
                        Button {
                            collapseProcessRequest += 1
                            floatingCollapseVisible = false
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.caption.weight(.bold))
                                .frame(width: 34, height: 34)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .liquidGlass(in: Circle(), interactive: true)
                        .accessibilityLabel("收起查看过程")
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 14)
                    .padding(.top, 68)
                    Spacer(minLength: 0)
                }
                .transition(.scale.combined(with: .opacity))
                .zIndex(10)
            }
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if !isAtChatBottom {
                    Button {
                        isAtChatBottom = true
                        scrollToBottomRequest += 1
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 42, height: 42)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlass(in: Circle(), interactive: true)
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
                    .padding(.bottom, 6)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("滚动到最新消息")
                }
                composer
            }
            .animation(.easeInOut(duration: 0.18), value: isAtChatBottom)
        }
        .ignoresSafeArea(.keyboard, edges: .top)
        .onChange(of: userMessageSignature, initial: true) { _, _ in
            messageJumpSnapshot = currentUserMessages
        }
        .task {
            await viewModel.start()
            await viewModel.loadModelsIfNeeded()
        }
        .sheet(isPresented: $showingSidebar) {
            SidebarView(isPresented: $showingSidebar)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(isPresented: $showingSettings)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingFilePicker) {
            RemoteFilePickerView(
                isPresented: $showingFilePicker,
                initialPath: viewModel.selectedProjectCWD ?? viewModel.selectedThread?.cwd ?? viewModel.projects.first?.cwd ?? ""
            ) { file in
                viewModel.attach(file)
            }
            .environmentObject(viewModel)
        }
    }

    private var liquidBackground: some View {
        ZStack {
            Color(.systemBackground)
            RadialGradient(
                colors: [Color.blue.opacity(0.13), Color.clear],
                center: .topLeading,
                startRadius: 15,
                endRadius: 360
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.09), Color.clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { showingSidebar = true } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .liquidGlass(in: Circle(), interactive: true)
            .shadow(color: .black.opacity(0.09), radius: 12, y: 5)
            .accessibilityLabel("打开项目菜单")

            MessageJumpSystemMenu(
                messages: messageJumpSnapshot,
                title: viewModel.navigationTitle,
                projectTitle: viewModel.projectTitle,
                isConnected: viewModel.isConnected,
                onSelect: { scrollTargetMessageID = $0 }
            )
            .equatable()

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .liquidGlass(in: Circle(), interactive: true)
            .shadow(color: .black.opacity(0.09), radius: 12, y: 5)
            .accessibilityLabel("打开设置")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            trackedChatScrollView {
                let messages = viewModel.renderedMessages
                LazyVStack(spacing: 12) {
                    if viewModel.selectedThread == nil && messages.isEmpty {
                        VStack(spacing: 10) {
                            Spacer(minLength: 130)
                            Text(viewModel.isCreatingNew ? "开始新对话" : "选择一个对话")
                                .font(.title2.bold())
                            Text(viewModel.selectedProject == nil
                                 ? "点击左上角菜单选择电脑上的项目和历史对话。"
                                 : "当前项目：\(viewModel.selectedProject?.displayName ?? "")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Spacer(minLength: 130)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if let thread = viewModel.selectedThread {
                        VStack(spacing: 4) {
                            Text("\(threadStatus(thread)) · \(DateFormatting.string(from: thread.updatedAt))")
                            Text(thread.cwd ?? "")
                                .lineLimit(2)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 4)
                    }

                    ForEach(messages) { message in
                        MessageBubble(
                            message: message,
                            collapseRequest: $collapseProcessRequest,
                            onFloatingStateChange: { visible in
                                floatingCollapseVisible = visible
                            }
                        )
                        .id(message.id)
                    }

                    ForEach(viewModel.visibleApprovals) { approval in
                        ApprovalBubble(approval: approval)
                            .environmentObject(viewModel)
                            .id("approval-\(approval.id)")
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if viewModel.active {
                        ProgressView()
                            .padding(.vertical, 8)
                    }

                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 78)
                .padding(.bottom, viewModel.attachedFiles.isEmpty ? 104 : 148)
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: viewModel.selectedThreadID) { _, _ in scrollToBottom(proxy, animated: false) }
            .onChange(of: viewModel.renderedMessages.count) { _, _ in
                if isAtChatBottom && !suppressAutomaticScroll { scrollToBottom(proxy, animated: false) }
            }
            .onChange(of: viewModel.liveMessages) { _, _ in
                if isAtChatBottom && !suppressAutomaticScroll { scrollToBottom(proxy, animated: false) }
            }
            .onChange(of: viewModel.visibleApprovals.count) { _, _ in
                if isAtChatBottom && !suppressAutomaticScroll { scrollToBottom(proxy, animated: false) }
            }
            .onChange(of: scrollToBottomRequest) { _, _ in
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: scrollTargetMessageID) { _, id in
                guard let id else { return }
                suppressAutomaticScroll = true
                isAtChatBottom = false
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .top)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    scrollTargetMessageID = nil
                    suppressAutomaticScroll = false
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var currentUserMessages: [ChatMessage] {
        viewModel.renderedMessages.filter { $0.role == .user }
    }

    private var userMessageSignature: [String] {
        currentUserMessages.map { "\($0.id):\($0.text)" }
    }

    @ViewBuilder
    private func trackedChatScrollView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 18.0, *) {
            ScrollView {
                content()
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                let distanceToBottom = geometry.contentSize.height - visibleBottom
                return geometry.contentSize.height <= geometry.containerSize.height || distanceToBottom <= 80
            } action: { _, atBottom in
                isAtChatBottom = atBottom
            }
        } else {
            ScrollView {
                content()
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !viewModel.attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(viewModel.attachedFiles) { file in
                            HStack(spacing: 5) {
                                Image(systemName: "doc")
                                Text(file.name).lineLimit(1)
                                Button { viewModel.removeAttachment(file) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .liquidGlass(in: Capsule(), interactive: true)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }

            HStack(spacing: 7) {
                Menu {
                    if viewModel.models.isEmpty {
                        Button {
                            Task { await viewModel.loadModelsIfNeeded(force: true) }
                        } label: {
                            Label("读取模型列表", systemImage: "arrow.clockwise")
                        }
                    } else {
                        ForEach(viewModel.models, id: \.identifier) { model in
                            Button {
                                viewModel.selectModel(model.identifier)
                            } label: {
                                if model.identifier == viewModel.selectedModelID {
                                    Label(model.title, systemImage: "checkmark")
                                } else {
                                    Text(model.title)
                                }
                            }
                        }

                        Divider()

                        Button {
                            Task { await viewModel.loadModelsIfNeeded(force: true) }
                        } label: {
                            Label("刷新模型列表", systemImage: "arrow.clockwise")
                        }
                    }
                } label: {
                    Text(viewModel.compactModelTitle)
                        .lineLimit(1)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Capsule(), interactive: true)
                .accessibilityLabel("切换模型")

                Menu {
                    if viewModel.availableEfforts.isEmpty {
                        Text("默认")
                    } else {
                        ForEach(viewModel.availableEfforts) { effort in
                            Button {
                                viewModel.selectEffort(effort.reasoningEffort)
                            } label: {
                                if effort.reasoningEffort == viewModel.selectedEffortID {
                                    Label(effort.title, systemImage: "checkmark")
                                } else {
                                    Text(effort.title)
                                }
                            }
                        }
                    }
                } label: {
                    Text("用量 \(viewModel.selectedEffortTitle)")
                        .lineLimit(1)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Capsule(), interactive: true)
                .accessibilityLabel("切换用量")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)

            HStack(alignment: .bottom, spacing: 8) {
                Button { showingFilePicker = true } label: {
                    Image(systemName: "paperclip")
                        .font(.body.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled((viewModel.selectedProjectCWD ?? viewModel.selectedThread?.cwd ?? viewModel.projects.first?.cwd) == nil)

                ZStack(alignment: .topLeading) {
                    if viewModel.draft.isEmpty {
                        Text(viewModel.selectedThreadID == nil ? "向 Codex 发送新指令…" : "继续发送指令…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 10)
                    }
                    TextEditor(text: $viewModel.draft)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 38, maxHeight: 110)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 3)

                if viewModel.active {
                    Button { Task { await viewModel.stop() } } label: {
                        Image(systemName: "stop.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(width: 38, height: 38)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy)
                } else {
                    Button { Task { await viewModel.send() } } label: {
                        Group {
                            if viewModel.isBusy {
                                ProgressView().tint(.accentColor)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.body.bold())
                                    .foregroundStyle(.primary)
                            }
                        }
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            } else {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            isAtChatBottom = true
        }
    }

    private func threadStatus(_ thread: CloudexThread) -> String {
        if thread.status?.type == "active", thread.status?.activeFlags?.contains("waitingOnApproval") == true { return "等待审批" }
        if thread.status?.type == "active" { return "运行中" }
        if thread.status?.type == "idle" { return "已完成" }
        if thread.status?.type == "notLoaded" { return "未加载" }
        return thread.status?.type ?? "未知状态"
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    @Binding var collapseRequest: Int
    let onFloatingStateChange: (Bool) -> Void

    @ViewBuilder
    var body: some View {
        if message.role == .execution {
            ExecutionStepRow(message: message)
        } else if message.role == .processSummary {
            ProcessSummaryBubble(
                message: message,
                collapseRequest: $collapseRequest,
                onFloatingStateChange: onFloatingStateChange
            )
        } else if message.role == .taskSummary || message.role == .compressed || message.role == .system {
            SystemTimelineBubble(message: message)
        } else {
            HStack {
                if message.role == .user { Spacer(minLength: 42) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(roleTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(message.role == .error ? Color.red : Color.secondary)
                    MarkdownText(text: message.text)
                        .font(.body)
                        .foregroundStyle(message.role == .error ? Color.red : Color.primary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                    if !messageTime.isEmpty {
                        Text(messageTime)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if message.role == .error {
                        RoundedRectangle(cornerRadius: 16).stroke(Color.red.opacity(0.3))
                    }
                }
                if message.role != .user { Spacer(minLength: 42) }
            }
        }
    }

    private var roleTitle: String {
        switch message.role {
        case .user: return "你"
        case .assistant: return "Codex"
        case .error: return "错误"
        case .system: return "系统"
        case .execution: return "执行"
        case .processSummary: return "过程"
        case .compressed: return "Compressed"
        case .taskSummary: return "任务"
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: return Color.blue.opacity(0.14)
        case .assistant, .system: return Color(.secondarySystemBackground)
        case .error: return Color.red.opacity(0.1)
        case .execution: return Color(.tertiarySystemBackground)
        case .processSummary, .compressed, .taskSummary: return Color(.secondarySystemBackground)
        }
    }

    private var messageTime: String {
        DateFormatting.messageTime(from: message.createdAt)
    }
}

private struct ProcessSummaryBubble: View {
    let message: ChatMessage
    @Binding var collapseRequest: Int
    let onFloatingStateChange: (Bool) -> Void
    @State private var expanded = false
    @State private var expansionGeneration = 0
    @State private var expandedContentHeight: CGFloat = 0
    @State private var collapseButtonVisible = true
    @State private var bubbleVisible = true

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded.toggle()
                        if !expanded { expansionGeneration += 1 }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                            .foregroundStyle(.secondary)
                        MarkdownText(text: message.text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(ScrollVisibilityModifier { visible in
                    collapseButtonVisible = visible
                    updateFloatingState()
                })

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(message.processItems ?? []) { item in
                            if item.role == .execution {
                                ExecutionStepRow(message: item)
                                    .id("\(item.id)-\(expansionGeneration)")
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(processItemTitle(item))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    MarkdownText(text: item.text)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                    let time = DateFormatting.messageTime(from: item.createdAt)
                                    if !time.isEmpty {
                                        Text(time)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ProcessContentHeightKey.self, value: geometry.size.height)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                let time = DateFormatting.messageTime(from: message.createdAt)
                if !time.isEmpty {
                    Text(time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer(minLength: 32)
        }
        .onChange(of: message.id) { _, _ in
            expanded = false
            expansionGeneration += 1
            expandedContentHeight = 0
            collapseButtonVisible = true
            bubbleVisible = true
            onFloatingStateChange(false)
        }
        .onPreferenceChange(ProcessContentHeightKey.self) { height in
            expandedContentHeight = height
            updateFloatingState()
        }
        .modifier(ScrollVisibilityModifier { visible in
            bubbleVisible = visible
            updateFloatingState()
        })
        .onChange(of: expanded) { _, _ in
            updateFloatingState()
        }
        .onChange(of: collapseRequest) { _, _ in
            guard expanded else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                expanded = false
                expansionGeneration += 1
            }
            onFloatingStateChange(false)
        }
        .onDisappear {
            onFloatingStateChange(false)
        }
    }

    private func processItemTitle(_ item: ChatMessage) -> String {
        switch item.role {
        case .assistant: return "中间消息"
        case .compressed: return "Compressed"
        case .taskSummary: return "任务"
        case .system: return "系统"
        case .error: return "错误"
        default: return "过程"
        }
    }

    private var shouldShowFloatingCollapse: Bool {
        guard expandedContentHeight > 0 else { return false }
        return expandedContentHeight > UIScreen.main.bounds.height
    }

    private func updateFloatingState() {
        onFloatingStateChange(expanded && shouldShowFloatingCollapse && bubbleVisible && !collapseButtonVisible)
    }
}

private struct ProcessContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ScrollVisibilityModifier: ViewModifier {
    let onChange: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.1, onChange)
        } else {
            content
        }
    }
}

private struct SystemTimelineBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            Spacer(minLength: 28)
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                    MarkdownText(text: message.text)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(foregroundColor)
                .multilineTextAlignment(.center)
                let time = DateFormatting.messageTime(from: message.createdAt)
                if !time.isEmpty {
                    Text(time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemBackground), in: Capsule())
            Spacer(minLength: 28)
        }
    }

    private var iconName: String {
        message.role == .compressed ? "archivebox.fill" : "timer"
    }

    private var foregroundColor: Color {
        message.role == .compressed ? .secondary : .secondary
    }
}

private struct MarkdownText: View {
    let text: String
    @State private var rendered: AttributedString

    init(text: String) {
        self.text = text
        _rendered = State(initialValue: MarkdownText.parse(text))
    }

    var body: some View {
        Text(rendered)
            .onChange(of: text) { _, newValue in
                rendered = MarkdownText.parse(newValue)
            }
    }

    private static func parse(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct ExecutionStepRow: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                    .frame(width: 18, height: 20)

                VStack(alignment: .leading, spacing: 5) {
                    if message.executionKind == "edit" {
                        EditDiffView(text: message.text, diff: message.editDiff, expanded: expanded)
                    } else {
                        Text(message.text)
                            .font(.system(.subheadline, design: .monospaced).weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(expanded ? nil : 3)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                    }

                    if let detailText {
                        Text(detailText)
                            .font(.caption2)
                            .foregroundStyle(statusColor)
                    }
                }
                Spacer(minLength: 0)
                if canExpand {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if message.executionStatus == "inProgress" {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: message.executionStatus == "failed" ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        message.executionStatus == "failed" ? .red : (message.executionStatus == "inProgress" ? .secondary : .green)
    }

    private var detailText: String? {
        var values: [String] = []
        if let duration = message.executionDuration, !duration.isEmpty { values.append(duration) }
        if message.executionStatus == "failed", let code = message.executionExitCode { values.append("退出码 \(code)") }
        if message.executionStatus == "inProgress" { values.append("运行中") }
        let time = DateFormatting.messageTime(from: message.createdAt)
        if !time.isEmpty { values.append(time) }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var canExpand: Bool {
        if message.executionKind == "edit" { return true }
        return message.text.count > 100 || message.text.contains("\n")
    }
}

private struct EditDiffView: View {
    let text: String
    let diff: [EditDiffPayload]?
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                Spacer(minLength: 8)
                if hasDiffPayload {
                    Text("+\(totalAdditions) -\(totalDeletions)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if hasDiffPayload && expanded {
                CodexStyleDiffRenderer(payloads: payloads, expanded: expanded)
            } else {
                Text(hasDiffPayload ? "点击展开修改内容" : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(hasDiffPayload ? 1 : (expanded ? nil : 4))
                    .textSelection(.enabled)
            }
        }
    }

    private var title: String {
        let names = payloads.map { displayName($0.name) }
        guard !names.isEmpty else { return text }
        if names.count <= 2 { return "Edited \(names.joined(separator: ", "))" }
        return "Edited \(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
    }

    private var payloads: [EditDiffPayload] {
        diff ?? []
    }

    private var hasDiffPayload: Bool {
        !payloads.isEmpty
    }

    private var totalAdditions: Int {
        payloads.reduce(0) { total, payload in
            total + (payload.additions ?? payload.lines?.filter { $0.kind == "addition" }.count ?? 0)
        }
    }

    private var totalDeletions: Int {
        payloads.reduce(0) { total, payload in
            total + (payload.deletions ?? payload.lines?.filter { $0.kind == "deletion" }.count ?? 0)
        }
    }

    private func displayName(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "files" }
        return (name as NSString).lastPathComponent
    }
}

private struct CodexStyleDiffRenderer: View {
    let payloads: [EditDiffPayload]
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 0) {
                    if payloads.count > 1 {
                        HStack(alignment: .firstTextBaseline) {
                            Text(file.displayName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(fileStats(file))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemBackground))
                    }

                    ForEach(visibleLines(file)) { line in
                        CodexDiffLineRow(line: line)
                    }

                    if !expanded && hiddenLineCount(file) > 0 {
                        Text("⋮")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 54)
                            .padding(.vertical, 2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(.separator).opacity(0.45), lineWidth: 0.6)
                }
            }
        }
    }

    private var files: [DiffFile] {
        payloads.enumerated().map { index, payload in
            DiffFile(oldPath: displayName(payload.name), newPath: displayName(payload.name), hunks: [hunk(from: payload, index: index)])
        }
    }

    private func visibleLines(_ file: DiffFile) -> [DiffLine] {
        let lines = file.hunks.flatMap(\.lines)
        return changedLinesWithContext(lines)
    }

    /// Shows every changed line, plus exactly one context line before and after
    /// each contiguous change group. Unrelated code is represented by an ellipsis.
    private func changedLinesWithContext(_ lines: [DiffLine]) -> [DiffLine] {
        let changedIndexes = lines.indices.filter { index in
            lines[index].type == .added || lines[index].type == .removed
        }
        guard !changedIndexes.isEmpty else {
            return Array(lines.prefix(2))
        }

        var ranges: [ClosedRange<Int>] = []
        for index in changedIndexes {
            let proposed = max(lines.startIndex, index - 1)...min(lines.index(before: lines.endIndex), index + 1)
            if let last = ranges.last, proposed.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, proposed.upperBound)
            } else {
                ranges.append(proposed)
            }
        }

        var result: [DiffLine] = []
        for (offset, range) in ranges.enumerated() {
            if offset > 0 {
                result.append(DiffLine(type: .header, content: "⋮", oldLineNumber: nil, newLineNumber: nil))
            }
            result.append(contentsOf: lines[range])
        }
        return result
    }

    private func hiddenLineCount(_ file: DiffFile) -> Int {
        max(file.hunks.flatMap(\.lines).count - visibleLines(file).count, 0)
    }

    private func fileStats(_ file: DiffFile) -> String {
        let lines = file.hunks.flatMap(\.lines)
        let added = lines.filter { $0.type == .added }.count
        let removed = lines.filter { $0.type == .removed }.count
        return "+\(added) -\(removed)"
    }

    private func displayName(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "files" }
        return (name as NSString).lastPathComponent
    }

    private func hunk(from payload: EditDiffPayload, index: Int) -> DiffHunk {
        let sourceLines = payload.lines ?? []
        let start = firstLineNumber(in: sourceLines) ?? 1
        let mappedLines = mapLines(sourceLines, start: start)
        let oldCount = mappedLines.filter { $0.type == .context || $0.type == .removed }.count
        let newCount = mappedLines.filter { $0.type == .context || $0.type == .added }.count
        return DiffHunk(
            oldStart: start,
            oldCount: max(oldCount, 1),
            newStart: start,
            newCount: max(newCount, 1),
            header: "@@ -\(start),\(max(oldCount, 1)) +\(start),\(max(newCount, 1)) @@",
            lines: mappedLines
        )
    }

    private func mapLines(_ lines: [EditDiffLinePayload], start: Int) -> [DiffLine] {
        var oldCursor = start
        var newCursor = start
        return lines.map { line in
            switch line.kind {
            case "addition":
                let number = line.lineNumber ?? newCursor
                newCursor = number + 1
                return DiffLine(type: .added, content: content(line.text), oldLineNumber: nil, newLineNumber: number)
            case "deletion":
                let number = line.lineNumber ?? oldCursor
                oldCursor = number + 1
                return DiffLine(type: .removed, content: content(line.text), oldLineNumber: number, newLineNumber: nil)
            case "header":
                return DiffLine(type: .header, content: headerContent(line.text), oldLineNumber: nil, newLineNumber: nil)
            default:
                let number = line.lineNumber ?? min(oldCursor, newCursor)
                oldCursor = number + 1
                newCursor = number + 1
                return DiffLine(type: .context, content: content(line.text), oldLineNumber: number, newLineNumber: number)
            }
        }
    }

    private func firstLineNumber(in lines: [EditDiffLinePayload]) -> Int? {
        lines.compactMap(\.lineNumber).filter { $0 > 0 }.min()
    }

    private func content(_ value: String) -> String {
        if value.hasPrefix("+") || value.hasPrefix("-") || value.hasPrefix(" ") {
            return String(value.dropFirst())
        }
        return value
    }

    private func headerContent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("@@") { return "⋮" }
        return trimmed == "..." ? "⋮" : trimmed
    }
}

private struct CodexDiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(lineNumber)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 8)

            Text(prefix)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 14, alignment: .leading)

            Text(displayContent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(textColor)
                .lineLimit(nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 8)
        .background(backgroundColor)
    }

    private var lineNumber: String {
        switch line.type {
        case .added, .context:
            return line.newLineNumber.map(String.init) ?? line.oldLineNumber.map(String.init) ?? ""
        case .removed:
            return line.oldLineNumber.map(String.init) ?? ""
        case .header:
            return ""
        }
    }

    private var prefix: String {
        switch line.type {
        case .added: return "+"
        case .removed: return "-"
        case .context, .header: return " "
        }
    }

    private var displayContent: String {
        let text = line.content.isEmpty ? " " : line.content
        return line.type == .header ? "⋮" : text
    }

    private var prefixColor: Color {
        switch line.type {
        case .added: return .green
        case .removed: return .red
        case .context, .header: return .secondary
        }
    }

    private var textColor: Color {
        switch line.type {
        case .added: return .green
        case .removed: return .red
        case .context: return .primary
        case .header: return .secondary
        }
    }

    private var backgroundColor: Color {
        switch line.type {
        case .added: return Color.green.opacity(0.10)
        case .removed: return Color.red.opacity(0.10)
        case .context, .header: return Color(.secondarySystemBackground).opacity(0.55)
        }
    }
}

private struct ApprovalBubble: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let approval: ApprovalRequest

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Codex")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Label(cardTitle, systemImage: "exclamationmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.subheadline)
                }
                if let destination = networkDestination {
                    detailRow(title: "网络", value: destination)
                } else if let permissionSummary = approval.permissionSummary, !permissionSummary.isEmpty {
                    detailRow(title: "权限", value: permissionSummary)
                } else if let command = approval.command, !command.isEmpty {
                    detailRow(title: "命令", value: command)
                }
                if let path = approval.grantRoot ?? approval.cwd, !path.isEmpty {
                    detailRow(title: approval.isFileChange ? "路径" : "目录", value: path)
                }

                HStack(spacing: 7) {
                    approvalButton("允许", decision: .accept, color: .blue)
                    approvalButton("始终允许", decision: .acceptForSession, color: .green)
                    approvalButton("禁止", decision: .decline, color: .red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer(minLength: 32)
        }
    }

    private var networkDestination: String? {
        guard let context = approval.networkApprovalContext, let host = context.host else { return nil }
        let scheme = context.protocolName.map { "\($0)://" } ?? ""
        let port = context.port.map { ":\($0)" } ?? ""
        return "\(scheme)\(host)\(port)"
    }

    private var cardTitle: String {
        if approval.isPermissionRequest { return "额外权限需要审批" }
        if approval.isFileChange { return "文件修改需要审批" }
        return "操作需要审批"
    }

    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func approvalButton(_ title: String, decision: ApprovalDecision, color: Color) -> some View {
        Button(title) { Task { await viewModel.respondToApproval(approval, decision: decision) } }
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
            .buttonStyle(.plain)
    }
}

private struct MessageJumpSystemMenu: View, Equatable {
    let messages: [ChatMessage]
    let title: String
    let projectTitle: String
    let isConnected: Bool
    let onSelect: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messages == rhs.messages &&
        lhs.title == rhs.title &&
        lhs.projectTitle == rhs.projectTitle &&
        lhs.isConnected == rhs.isConnected
    }

    var body: some View {
        Menu {
            if messages.isEmpty {
                Text("暂无发送信息")
            } else {
                ForEach(messages) { message in
                    Button {
                        onSelect(message.id)
                    } label: {
                        Text(oneLineText(message.text))
                            .lineLimit(1)
                    }
                    .id("jump-menu-\(message.id)")
                }
            }
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(projectTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .contentShape(Capsule())
            .liquidGlass(in: Capsule(), interactive: true)
            .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        }
        .tint(.primary)
    }

    private func oneLineText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "（空消息）" : normalized
    }
}

private extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        if #available(iOS 26.0, *) {
            let glass = Glass.regular.tint(tint).interactive(interactive)
            self.glassEffect(glass, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? .clear), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.3), lineWidth: 0.7))
        }
    }
}
