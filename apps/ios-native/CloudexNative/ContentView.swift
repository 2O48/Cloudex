import SwiftUI
import gitdiff
import UIKit

private enum ConversationSubpage: Hashable {
    case conversation
    case files
    case review
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.cloudexIsWindowedIPad) private var isWindowedIPad
    @Environment(\.cloudexBottomSafeArea) private var bottomSafeArea
    @StateObject private var chatScrollController = ChatScrollController()
    let expectedThreadID: String?
    let onToggleDirectory: (() -> Void)?
    let showsDirectoryButton: Bool
    @State private var showingFilePicker = false
    @State private var isAtChatBottom = true
    @State private var isFollowingChatBottom = true
    @State private var hasLoadedChatContent = false
    @State private var scrollToBottomRequest = 0
    @State private var explicitScrollGeneration = 0
    @State private var isExplicitScrollInProgress = false
    @State private var initialBottomScrollGeneration = 0
    @State private var isInitialBottomScrollInProgress = false
    @State private var isPreparingInitialLayout = true
    @State private var isStaticConversationLocked = false
    @State private var messagePositioningGeneration = 0
    @State private var isMessagePositioningInProgress = false
    @State private var isProcessLayoutChangeInProgress = false
    @State private var processLayoutGeneration = 0
    @State private var processExpansionScrollOffset: CGPoint?
    @State private var isUserScrollingChat = false
    @State private var messageJumpSnapshot: [MessageJumpItem] = []
    @State private var scrollTargetMessageID: String?
    @State private var messageTextHighlight: MessageTextHighlight?
    @State private var chatContentSnapshot = ChatScrollContent.empty
    @State private var collapseProcessRequest = 0
    @State private var floatingCollapseVisible = false
    @State private var showingTokenUsage = false
    @State private var showingMessageDirectory = false
    @State private var taskTimerTurnID: String?
    @State private var taskTimerStartedAt: Double?
    @State private var taskTimerCompletedAt: Double?
    @State private var taskTimerHidden = true
    @FocusState private var composerFocused: Bool
    @State private var keyboardHeight: CGFloat = 0

    init(
        expectedThreadID: String? = nil,
        onToggleDirectory: (() -> Void)? = nil,
        showsDirectoryButton: Bool = true
    ) {
        self.expectedThreadID = expectedThreadID
        self.onToggleDirectory = onToggleDirectory
        self.showsDirectoryButton = showsDirectoryButton
    }

    var body: some View {
        ZStack {
            liquidBackground
            chat
                // Keep the full message tree in the hierarchy so SwiftUI
                // can measure it, but reveal text only after the initial
                // bottom position has been calculated.
                .opacity(isPreparingInitialLayout ? 0 : 1)
            if isPreparingInitialLayout {
                ProgressView()
                    .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial.opacity(0.72))
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(20)
            }
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
                    .padding(.top, 14)
                    Spacer(minLength: 0)
                }
                .transition(.scale.combined(with: .opacity))
                .zIndex(10)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                // Content growth briefly makes the geometry report that the
                // viewport is not at the bottom before follow-mode scrolling
                // catches up. Do not flash the button during that interval.
                // It becomes available only after a user gesture explicitly
                // leaves follow mode.
                if !isFollowingChatBottom {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            showLatestChatContent()
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.body.weight(.semibold))
                                .frame(width: 42, height: 42)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .liquidGlass(in: Circle(), interactive: true)
                        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
                        .accessibilityLabel("滚动到最新消息")
                        .transition(.scale.combined(with: .opacity))
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 6)
                }
                composer
            }
            .animation(.easeInOut(duration: 0.18), value: isFollowingChatBottom)
        }
        .ignoresSafeArea(.keyboard, edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(viewModel.navigationTitle)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.isConnected ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        Text(viewModel.isConnected ? "已连接" : "未连接")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(viewModel.isConnected ? "已连接" : "未连接")
                }
                .frame(maxWidth: 220)
            }
            if showsDirectoryButton {
                if let onToggleDirectory {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onToggleDirectory) {
                            Image(systemName: "list.bullet")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("打开侧边面板")
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingMessageDirectory = true
                        } label: {
                            Image(systemName: "list.bullet")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("打开侧边面板")
                    }
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $showingFilePicker) {
            RemoteFilePickerView(
                isPresented: $showingFilePicker,
                initialPath: viewModel.selectedProjectCWD ?? viewModel.selectedThread?.cwd ?? viewModel.projects.first?.cwd ?? ""
            ) { file in
                viewModel.attach(file)
            }
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingTokenUsage) {
            TokenUsageSheet(usage: viewModel.selectedThread?.usage)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingMessageDirectory) {
            NavigationStack {
                MessageJumpListView(
                    messages: messageJumpSnapshot,
                    onSelect: { showMessage($0.id) }
                )
                .environmentObject(viewModel)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingMessageDirectory = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("关闭侧边面板")
                    }
                }
            }
            .interactiveDismissDisabled(true)
            .presentationDragIndicator(.hidden)
        }
        .onChange(of: viewModel.messageIndex, initial: true) { _, items in
            // A native Menu loses its internal scroll position whenever its
            // children are rebuilt. Keep its data stable while a task streams
            // new messages, then refresh once after the task finishes.
            guard !viewModel.active || messageJumpSnapshot.isEmpty else { return }
            let snapshot = MessageJumpItem.paired(from: items, turns: viewModel.detail?.turns ?? [])
            if messageJumpSnapshot != snapshot {
                messageJumpSnapshot = snapshot
            }
        }
        .onChange(of: viewModel.active) { _, active in
            if active {
                isStaticConversationLocked = false
                updateChatContent(force: true)
            } else if hasLoadedChatContent && !isPreparingInitialLayout {
                // Apply the terminal snapshot once, then freeze completed
                // conversations against background layout changes.
                updateChatContent(force: true)
                DispatchQueue.main.async {
                    guard !viewModel.active, !isPreparingInitialLayout else { return }
                    isStaticConversationLocked = true
                }
            }
            guard !active else { return }
            let snapshot = MessageJumpItem.paired(
                from: viewModel.messageIndex,
                turns: viewModel.detail?.turns ?? []
            )
            if messageJumpSnapshot != snapshot {
                messageJumpSnapshot = snapshot
            }
        }
        .onChange(of: viewModel.isOpeningThread, initial: true) { _, opening in
            if opening {
                resetChatLayoutForNewThread()
                return
            }
            updateChatContent(force: !hasLoadedChatContent)
            // During an active task the target message can arrive while the
            // conversation is still opening. The ScrollView is disabled in
            // that phase, so keep the request alive and fulfill it only after
            // opening has completed.
            fulfillPendingMessageJumpIfPossible()
        }
        .onChange(of: viewModel.detail, initial: true) { _, _ in
            syncTaskTimerState()
        }
        .onChange(of: viewModel.liveRunning, initial: true) { _, _ in
            syncTaskTimerState()
        }
        .onChange(of: viewModel.selectedThreadID) { _, _ in
            taskTimerTurnID = nil
            taskTimerStartedAt = nil
            taskTimerCompletedAt = nil
            taskTimerHidden = true
            syncTaskTimerState()
        }
        .onChange(of: currentChatContent, initial: true) { _, _ in
            updateChatContent()
            fulfillPendingMessageJumpIfPossible()
        }
        .onChange(of: viewModel.pendingMessageJump, initial: true) { _, _ in
            fulfillPendingMessageJumpIfPossible()
        }
        .onChange(of: isFollowingChatBottom) { _, following in
            guard following,
                  !isPreparingInitialLayout,
                  !viewModel.isOpeningThread else { return }
            updateChatContent(force: true)
        }
        .onChange(of: expectedThreadID, initial: true) { _, _ in
            resetChatLayoutForNewThread()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
            keyboardHeight = max(0, UIScreen.main.bounds.maxY - value.cgRectValue.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
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

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let isNewChat = expectedThreadID?.hasPrefix("new-") == true
                let isReady = isNewChat
                    || (expectedThreadID == viewModel.selectedThreadID && !viewModel.isOpeningThread)
                let content = isReady ? chatContentSnapshot : .empty
                LazyVStack(spacing: 12) {
                    if !isReady {
                        ProgressView("正在打开对话…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    }
                    if isReady && viewModel.selectedThread == nil && content.messages.isEmpty {
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

                    if isReady, let thread = viewModel.selectedThread {
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

                    ForEach(content.messages) { message in
                        MessageBubble(
                            message: message,
                            highlightQuery: messageTextHighlight?.messageID == message.id
                                ? messageTextHighlight?.query
                                : nil,
                            collapseRequest: $collapseProcessRequest,
                            onQuickFill: { text in
                                viewModel.draft = text
                                composerFocused = true
                            },
                            onFork: {
                                await viewModel.forkAssistantMessage(message)
                            },
                            onProcessInteraction: { isExpanding in
                                beginProcessLayoutChange(expanding: isExpanding, restorePosition: false)
                            },
                            onFloatingProcessCollapse: {
                                beginProcessLayoutChange(expanding: false, restorePosition: true)
                            },
                            onFloatingStateChange: { visible in
                                floatingCollapseVisible = visible
                            }
                        )
                        .id(message.id)
                    }

                    ForEach(content.approvals) { approval in
                        ApprovalBubble(approval: approval)
                            .environmentObject(viewModel)
                            .id("approval-\(approval.id)")
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if content.active {
                        ProgressView()
                            .padding(.vertical, 8)
                    }

                    // Reserve only the space needed by the overlaid composer.
                    // Keeping this close to the actual composer height avoids
                    // leaving a visible gap below the running-task spinner.
                    Color.clear
                        .frame(height: viewModel.attachedFiles.isEmpty ? 112 : 156)
                        .id("chat-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .background {
                    ChatScrollViewResolver(controller: chatScrollController)
                        .frame(width: 0, height: 0)
                }
            }
            .nativeTopScrollEdgeEffect()
            .scrollDisabled(viewModel.isOpeningThread || isPreparingInitialLayout)
            .scrollDismissesKeyboard(.interactively)
            .trackChatScroll(
                isAtBottom: $isAtChatBottom,
                isFollowingBottom: $isFollowingChatBottom,
                isExplicitScrollInProgress: $isExplicitScrollInProgress,
                isUserScrolling: $isUserScrollingChat,
                isLayoutChangeInProgress: $isProcessLayoutChangeInProgress,
                isFollowRestorationDisabled: {
                    isPreparingInitialLayout || viewModel.isOpeningThread
                },
                nativeIsAtBottom: { chatScrollController.isAtBottom() }
            )
            .onChange(of: scrollToBottomRequest) { _, _ in
                guard !isMessagePositioningInProgress,
                      isFollowingChatBottom || isExplicitScrollInProgress else { return }
                let generation = explicitScrollGeneration
                let initialGeneration = initialBottomScrollGeneration
                let requestGeneration = scrollToBottomRequest
                DispatchQueue.main.async {
                    guard !isMessagePositioningInProgress,
                          scrollToBottomRequest == requestGeneration,
                          isFollowingChatBottom
                            || (isExplicitScrollInProgress && explicitScrollGeneration == generation) else { return }

                    let initialStillOwnsScroll = isInitialBottomScrollInProgress
                        && initialBottomScrollGeneration == initialGeneration
                        && isFollowingChatBottom
                        && !isUserScrollingChat
                    if initialStillOwnsScroll {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }

                        // One anchor repeat lets LazyVStack materialize the
                        // target row. A single native reconciliation then
                        // accounts for adjusted insets without repeatedly
                        // chasing a growing contentSize.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            guard isInitialBottomScrollInProgress,
                                  initialBottomScrollGeneration == initialGeneration,
                                  scrollToBottomRequest == requestGeneration,
                                  isFollowingChatBottom,
                                  !isUserScrollingChat else { return }
                            var repeatTransaction = Transaction()
                            repeatTransaction.disablesAnimations = true
                            withTransaction(repeatTransaction) {
                                proxy.scrollTo("chat-bottom", anchor: .bottom)
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            guard isInitialBottomScrollInProgress,
                                  initialBottomScrollGeneration == initialGeneration,
                                  scrollToBottomRequest == requestGeneration else { return }
                            if isFollowingChatBottom && !isUserScrollingChat {
                                _ = chatScrollController.scrollToBottom(animated: false)
                            }
                            isInitialBottomScrollInProgress = false
                            isAtChatBottom = chatScrollController.isAtBottom()
                        }
                        return
                    }

                    let explicitStillOwnsScroll = isExplicitScrollInProgress
                        && explicitScrollGeneration == generation
                    if !chatScrollController.scrollToBottom(animated: true) {
                        withAnimation(.easeOut(duration: 0.28)) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                    if explicitStillOwnsScroll {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            guard isExplicitScrollInProgress,
                                  explicitScrollGeneration == generation,
                                  scrollToBottomRequest == requestGeneration else { return }
                            _ = chatScrollController.scrollToBottom(animated: true)
                        }
                    }
                }
            }
            .onChange(of: scrollTargetMessageID) { _, messageID in
                guard let messageID else { return }
                let generation = messagePositioningGeneration
                let positionTarget = {
                    guard isMessagePositioningInProgress,
                          messagePositioningGeneration == generation else { return }
                    proxy.scrollTo(messageID, anchor: .top)
                }
                // LazyVStack layout and live message insertion can move the
                // target during the first few frames. Reassert the explicit
                // destination until layout has settled instead of allowing a
                // pending bottom-follow scroll to win the race.
                DispatchQueue.main.async(execute: positionTarget)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: positionTarget)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    positionTarget()
                    guard messagePositioningGeneration == generation else { return }
                    scrollTargetMessageID = nil
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
                    guard messagePositioningGeneration == generation else { return }
                    isMessagePositioningInProgress = false
                }
            }
        }
        .frame(maxHeight: .infinity)
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
                    Button {
                        Task { await viewModel.loadModelsIfNeeded(force: true) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }

                    Menu {
                        if viewModel.models.isEmpty {
                            Button {
                                Task { await viewModel.loadModelsIfNeeded(force: true) }
                            } label: {
                                Label("读取模型列表", systemImage: "arrow.clockwise")
                            }
                        } else {
                            Picker("选择模型", selection: Binding(
                                get: { viewModel.selectedModelID },
                                set: { viewModel.selectModel($0) }
                            )) {
                                ForEach(viewModel.models, id: \.identifier) { model in
                                    Text(model.title).tag(model.identifier)
                                }
                            }
                        }
                    } label: {
                        Label("模型", systemImage: "cpu")
                    }

                    Menu {
                        if viewModel.availableEfforts.isEmpty {
                            Text("默认")
                        } else {
                            Picker("选择用量", selection: Binding(
                                get: { viewModel.selectedEffortID },
                                set: { viewModel.selectEffort($0) }
                            )) {
                                ForEach(viewModel.availableEfforts) { effort in
                                    Text(effort.title).tag(effort.reasoningEffort)
                                }
                            }
                        }
                    } label: {
                        Label("用量", systemImage: "gauge.with.dots.needle.67percent")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(viewModel.compactModelTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(viewModel.selectedEffortTitle)
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Capsule(), interactive: true)
                .accessibilityLabel("切换模型和用量")

                Menu {
                    Picker("模式", selection: Binding(
                        get: { viewModel.codexMode },
                        set: { viewModel.selectCodexMode($0) }
                    )) {
                        ForEach(CodexExecutionMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                } label: {
                    Label(viewModel.codexMode.title, systemImage: viewModel.codexMode.systemImage)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Capsule(), interactive: true)
                .accessibilityLabel("切换执行模式")

                Spacer(minLength: 0)

                taskTimerBubble

                Button {
                    showingTokenUsage = true
                } label: {
                    Text(contextRemainingLabel)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Capsule(), interactive: true)
                .accessibilityLabel("查看本轮 Token 使用量")
            }
            .padding(.horizontal, 20)

            composerControls
        }
    }

    @ViewBuilder
    private var composerControls: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                composerControlStack
            }
        } else {
            composerControlStack
        }
    }

    private var composerControlStack: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button { showingFilePicker = true } label: {
                Image(systemName: "paperclip")
                    .font(.body.weight(.semibold))
                    .frame(width: 46, height: 46)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .liquidGlass(in: Circle(), interactive: true)
            .disabled((viewModel.selectedProjectCWD ?? viewModel.selectedThread?.cwd ?? viewModel.projects.first?.cwd) == nil)
            .accessibilityLabel("上传文件")

            HStack(alignment: .bottom, spacing: 4) {
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
                        .focused($composerFocused)
                }
                .padding(.leading, 4)

                if viewModel.active {
                    Button { Task { await viewModel.stop() } } label: {
                        Image(systemName: "stop.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy)
                    .accessibilityLabel("停止任务")
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
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("发送消息")
                }
            }
            .padding(.vertical, 4)
            .padding(.trailing, 6)
            .padding(.leading, 3)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 27, style: .continuous), interactive: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, bottomControlPadding)
    }

    private var bottomControlPadding: CGFloat {
        if keyboardHeight > 0 { return 18 }
        guard UIDevice.current.userInterfaceIdiom == .pad else { return -7 }
        guard isWindowedIPad else { return 0 }
        return max(0, 24 - bottomSafeArea)
    }

    private var isExpectedChatReady: Bool {
        let isNewChat = expectedThreadID?.hasPrefix("new-") == true
        return isNewChat || expectedThreadID == viewModel.selectedThreadID
    }

    private var currentChatContent: ChatScrollContent {
        guard isExpectedChatReady else { return .empty }
        return ChatScrollContent(
            messages: viewModel.renderedMessages,
            approvals: viewModel.visibleApprovals,
            active: viewModel.active
        )
    }

    private func updateChatContent(force: Bool = false) {
        guard isExpectedChatReady, !viewModel.isOpeningThread else { return }
        if isStaticConversationLocked && !force { return }
        let latest = currentChatContent
        if !hasLoadedChatContent {
            beginInitialBottomPositioning()
            chatContentSnapshot = latest
            hasLoadedChatContent = true
            return
        }

        if isPreparingInitialLayout {
            // Keep the hidden initial snapshot current while the first layout
            // settles. Do not enqueue another scroll for every streamed delta.
            chatContentSnapshot = latest
            return
        }

        if force || isFollowingChatBottom {
            chatContentSnapshot = latest
            if isFollowingChatBottom {
                let requestGeneration = scrollToBottomRequest + 1
                DispatchQueue.main.async {
                    guard isFollowingChatBottom,
                          !isPreparingInitialLayout,
                          !isUserScrollingChat else { return }
                    scrollToBottomRequest = requestGeneration
                }
            }
        } else {
            // Leaving follow mode must freeze only the viewport, not the
            // conversation data. Keep replacing rows that are still being
            // streamed and append newly arrived rows without requesting a
            // scroll, so messages and execution commands remain live while
            // the user reads older content.
            if shouldReplaceForCompletedProcess(with: latest) {
                // Completion changes the timeline's structure: fine-grained
                // live rows are replaced by one process-summary row plus the
                // final answer. An append-only merge would retain all of the
                // obsolete live rows. Apply the final snapshot atomically but
                // deliberately do not request any scroll positioning.
                chatContentSnapshot = latest
                return
            }
            mergeLiveChatContent(from: latest)
        }
    }

    private func beginInitialBottomPositioning() {
        initialBottomScrollGeneration += 1
        let generation = initialBottomScrollGeneration
        isInitialBottomScrollInProgress = true
        isPreparingInitialLayout = true
        DispatchQueue.main.async {
            guard initialBottomScrollGeneration == generation,
                  isFollowingChatBottom else { return }
            scrollToBottomRequest += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard initialBottomScrollGeneration == generation else { return }
            if isFollowingChatBottom && !isUserScrollingChat {
                // The final native correction runs while the content is still
                // hidden, so revealing it cannot expose an intermediate offset.
                _ = chatScrollController.scrollToBottom(animated: false)
                isAtChatBottom = chatScrollController.isAtBottom()
            }
            isInitialBottomScrollInProgress = false
            isPreparingInitialLayout = false
            if !viewModel.active {
                isStaticConversationLocked = true
            }
        }
    }

    private func resetChatLayoutForNewThread() {
        chatScrollController.cancelCurrentScroll()
        initialBottomScrollGeneration += 1
        explicitScrollGeneration += 1
        messagePositioningGeneration += 1
        processLayoutGeneration += 1
        scrollTargetMessageID = nil
        chatContentSnapshot = .empty
        hasLoadedChatContent = false
        isStaticConversationLocked = false
        isPreparingInitialLayout = true
        isInitialBottomScrollInProgress = false
        isMessagePositioningInProgress = false
        isProcessLayoutChangeInProgress = false
        processExpansionScrollOffset = nil
        isAtChatBottom = true
        isFollowingChatBottom = true
        isUserScrollingChat = false
    }

    private func shouldReplaceForCompletedProcess(with latest: ChatScrollContent) -> Bool {
        let currentIDs = Set(chatContentSnapshot.messages.map(\.id))
        let latestIDs = Set(latest.messages.map(\.id))
        let introducedProcessSummary = latest.messages.contains {
            $0.role == .processSummary && !currentIDs.contains($0.id)
        }
        let removesLiveRows = chatContentSnapshot.messages.contains {
            !latestIDs.contains($0.id)
        }
        return introducedProcessSummary && removesLiveRows
    }

    private func mergeLiveChatContent(from latest: ChatScrollContent) {
        var latestByID: [String: ChatMessage] = [:]
        for message in latest.messages {
            latestByID[message.id] = message
        }

        let existingIDs = Set(chatContentSnapshot.messages.map(\.id))
        var messages = chatContentSnapshot.messages.map { current in
            latestByID[current.id] ?? current
        }
        messages.append(contentsOf: latest.messages.filter { !existingIDs.contains($0.id) })

        chatContentSnapshot = ChatScrollContent(
            messages: messages,
            approvals: latest.approvals,
            active: latest.active
        )
    }

    private func showLatestChatContent() {
        beginExplicitScroll()
        if isFollowingChatBottom {
            updateChatContent(force: true)
            return
        }
        isFollowingChatBottom = true
        isAtChatBottom = true
    }

    private func beginExplicitScroll() {
        explicitScrollGeneration += 1
        let generation = explicitScrollGeneration
        isExplicitScrollInProgress = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard explicitScrollGeneration == generation else { return }
            isExplicitScrollInProgress = false
        }
    }

    private func beginProcessLayoutChange(expanding: Bool, restorePosition: Bool) {
        processLayoutGeneration += 1
        let generation = processLayoutGeneration
        chatScrollController.cancelCurrentScroll()
        isFollowingChatBottom = false
        isProcessLayoutChangeInProgress = true

        if expanding {
            processExpansionScrollOffset = chatScrollController.currentContentOffset()
        } else if restorePosition, let offset = processExpansionScrollOffset {
            processExpansionScrollOffset = nil
            let restoreSavedPosition = {
                guard processLayoutGeneration == generation else { return }
                _ = chatScrollController.restoreContentOffset(offset)
            }
            DispatchQueue.main.async(execute: restoreSavedPosition)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: restoreSavedPosition)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: restoreSavedPosition)
        } else {
            processExpansionScrollOffset = nil
        }

        // Long histories need several LazyVStack layout passes. During that
        // window, do not interpret content-height changes as a reason to
        // resume bottom following.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard processLayoutGeneration == generation else { return }
            isProcessLayoutChangeInProgress = false
            isAtChatBottom = chatScrollController.isAtBottom()
        }
    }

    private func showMessage(_ messageID: String, highlightQuery: String? = nil) {
        messagePositioningGeneration += 1
        isMessagePositioningInProgress = true
        beginExplicitScroll()
        chatScrollController.cancelCurrentScroll()
        isFollowingChatBottom = false
        isAtChatBottom = false
        messageTextHighlight = highlightQuery.flatMap { query in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : MessageTextHighlight(messageID: messageID, query: trimmed)
        }
        chatContentSnapshot = currentChatContent
        hasLoadedChatContent = true
        DispatchQueue.main.async {
            scrollTargetMessageID = messageID
        }
    }

    private func fulfillPendingMessageJumpIfPossible() {
        guard !viewModel.isOpeningThread,
              let request = viewModel.pendingMessageJump,
              request.threadID == viewModel.selectedThreadID,
              viewModel.renderedMessages.contains(where: { $0.id == request.messageID }) else { return }
        viewModel.clearMessageJumpRequest()
        showMessage(request.messageID, highlightQuery: request.query)
    }

    private func threadStatus(_ thread: CloudexThread) -> String {
        if thread.status?.type == "active", thread.status?.activeFlags?.contains("waitingOnApproval") == true { return "等待审批" }
        if thread.status?.type == "active" { return "运行中" }
        if thread.status?.type == "idle" { return "已完成" }
        if thread.status?.type == "notLoaded" { return "未加载" }
        return thread.status?.type ?? "未知状态"
    }

    private var contextRemainingLabel: String {
        guard let usage = viewModel.selectedThread?.usage,
              let window = usage.modelContextWindow,
              let used = usage.last?.totalTokens else { return "上下文" }
        let remaining = max(0, window - used)
        let percent = Int((Double(remaining) / Double(max(1, window)) * 100).rounded())
        return "余 \(percent)%"
    }

    @ViewBuilder
    private var taskTimerBubble: some View {
        if !taskTimerHidden, taskTimerTurnID != nil {
            if let completedAt = taskTimerCompletedAt {
                taskTimerButton(duration: taskDurationText(at: completedAt), completed: true)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    taskTimerButton(duration: taskDurationText(at: context.date.timeIntervalSince1970), completed: false)
                }
            }
        }
    }

    private func taskTimerButton(duration: String, completed: Bool) -> some View {
        Button {
            let wasCompleted = taskTimerCompletedAt != nil
            if wasCompleted {
                taskTimerHidden = true
                taskTimerTurnID = nil
            }
            // Use the same explicit bottom-scroll path as the existing
            // "latest message" button, including deceleration cancellation.
            showLatestChatContent()
        } label: {
            HStack(spacing: 5) {
                if completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(duration)
                    .lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Capsule(), interactive: true)
        .accessibilityLabel(completed ? "任务已完成，点击查看最新对话" : "任务已用时 \(duration)")
    }

    private func syncTaskTimerState() {
        guard isExpectedChatReady else { return }
        let runningTurn = viewModel.active
            ? viewModel.detail?.turns.last(where: { turn in
                guard let status = turn.status?.lowercased() else { return false }
                return ["inprogress", "in_progress", "active", "running"].contains(status)
            })
            : nil
        if let runningTurn {
            if taskTimerTurnID == nil || taskTimerCompletedAt != nil || taskTimerTurnID != runningTurn.id {
                taskTimerTurnID = runningTurn.id
                taskTimerStartedAt = runningTurn.startedAt ?? Date().timeIntervalSince1970
                taskTimerCompletedAt = nil
                taskTimerHidden = false
            } else if taskTimerStartedAt == nil {
                taskTimerStartedAt = runningTurn.startedAt ?? Date().timeIntervalSince1970
            }
            return
        }

        // A newly submitted task can be running before the first server
        // snapshot creates its turn. Start a provisional clock immediately.
        if viewModel.liveRunning && (taskTimerTurnID == nil || taskTimerCompletedAt != nil) {
            taskTimerTurnID = "pending-\(viewModel.selectedThreadID ?? "new")"
            taskTimerStartedAt = Date().timeIntervalSince1970
            taskTimerCompletedAt = nil
            taskTimerHidden = false
            return
        }

        guard let taskTimerTurnID,
              !taskTimerTurnID.hasPrefix("pending-") else {
            if !viewModel.liveRunning { taskTimerCompletedAt = taskTimerCompletedAt ?? Date().timeIntervalSince1970 }
            return
        }
        guard let turn = viewModel.detail?.turns.first(where: { $0.id == taskTimerTurnID }) else { return }
        guard let status = turn.status?.lowercased(),
              !["inprogress", "in_progress", "active", "running"].contains(status) else { return }
        if taskTimerCompletedAt == nil {
            let fallback = taskTimerStartedAt.map { $0 + (turn.durationMs ?? 0) / 1000 }
            taskTimerCompletedAt = turn.completedAt ?? fallback ?? Date().timeIntervalSince1970
            taskTimerHidden = false
        }
    }

    private func taskDurationText(at timestamp: Double) -> String {
        guard let started = taskTimerStartedAt else { return "0秒" }
        return DateFormatting.duration(fromSeconds: max(0, timestamp - started))
    }
}

private struct ChatScrollContent: Equatable {
    let messages: [ChatMessage]
    let approvals: [ApprovalRequest]
    let active: Bool

    static let empty = ChatScrollContent(messages: [], approvals: [], active: false)
}

private final class ChatScrollController: ObservableObject {
    private weak var scrollView: UIScrollView?

    func attach(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
    }

    func detach() {
        scrollView = nil
    }

    func isAtBottom(tolerance: CGFloat = 24) -> Bool {
        guard let scrollView, scrollView.window != nil else { return false }
        scrollView.layoutIfNeeded()
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        return maximumY - scrollView.contentOffset.y <= tolerance
    }

    func currentContentOffset() -> CGPoint? {
        guard let scrollView, scrollView.window != nil else { return nil }
        return scrollView.contentOffset
    }

    @discardableResult
    func restoreContentOffset(_ offset: CGPoint) -> Bool {
        guard let scrollView, scrollView.window != nil else { return false }
        scrollView.layoutIfNeeded()
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let targetY = min(max(offset.y, minimumY), maximumY)
        scrollView.setContentOffset(CGPoint(x: offset.x, y: targetY), animated: false)
        return true
    }

    @discardableResult
    func scrollToBottom(animated: Bool) -> Bool {
        guard let scrollView, scrollView.window != nil else { return false }

        // Stop both an active drag and any remaining deceleration before
        // starting the explicit navigation animation. Toggling the pan
        // recognizer forces UIKit to cancel the gesture immediately.
        let currentOffset = scrollView.contentOffset
        scrollView.layer.removeAllAnimations()
        scrollView.setContentOffset(currentOffset, animated: false)
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.panGestureRecognizer.isEnabled = true
        scrollView.layoutIfNeeded()

        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: maximumY),
            animated: animated
        )
        return true
    }

    func cancelCurrentScroll() {
        guard let scrollView, scrollView.window != nil else { return }
        let currentOffset = scrollView.contentOffset
        scrollView.layer.removeAllAnimations()
        scrollView.setContentOffset(currentOffset, animated: false)
        // Cancel both a finger-owned gesture and UIKit deceleration. The
        // search positioning transaction takes ownership immediately after.
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.panGestureRecognizer.isEnabled = true
    }
}

private struct ChatScrollViewResolver: UIViewRepresentable {
    let controller: ChatScrollController

    func makeUIView(context: Context) -> ResolverView {
        ResolverView(controller: controller)
    }

    func updateUIView(_ uiView: ResolverView, context: Context) {
        uiView.controller = controller
        uiView.resolveScrollView()
    }

    static func dismantleUIView(_ uiView: ResolverView, coordinator: ()) {
        uiView.controller.detach()
    }

    final class ResolverView: UIView {
        var controller: ChatScrollController

        init(controller: ChatScrollController) {
            self.controller = controller
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            resolveScrollView()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveScrollView()
        }

        func resolveScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let scrollView = view as? UIScrollView {
                        self.controller.attach(scrollView)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func trackChatScroll(
        isAtBottom: Binding<Bool>,
        isFollowingBottom: Binding<Bool>,
        isExplicitScrollInProgress: Binding<Bool>,
        isUserScrolling: Binding<Bool>,
        isLayoutChangeInProgress: Binding<Bool>,
        isFollowRestorationDisabled: @escaping () -> Bool,
        nativeIsAtBottom: @escaping () -> Bool
    ) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                let distanceToBottom = geometry.contentSize.height - visibleBottom
                return geometry.contentSize.height <= geometry.containerSize.height || distanceToBottom <= 24
            } action: { _, atBottom in
                isAtBottom.wrappedValue = atBottom
                // Scroll geometry can deliver its final bottom value just
                // after the phase changes to idle. Restore follow mode here
                // as well so that event ordering cannot leave a stale button.
                if atBottom
                    && !isUserScrolling.wrappedValue
                    && !isLayoutChangeInProgress.wrappedValue
                    && !isExplicitScrollInProgress.wrappedValue
                    && !isFollowRestorationDisabled() {
                    isFollowingBottom.wrappedValue = true
                }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    guard !isExplicitScrollInProgress.wrappedValue else { break }
                    isUserScrolling.wrappedValue = true
                    // Any user-initiated scroll leaves follow mode. Do not
                    // automatically restore it when scrolling becomes idle:
                    // an upward drag that starts at the bottom can still be
                    // reported as "at bottom" for a moment, which previously
                    // caused the next content update to jump back down.
                    // Follow mode is restored only after the gesture really
                    // settles at the bottom (see the idle case below), or by
                    // showLatestChatContent().
                    isFollowingBottom.wrappedValue = false
                case .idle:
                    isUserScrolling.wrappedValue = false
                    // SwiftUI's geometry can lag behind the final rubber-band
                    // position. Reconcile against the underlying UIScrollView
                    // now and once more on the next run loop after layout.
                    let reconcileBottom = {
                        let atBottom = nativeIsAtBottom()
                        isAtBottom.wrappedValue = atBottom
                        if atBottom
                            && !isLayoutChangeInProgress.wrappedValue
                            && !isExplicitScrollInProgress.wrappedValue
                            && !isFollowRestorationDisabled() {
                            isFollowingBottom.wrappedValue = true
                        }
                    }
                    reconcileBottom()
                    DispatchQueue.main.async(execute: reconcileBottom)
                default:
                    break
                }
            }
        } else {
            self.simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        guard !isExplicitScrollInProgress.wrappedValue else { return }
                        isUserScrolling.wrappedValue = true
                        isAtBottom.wrappedValue = false
                        isFollowingBottom.wrappedValue = false
                    }
                    .onEnded { _ in
                        isUserScrolling.wrappedValue = false
                        if isAtBottom.wrappedValue
                            && !isExplicitScrollInProgress.wrappedValue
                            && !isFollowRestorationDisabled() {
                            isFollowingBottom.wrappedValue = true
                        }
                    }
            )
        }
    }
}

private struct TokenUsageSheet: View {
    let usage: CloudexUsage?

    var body: some View {
        NavigationStack {
            List {
                if let last = usage?.last {
                    Section("本轮对话") {
                        usageRow("输入 Token", value: last.inputTokens)
                        usageRow("缓存输入", value: last.cachedInputTokens)
                        usageRow("输出 Token", value: last.outputTokens)
                        usageRow("推理输出", value: last.reasoningOutputTokens)
                        usageRow("合计", value: last.totalTokens)
                    }
                }
                if let total = usage?.total {
                    Section("整段对话累计") {
                        usageRow("输入 Token", value: total.inputTokens)
                        usageRow("输出 Token", value: total.outputTokens)
                        usageRow("合计", value: total.totalTokens)
                    }
                }
                if let window = usage?.modelContextWindow {
                    Section("上下文窗口") {
                        usageRow("窗口大小", value: window)
                        let used = usage?.last?.totalTokens ?? 0
                        usageRow("本轮剩余", value: max(0, window - used))
                    }
                }
                if usage?.last == nil && usage?.total == nil {
                    ContentUnavailableView("暂无 Token 数据", systemImage: "chart.bar.xaxis")
                }
            }
            .navigationTitle("Token 使用量")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func usageRow(_ title: String, value: Int?) -> some View {
        if let value {
            LabeledContent(title, value: "\(value.formatted())")
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let highlightQuery: String?
    @Binding var collapseRequest: Int
    let onQuickFill: (String) -> Void
    let onFork: () async -> Bool
    let onProcessInteraction: (Bool) -> Void
    let onFloatingProcessCollapse: () -> Void
    let onFloatingStateChange: (Bool) -> Void
    @State private var isPerformingAction = false

    @ViewBuilder
    var body: some View {
        if message.role == .execution {
            ExecutionStepRow(message: message)
        } else if message.role == .processSummary {
            ProcessSummaryBubble(
                message: message,
                collapseRequest: $collapseRequest,
                onInteraction: onProcessInteraction,
                onFloatingCollapse: onFloatingProcessCollapse,
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
                    MarkdownText(text: message.text, highlightQuery: highlightQuery)
                        .font(.body)
                        .foregroundStyle(message.role == .error ? Color.red : Color.primary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)

                    messageFooter
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

    @ViewBuilder
    private var messageFooter: some View {
        HStack(spacing: 6) {
            if !messageTime.isEmpty {
                Text(messageTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            if message.role == .user || message.role == .assistant {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("复制消息")

                if message.role == .user {
                    Button {
                        onQuickFill(message.text)
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isPerformingAction)
                    .accessibilityLabel("填充到输入框")
                } else {
                    Button {
                        Task {
                            isPerformingAction = true
                            _ = await onFork()
                            isPerformingAction = false
                        }
                    } label: {
                        if isPerformingAction {
                            ProgressView().controlSize(.mini)
                                .frame(width: 28, height: 24)
                        } else {
                            Image(systemName: "arrow.triangle.branch")
                                .frame(width: 28, height: 24)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(message.sourceTurnID == nil || isPerformingAction)
                    .accessibilityLabel("从这里分叉对话")
                }
            }
        }
        .font(.caption)
    }
}

private struct ProcessSummaryBubble: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let message: ChatMessage
    @Binding var collapseRequest: Int
    let onInteraction: (Bool) -> Void
    let onFloatingCollapse: () -> Void
    let onFloatingStateChange: (Bool) -> Void
    @State private var expanded = false
    @State private var expansionGeneration = 0
    @State private var expandedContentHeight: CGFloat = 0
    @State private var collapseButtonVisible = true
    @State private var bubbleVisible = true
    @State private var loadingDetails = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if expanded {
                        onInteraction(false)
                        expanded = false
                        expansionGeneration += 1
                    } else if message.processDetailsLoaded {
                        onInteraction(true)
                        expanded = true
                    } else if let turnID = message.sourceTurnID, !loadingDetails {
                        loadingDetails = true
                        Task {
                            let loaded = await viewModel.loadTurnDetails(turnID: turnID)
                            loadingDetails = false
                            if loaded {
                                onInteraction(true)
                                expanded = true
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if loadingDetails {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: expanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                                .foregroundStyle(.secondary)
                        }
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
            // Keep the expanded process content constrained to the same
            // bubble width as its header. Without an explicit finite width,
            // long shell commands and diff rows can make the VStack choose
            // an intrinsic width larger than the rounded rectangle.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            onFloatingCollapse()
            expanded = false
            expansionGeneration += 1
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
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: iconName)
                Text(message.text)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemBackground), in: Capsule())
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
    var highlightQuery: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.blocks(from: text)) { block in
                switch block.content {
                case let .paragraph(value):
                    Text(Self.parseInline(value, highlightQuery: highlightQuery))
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .code(value, language):
                    MarkdownCodeBlock(source: value, language: language)
                case let .table(rows):
                    MarkdownTableView(rows: rows, highlightQuery: highlightQuery)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func parseInline(_ text: String, highlightQuery: String?) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        return highlightedAttributedString(parsed, query: highlightQuery)
    }

    private static func blocks(from source: String) -> [MarkdownBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        var blockID = 0

        func appendBlock(_ content: MarkdownBlock.Content) {
            blocks.append(MarkdownBlock(id: blockID, content: content))
            blockID += 1
        }

        func flushParagraph() {
            let value = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                appendBlock(.paragraph(value))
            }
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let language = Self.fenceLanguage(in: trimmed) {
                flushParagraph()
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let codeLine = lines[index]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(codeLine)
                    index += 1
                }
                appendBlock(.code(codeLines.joined(separator: "\n"), language))
                continue
            }

            if index + 1 < lines.count,
               trimmed.contains("|"),
               Self.isTableSeparator(lines[index + 1]) {
                flushParagraph()
                var rows = [Self.tableRow(from: line)]
                index += 2
                while index < lines.count {
                    let row = lines[index]
                    let rowTrimmed = row.trimmingCharacters(in: .whitespaces)
                    guard !rowTrimmed.isEmpty, rowTrimmed.contains("|") else { break }
                    rows.append(Self.tableRow(from: row))
                    index += 1
                }
                if rows.first?.count ?? 0 > 0 {
                    appendBlock(.table(rows))
                }
                continue
            }

            if Self.isIndentedCode(line) {
                flushParagraph()
                var codeLines: [String] = []
                while index < lines.count {
                    let codeLine = lines[index]
                    if codeLine.isEmpty {
                        codeLines.append("")
                        index += 1
                    } else if Self.isIndentedCode(codeLine) {
                        let indentation = codeLine.hasPrefix("\t") ? 1 : min(4, codeLine.count)
                        codeLines.append(String(codeLine.dropFirst(indentation)))
                        index += 1
                    } else {
                        break
                    }
                }
                while codeLines.last?.isEmpty == true { codeLines.removeLast() }
                appendBlock(.code(codeLines.joined(separator: "\n"), ""))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func fenceLanguage(in line: String) -> String? {
        guard line.hasPrefix("```") else { return nil }
        return String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isIndentedCode(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableRow(from: line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            let withoutEdges = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return withoutEdges.count >= 3 && withoutEdges.allSatisfy { $0 == "-" }
        }
    }

    private static func tableRow(from line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if character == "|" && !escaped {
                cells.append(current.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|"))
                current = ""
            } else {
                current.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(current.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|"))
        return cells
    }
}

private struct MarkdownBlock: Identifiable {
    enum Content {
        case paragraph(String)
        case code(String, String)
        case table([[String]])
    }

    let id: Int
    let content: Content
}

private struct MarkdownCodeBlock: View {
    let source: String
    let language: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language.lowercased())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(source.isEmpty ? " " : source)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MarkdownTableView: View {
    let rows: [[String]]
    let highlightQuery: String?

    var body: some View {
        let columnCount = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            Text(inlineText(row.indices.contains(column) ? row[column] : ""))
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(minWidth: 110, maxWidth: 220, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(rowIndex == 0 ? Color(.secondarySystemBackground) : Color(.tertiarySystemBackground))
                                .overlay {
                                    Rectangle().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                                }
                        }
                    }
                }
            }
            .padding(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func inlineText(_ value: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        let parsed = (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
        return highlightedAttributedString(parsed, query: highlightQuery)
    }
}

private struct ExecutionStepRow: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            if message.executionKind == "edit" {
                editRow
            } else {
                HStack(alignment: .top, spacing: 10) {
                    statusIcon
                        .frame(width: 18, height: 20)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.text)
                            .font(.system(.subheadline, design: .monospaced).weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(expanded ? nil : 3)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .buttonStyle(.plain)
    }

    private var editRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statusIcon
                    .frame(width: 18, height: 20)
                Text(editTitle)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                if hasEditDiff {
                    Text("+\(totalEditAdditions) -\(totalEditDeletions)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if hasEditDiff && expanded {
                CodexStyleDiffRenderer(payloads: editPayloads, expanded: expanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !hasEditDiff {
                Text(message.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
            }

            if let detailText {
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .padding(.leading, 40)
                    .padding(.trailing, 12)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if message.executionStatus == "inProgress" {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: message.executionStatus == "failed" || message.executionStatus == "declined"
                  ? "xmark.circle.fill"
                  : "checkmark.circle.fill")
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        if message.executionStatus == "failed" { return .red }
        if message.executionStatus == "declined" { return .orange }
        return message.executionStatus == "inProgress" ? .secondary : .green
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

    private var editTitle: String {
        let names = editPayloads.map { editDisplayName($0.name) }
        guard !names.isEmpty else { return message.text }
        if names.count <= 2 { return "Edited \(names.joined(separator: ", "))" }
        return "Edited \(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
    }

    private var editPayloads: [EditDiffPayload] {
        message.editDiff ?? []
    }

    private var hasEditDiff: Bool {
        !editPayloads.isEmpty
    }

    private var totalEditAdditions: Int {
        editPayloads.reduce(0) { total, payload in
            total + (payload.additions ?? payload.lines?.filter { $0.kind == "addition" }.count ?? 0)
        }
    }

    private var totalEditDeletions: Int {
        editPayloads.reduce(0) { total, payload in
            total + (payload.deletions ?? payload.lines?.filter { $0.kind == "deletion" }.count ?? 0)
        }
    }

    private func editDisplayName(_ value: String) -> String {
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

struct CodexDiffLineRow: View {
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

private struct MessageJumpItem: Identifiable, Equatable {
    let id: String
    let turnID: String
    let title: String
    let body: String
    let dateTime: String
    let processingDuration: String

    static func paired(from items: [MessageIndexItem], turns: [CloudexTurn]) -> [MessageJumpItem] {
        var result: [MessageJumpItem] = []
        var pendingUser: MessageIndexItem?
        let turnsByID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })

        func makeItem(user: MessageIndexItem, assistant: MessageIndexItem?) -> MessageJumpItem {
            let turn = turnsByID[user.turnId]
            let duration = turn?.durationMs.flatMap { DateFormatting.duration(fromMilliseconds: $0).nilIfEmpty }
                ?? {
                    guard let startedAt = user.createdAt,
                          let completedAt = assistant?.createdAt,
                          completedAt >= startedAt else { return nil }
                    return DateFormatting.duration(fromSeconds: completedAt - startedAt).nilIfEmpty
                }()
                ?? ""
            return MessageJumpItem(
                id: user.id,
                turnID: user.turnId,
                title: user.text,
                body: assistant?.text ?? "",
                dateTime: DateFormatting.string(from: user.createdAt),
                processingDuration: duration
            )
        }

        for item in items {
            if item.role == "user" {
                if let pendingUser {
                    result.append(makeItem(user: pendingUser, assistant: nil))
                }
                pendingUser = item
            } else if let user = pendingUser {
                result.append(makeItem(user: user, assistant: item))
                pendingUser = nil
            }
        }

        if let pendingUser {
            result.append(makeItem(user: pendingUser, assistant: nil))
        }
        return result
    }
}

struct IPadConversationDirectoryView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let onSelect: (_ messageID: String, _ turnID: String) -> Void
    let onOpenPage: (() -> Void)?
    let onClosePage: (() -> Void)?
    var showsNavigationChrome = true
    @State private var messages: [MessageJumpItem] = []

    @ViewBuilder
    var body: some View {
        Group {
            if showsNavigationChrome {
                NavigationStack {
                    directoryContent
                        .toolbar {
                            if let onClosePage {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button(action: onClosePage) {
                                        Image(systemName: "chevron.left")
                                    }
                                    .accessibilityLabel("返回三栏视图")
                                }
                            }
                        }
                }
            } else {
                directoryContent
            }
        }
        .onChange(of: viewModel.messageIndex, initial: true) { _, items in
            guard !viewModel.active || messages.isEmpty else { return }
            let snapshot = MessageJumpItem.paired(from: items, turns: viewModel.detail?.turns ?? [])
            if messages != snapshot { messages = snapshot }
        }
        .onChange(of: viewModel.active) { _, active in
            guard !active else { return }
            let snapshot = MessageJumpItem.paired(
                from: viewModel.messageIndex,
                turns: viewModel.detail?.turns ?? []
            )
            if messages != snapshot { messages = snapshot }
        }
    }

    private var directoryContent: some View {
        MessageJumpListView(
            messages: messages,
            onSelect: { onSelect($0.id, $0.turnID) },
            onExpand: onOpenPage,
            dismissOnSelection: false,
            showsNavigationChrome: showsNavigationChrome
        )
        .environmentObject(viewModel)
    }
}

private struct MessageJumpListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    let messages: [MessageJumpItem]
    let onSelect: (MessageJumpItem) -> Void
    var onExpand: (() -> Void)? = nil
    var dismissOnSelection = true
    var showsNavigationChrome = true
    @State private var pendingSelection: MessageJumpItem?
    @State private var selectedSubpage = ConversationSubpage.conversation

    var body: some View {
        VStack(spacing: 0) {
            Picker("页面", selection: $selectedSubpage) {
                Label("对话", systemImage: "bubble.left.and.bubble.right")
                    .tag(ConversationSubpage.conversation)
                Label("文件", systemImage: "folder")
                    .tag(ConversationSubpage.files)
                Label("审阅", systemImage: "doc.text.magnifyingglass")
                    .tag(ConversationSubpage.review)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            ZStack {
                conversationDirectory
                    .opacity(selectedSubpage == .conversation ? 1 : 0)
                    .allowsHitTesting(selectedSubpage == .conversation)
                    .accessibilityHidden(selectedSubpage != .conversation)

                WorkspaceFilesView(rootPath: workspaceRoot)
                    .environmentObject(viewModel)
                    .id(workspaceRoot)
                    .opacity(selectedSubpage == .files ? 1 : 0)
                    .allowsHitTesting(selectedSubpage == .files)
                    .accessibilityHidden(selectedSubpage != .files)

                ProjectReviewView(rootPath: workspaceRoot)
                    .environmentObject(viewModel)
                    .id(workspaceRoot)
                    .opacity(selectedSubpage == .review ? 1 : 0)
                    .allowsHitTesting(selectedSubpage == .review)
                    .accessibilityHidden(selectedSubpage != .review)
            }
        }
        .modifier(DirectoryNavigationChromeModifier(
            isVisible: showsNavigationChrome,
            onExpand: onExpand
        ))
        .onDisappear {
            guard let selection = pendingSelection else { return }
            pendingSelection = nil
            // Wait until the pop transition has handed scrolling back to the
            // parent conversation before starting its explicit positioning.
            DispatchQueue.main.async {
                onSelect(selection)
            }
        }
    }

    @ViewBuilder
    private var conversationDirectory: some View {
        if messages.isEmpty {
            ContentUnavailableView("暂无对话", systemImage: "text.bubble")
        } else {
            List(messages) { message in
                Button {
                    if dismissOnSelection {
                        pendingSelection = message
                        dismiss()
                    } else {
                        onSelect(message)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(normalizedText(message.title))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)

                        Text(message.body.isEmpty ? "暂无 Codex 回复" : normalizedText(message.body))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 10) {
                            Text(message.dateTime)
                            Spacer(minLength: 8)
                            Text(message.processingDuration.isEmpty
                                 ? "处理中"
                                 : "处理 \(message.processingDuration)")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    }
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("跳转到：\(normalizedText(message.title))")
            }
        }
    }

    private var workspaceRoot: String {
        viewModel.selectedProjectCWD
            ?? viewModel.selectedThread?.cwd
            ?? ""
    }

    private func normalizedText(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

private struct DirectoryNavigationChromeModifier: ViewModifier {
    let isVisible: Bool
    let onExpand: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isVisible {
            content
                .navigationTitle("侧边面板")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let onExpand {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: onExpand) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .accessibilityLabel("打开侧边面板页面")
                        }
                    }
                }
                .toolbar(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func nativeTopScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

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
