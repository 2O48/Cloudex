import SwiftUI
import Combine
import UIKit

struct CloudexRootView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("cloudex.lastOpenedThreadID") private var lastOpenedThreadID = ""
    @State private var navigationPath: [String] = []
    @State private var searchQuery = ""
    @State private var showingSettings = false
    @State private var showingQRCodeScanner = false
    @State private var showingScannerError = false
    @State private var scannerErrorMessage = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var keyboardHeight: CGFloat = 0
    @State private var searchMatches: [ConversationSearchMatch] = []
    @State private var searchRequest: Task<Void, Never>?
    @State private var isSearchingMessages = false
    @State private var collapsedProjectIDs: Set<String> = []
    @State private var iPadColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var iPadPreferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var showingIPadDirectory = false
    @State private var iPadSelectedProjectID: String?
    @State private var iPadSelectedThreadRoute: String?
    @State private var restoredIPadSelection = false

    var body: some View {
        rootNavigation
        .task {
            await viewModel.start()
            await viewModel.loadModelsIfNeeded()
            await restoreIPadSelectionIfNeeded()
        }
        .onChange(of: navigationPath) { _, _ in
            // Do not leave the keyboard attached while transitioning to a chat.
            searchFieldFocused = false
        }
        .onChange(of: viewModel.threadNavigationRequest) { _, request in
            guard let request else { return }
            lastOpenedThreadID = request.threadID
            if usesIPadLayout {
                iPadSelectedThreadRoute = request.threadID
                selectProjectContainingThread(request.threadID)
                iPadPreferredCompactColumn = .detail
            } else {
                navigationPath.append(request.threadID)
            }
            viewModel.clearThreadNavigationRequest()
        }
        .onChange(of: viewModel.projects) { _, _ in
            normalizeIPadProjectSelection()
        }
        .onChange(of: searchQuery) { _, query in
            scheduleMessageSearch(query)
        }
        .onDisappear {
            searchRequest?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
            keyboardHeight = max(0, UIScreen.main.bounds.maxY - value.cgRectValue.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudexOpenNotificationSettings)) { _ in
            showingSettings = true
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(isPresented: $showingSettings)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingQRCodeScanner) {
            NavigationStack {
                QRCodeScannerView { code in
                    connect(using: code)
                } onFailure: { message in
                    showingQRCodeScanner = false
                    scannerErrorMessage = message
                    showingScannerError = true
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("扫描连接二维码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingQRCodeScanner = false }
                    }
                }
            }
        }
        .alert("无法扫描二维码", isPresented: $showingScannerError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(scannerErrorMessage)
        }
    }

    private var usesIPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    @ViewBuilder
    private var rootNavigation: some View {
        if usesIPadLayout {
            iPadNavigation
        } else {
            phoneNavigation
        }
    }

    private var phoneNavigation: some View {
        NavigationStack(path: $navigationPath) {
            List {
                if !pinnedConversations.isEmpty {
                    Section("置顶") {
                        ForEach(pinnedConversations) { pinned in
                            conversationButton(
                                pinned.thread,
                                projectCWD: pinned.projectCWD
                            )
                        }
                    }
                }

                ForEach(filteredProjects) { project in
                    Section {
                        if !isProjectCollapsed(project) {
                            projectNewConversationButton(project)

                            ForEach(project.threads) { thread in
                                VStack(alignment: .leading, spacing: 0) {
                                    conversationButton(thread, projectCWD: project.isNoProjectLike ? nil : project.cwd)

                                    ForEach(matchesByThreadID[thread.id] ?? []) { match in
                                        searchMatchButton(
                                            match,
                                            thread: thread,
                                            projectCWD: project.isNoProjectLike ? nil : project.cwd
                                        )
                                    }
                                }
                            }
                        }
                    } header: {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                toggleProject(project)
                            }
                        } label: {
                            HStack {
                                Text(project.displayName)
                                Spacer(minLength: 8)
                                Image(systemName: isProjectCollapsed(project) ? "chevron.right" : "chevron.down")
                                    .font(.caption.weight(.semibold))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(cloudexLocalized(isProjectCollapsed(project) ? "展开" : "折叠"))\(project.displayName)")
                    }
                }

                if filteredProjects.isEmpty, !isSearchingMessages {
                    ContentUnavailableView.search(text: searchQuery)
                        .listRowBackground(Color.clear)
                }
            }
            .refreshable { await viewModel.refresh() }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Cloudex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                rootToolbar
                homeTitleToolbar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                conversationSearchBar
            }
            .navigationDestination(for: String.self) { threadID in
                ContentView(expectedThreadID: threadID)
            }
        }
    }

    private var iPadNavigation: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                NavigationSplitView(
                    columnVisibility: $iPadColumnVisibility,
                    preferredCompactColumn: $iPadPreferredCompactColumn
                ) {
                    iPadSidebarColumn(
                        windowed: isWindowedIPad(for: geometry.size),
                        bottomSafeArea: geometry.safeAreaInsets.bottom
                    )
                        .navigationSplitViewColumnWidth(
                            min: 290,
                            ideal: iPadSidebarWidth(for: geometry.size.width),
                            max: 360
                        )
                } detail: {
                    Group {
                        if let route = iPadSelectedThreadRoute {
                            NavigationStack {
                                ContentView(
                                    expectedThreadID: route,
                                    onToggleDirectory: { showingIPadDirectory = true },
                                    showsDirectoryButton: false
                                )
                                .id(route)
                            }
                            .navigationTitle(viewModel.navigationTitle)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button { showingIPadDirectory = true } label: {
                                        Image(systemName: "list.bullet")
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("打开侧边面板")
                                }
                            }
                            .toolbar(.visible, for: .navigationBar)
                        } else {
                            ContentUnavailableView(
                                cloudexLocalized("选择一个对话"),
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text(cloudexLocalized("从左侧栏打开对话或创建新对话。"))
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationSplitViewStyle(.balanced)
                .environment(\.cloudexIsWindowedIPad, isWindowedIPad(for: geometry.size))
                .environment(\.cloudexBottomSafeArea, geometry.safeAreaInsets.bottom)

            }
            .sheet(isPresented: $showingIPadDirectory) {
                NavigationStack {
                    IPadConversationDirectoryView(
                        onSelect: { messageID, turnID in
                            requestIPadMessageJump(messageID: messageID, turnID: turnID)
                            showingIPadDirectory = false
                        },
                        onOpenPage: nil,
                        onClosePage: nil,
                        showsNavigationChrome: false
                    )
                    .navigationTitle("侧边面板")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showingIPadDirectory = false
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
        }
    }

    private func iPadSidebarColumn(windowed: Bool, bottomSafeArea: CGFloat) -> some View {
        List {
            if !pinnedConversations.isEmpty {
                Section("置顶") {
                    ForEach(pinnedConversations) { pinned in
                        iPadConversationButton(pinned.thread, project: pinned.project)
                            .listRowBackground(iPadSelectionRowBackground(for: pinned.thread.id))
                    }
                }
            }

            ForEach(iPadSidebarProjects) { project in
                Section {
                    if !isProjectCollapsed(project) {
                        Button {
                            startNewIPadConversation(in: project)
                        } label: {
                            Label("新对话", systemImage: "square.and.pencil")
                                .fontWeight(.semibold)
                        }

                        ForEach(project.threads) { thread in
                            VStack(alignment: .leading, spacing: 0) {
                                iPadConversationButton(thread, project: project)

                                ForEach(matchesByThreadID[thread.id] ?? []) { match in
                                    iPadSearchMatchButton(match, thread: thread, project: project)
                                }
                            }
                            .listRowBackground(iPadSelectionRowBackground(for: thread.id))
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            toggleProject(project)
                        }
                    } label: {
                        HStack {
                            Text(project.displayName)
                            Spacer(minLength: 8)
                            Image(systemName: isProjectCollapsed(project) ? "chevron.right" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if iPadSidebarProjects.isEmpty, !isSearchingMessages {
                ContentUnavailableView.search(text: searchQuery)
                    .listRowBackground(Color.clear)
            }
        }
            .refreshable { await viewModel.refresh() }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Cloudex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                rootToolbar
                homeTitleToolbar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                conversationSearchBar(isWindowedIPad: windowed, bottomSafeArea: bottomSafeArea)
            }
    }

    @ToolbarContentBuilder
    private var rootToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingQRCodeScanner = true } label: {
                Image(systemName: "qrcode.viewfinder")
            }
            .accessibilityLabel("扫描服务器二维码")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("打开设置")
        }
    }

    @ToolbarContentBuilder
    private var homeTitleToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text("Cloudex")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.isConnected ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(cloudexLocalized(viewModel.isConnected ? "已连接" : "未连接"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(cloudexLocalized(viewModel.isConnected ? "已连接" : "未连接"))
            }
            .frame(maxWidth: 220)
        }
    }

    @ViewBuilder
    private var iPadConversationColumn: some View {
        if let project = iPadSelectedProject {
            List {
                Section {
                    Button {
                        startNewIPadConversation(in: project)
                    } label: {
                        Label("新对话", systemImage: "square.and.pencil")
                            .fontWeight(.semibold)
                    }
                }

                let projectPinnedConversations = pinnedConversations.filter { $0.project.id == project.id }
                if !projectPinnedConversations.isEmpty {
                    Section("置顶") {
                        ForEach(projectPinnedConversations) { pinned in
                            iPadConversationButton(pinned.thread, project: project)
                                .listRowBackground(iPadSelectionRowBackground(for: pinned.thread.id))
                        }
                    }
                }

                Section("对话") {
                    ForEach(iPadVisibleThreads) { thread in
                        VStack(alignment: .leading, spacing: 0) {
                            iPadConversationButton(thread, project: project)

                            ForEach(matchesByThreadID[thread.id] ?? []) { match in
                                iPadSearchMatchButton(match, thread: thread, project: project)
                            }
                        }
                        .listRowBackground(iPadSelectionRowBackground(for: thread.id))
                    }

                    if iPadVisibleThreads.isEmpty, !isSearchingMessages {
                        ContentUnavailableView.search(text: searchQuery)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .refreshable { await viewModel.refresh() }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(project.displayName)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                conversationSearchBar
            }
        } else {
            ContentUnavailableView(
                "选择一个项目",
                systemImage: "folder",
                description: Text("从左侧栏选择项目。")
            )
        }
    }

    private func connect(using code: String) {
        guard let payload = CloudexConnectionPayload(code: code) else {
            showingQRCodeScanner = false
            scannerErrorMessage = "这不是有效的 Cloudex 服务器连接二维码。"
            showingScannerError = true
            return
        }

        showingQRCodeScanner = false
        Task {
            let mode = payload.preferredConnectionMode
            await viewModel.applySettings(
                lanServerURL: mode == .lan ? payload.serverURL : viewModel.lanServerURL,
                tailscaleServerURL: mode == .tailscale ? payload.serverURL : viewModel.tailscaleServerURL,
                connectionMode: mode,
                token: payload.token
            )
        }
    }

    private var filteredProjects: [CloudexProject] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.projects.compactMap { project in
            let threads = project.threads
                .filter { thread in
                    !viewModel.isPinned(thread.id)
                        && (query.isEmpty
                        || matchesByThreadID[thread.id]?.isEmpty == false
                        || [thread.title, thread.preview ?? "", thread.cwd ?? "", project.displayName]
                            .contains { $0.localizedCaseInsensitiveContains(query) })
                }
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            guard !threads.isEmpty else { return nil }
            return CloudexProject(
                id: project.id,
                name: project.name,
                cwd: project.cwd,
                threads: threads,
                updatedAt: project.updatedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.isNoProjectLike != rhs.isNoProjectLike {
                return !lhs.isNoProjectLike
            }
            return (lhs.updatedAt ?? 0) > (rhs.updatedAt ?? 0)
        }
    }

    private var iPadProjects: [CloudexProject] {
        viewModel.projects.sorted { lhs, rhs in
            if lhs.isNoProjectLike != rhs.isNoProjectLike {
                return !lhs.isNoProjectLike
            }
            return (lhs.updatedAt ?? 0) > (rhs.updatedAt ?? 0)
        }
    }

    private var iPadSidebarProjects: [CloudexProject] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return iPadProjects.compactMap { project in
            let threads = project.threads
                .filter { thread in
                    !viewModel.isPinned(thread.id)
                        && (query.isEmpty
                        || matchesByThreadID[thread.id]?.isEmpty == false
                        || [thread.title, thread.preview ?? "", thread.cwd ?? "", project.displayName]
                            .contains { $0.localizedCaseInsensitiveContains(query) })
                }
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            guard query.isEmpty || !threads.isEmpty else { return nil }
            return CloudexProject(
                id: project.id,
                name: project.name,
                cwd: project.cwd,
                threads: threads,
                updatedAt: project.updatedAt
            )
        }
    }

    private var iPadSelectedProject: CloudexProject? {
        iPadProjects.first { $0.id == iPadSelectedProjectID }
    }

    private var showsIPadSelectionBackground: Bool {
        iPadColumnVisibility == .all || iPadColumnVisibility == .doubleColumn
    }

    private var iPadVisibleThreads: [CloudexThread] {
        guard let project = iPadSelectedProject else { return [] }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return project.threads
            .filter { thread in
                !viewModel.isPinned(thread.id)
                    && (query.isEmpty
                    || matchesByThreadID[thread.id]?.isEmpty == false
                    || [thread.title, thread.preview ?? "", thread.cwd ?? "", project.displayName]
                        .contains { $0.localizedCaseInsensitiveContains(query) })
            }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    private var pinnedConversations: [PinnedConversation] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.projects
            .flatMap { project in
                project.threads.map { PinnedConversation(project: project, thread: $0) }
            }
            .filter { pinned in
                viewModel.isPinned(pinned.thread.id)
                    && (query.isEmpty
                        || matchesByThreadID[pinned.thread.id]?.isEmpty == false
                        || [
                            pinned.thread.title,
                            pinned.thread.preview ?? "",
                            pinned.thread.cwd ?? "",
                            pinned.project.displayName,
                        ].contains { $0.localizedCaseInsensitiveContains(query) })
            }
            .sorted { ($0.thread.updatedAt ?? 0) > ($1.thread.updatedAt ?? 0) }
    }

    private func iPadProjectButton(_ project: CloudexProject) -> some View {
        Button {
            iPadSelectedProjectID = project.id
            viewModel.selectProject(project.isNoProjectLike ? nil : project.cwd)
            searchQuery = ""
        } label: {
            ProjectRow(project: project)
                .equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            iPadSelectedProjectID == project.id
                ? Color.accentColor.opacity(0.14)
                : Color.clear
        )
    }

    private func iPadConversationButton(_ thread: CloudexThread, project: CloudexProject) -> some View {
        Button {
            openIPadThread(thread, project: project)
        } label: {
            ThreadRow(thread: thread)
                .equatable()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                Task { await viewModel.archive(thread.id) }
            } label: {
                Label("归档", systemImage: "archivebox")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            pinButton(thread)
        }
    }

    private func iPadSelectionRowBackground(for threadID: String) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                Color.black.opacity(
                    showsIPadSelectionBackground && iPadSelectedThreadRoute == threadID ? 0.14 : 0
                )
            )
    }

    private func iPadSearchMatchButton(
        _ match: ConversationSearchMatch,
        thread: CloudexThread,
        project: CloudexProject
    ) -> some View {
        Button {
            viewModel.requestMessageJump(
                threadID: thread.id,
                messageID: match.messageId,
                turnID: match.turnId,
                query: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            openIPadThread(thread, project: project, clearJumpRequest: false)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: match.role == "user" ? "person.fill" : "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)

                Text(searchHighlightedText(match.snippet))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Divider().padding(.leading, 38)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("跳转到匹配消息：\(match.snippet)")
    }

    private func openIPadThread(
        _ thread: CloudexThread,
        project: CloudexProject,
        clearJumpRequest: Bool = true
    ) {
        if clearJumpRequest { viewModel.clearMessageJumpRequest() }
        iPadSelectedProjectID = project.id
        iPadSelectedThreadRoute = thread.id
        iPadPreferredCompactColumn = .detail
        lastOpenedThreadID = thread.id
        searchFieldFocused = false
        Task {
            await viewModel.openThread(
                thread,
                projectCWD: project.isNoProjectLike ? nil : project.cwd
            )
        }
    }

    private func startNewIPadConversation(in project: CloudexProject) {
        let projectCWD = project.isNoProjectLike ? nil : project.cwd
        viewModel.clearMessageJumpRequest()
        iPadSelectedProjectID = project.id
        if projectCWD == nil { viewModel.selectProject(nil) }
        viewModel.startNewChat(projectCWD: projectCWD, clearProject: projectCWD == nil)
        iPadSelectedThreadRoute = projectCWD == nil
            ? "new-no-project-\(UUID().uuidString)"
            : "new-\(UUID().uuidString)"
        iPadPreferredCompactColumn = .detail
        searchFieldFocused = false
    }

    private func requestIPadMessageJump(messageID: String, turnID: String) {
        guard let threadID = viewModel.selectedThreadID else { return }
        viewModel.requestMessageJump(
            threadID: threadID,
            messageID: messageID,
            turnID: turnID,
            query: ""
        )
    }

    private func iPadSidebarWidth(for totalWidth: CGFloat) -> CGFloat {
        min(340, max(290, totalWidth * 0.36))
    }

    private func restoreIPadSelectionIfNeeded() async {
        guard usesIPadLayout, !restoredIPadSelection else { return }
        restoredIPadSelection = true

        let projectThreads: [(project: CloudexProject, thread: CloudexThread)] = iPadProjects.flatMap { project in
            project.threads.map { thread in
                (project: project, thread: thread)
            }
        }
        let target = projectThreads.first { $0.thread.id == lastOpenedThreadID }
            ?? projectThreads.max { ($0.thread.updatedAt ?? 0) < ($1.thread.updatedAt ?? 0) }

        guard let (project, thread) = target else {
            normalizeIPadProjectSelection()
            return
        }
        iPadSelectedProjectID = project.id
        iPadSelectedThreadRoute = thread.id
        lastOpenedThreadID = thread.id
        await viewModel.openThread(
            thread,
            projectCWD: project.isNoProjectLike ? nil : project.cwd
        )
    }

    private func normalizeIPadProjectSelection() {
        guard usesIPadLayout else { return }
        if let selected = iPadSelectedProjectID,
           iPadProjects.contains(where: { $0.id == selected }) {
            return
        }
        iPadSelectedProjectID = iPadProjects.first?.id
    }

    private func selectProjectContainingThread(_ threadID: String) {
        guard let project = iPadProjects.first(where: { project in
            project.threads.contains(where: { $0.id == threadID })
        }) else { return }
        iPadSelectedProjectID = project.id
    }

    private func isProjectCollapsed(_ project: CloudexProject) -> Bool {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isSearching && collapsedProjectIDs.contains(project.id)
    }

    private func toggleProject(_ project: CloudexProject) {
        if collapsedProjectIDs.contains(project.id) {
            collapsedProjectIDs.remove(project.id)
        } else {
            collapsedProjectIDs.insert(project.id)
        }
    }

    private var matchesByThreadID: [String: [ConversationSearchMatch]] {
        Dictionary(grouping: searchMatches, by: \.threadId)
    }

    private func projectNewConversationButton(_ project: CloudexProject) -> some View {
        Button {
            let projectCWD = project.isNoProjectLike ? nil : project.cwd
            viewModel.clearMessageJumpRequest()
            // startNewChat normally preserves the current project when it is
            // passed nil. Clear it first so the “无项目” section really opens
            // an unscoped conversation instead of reusing the previous cwd.
            if projectCWD == nil { viewModel.selectProject(nil) }
            viewModel.startNewChat(projectCWD: projectCWD, clearProject: projectCWD == nil)
            let route = projectCWD == nil
                ? "new-no-project-\(UUID().uuidString)"
                : "new-\(UUID().uuidString)"
            navigationPath.append(route)
        } label: {
            Label("新对话", systemImage: "square.and.pencil")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("在\(project.displayName)中新建对话")
    }

    private func conversationButton(_ thread: CloudexThread, projectCWD: String?) -> some View {
        Button {
            viewModel.clearMessageJumpRequest()
            lastOpenedThreadID = thread.id
            // Push immediately so the navigation bar switches to the child
            // page while the thread data is loading.
            navigationPath.append(thread.id)
            Task {
                await viewModel.openThread(thread, projectCWD: projectCWD)
            }
        } label: {
            ThreadRow(thread: thread)
                .equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                Task { await viewModel.archive(thread.id) }
            } label: {
                Label("归档", systemImage: "archivebox")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            pinButton(thread)
        }
    }

    private func pinButton(_ thread: CloudexThread) -> some View {
        Button {
            viewModel.togglePinned(thread.id)
        } label: {
            Label(
                viewModel.isPinned(thread.id) ? "取消置顶" : "置顶",
                systemImage: viewModel.isPinned(thread.id) ? "pin.slash" : "pin"
            )
        }
        .tint(.orange)
    }

    private func searchMatchButton(
        _ match: ConversationSearchMatch,
        thread: CloudexThread,
        projectCWD: String?
    ) -> some View {
        Button {
            viewModel.requestMessageJump(
                threadID: thread.id,
                messageID: match.messageId,
                turnID: match.turnId,
                query: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            lastOpenedThreadID = thread.id
            navigationPath.append(thread.id)
            Task {
                await viewModel.openThread(thread, projectCWD: projectCWD)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: match.role == "user" ? "person.fill" : "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)

                Text(searchHighlightedText(match.snippet))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Divider().padding(.leading, 38)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("跳转到匹配消息：\(match.snippet)")
    }

    private func searchHighlightedText(_ text: String) -> AttributedString {
        highlightedAttributedString(
            text,
            query: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func scheduleMessageSearch(_ query: String) {
        searchRequest?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchMatches = []
            isSearchingMessages = false
            return
        }
        isSearchingMessages = true
        searchRequest = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            let matches = await viewModel.searchConversationMessages(trimmed)
            guard !Task.isCancelled,
                  searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            searchMatches = matches
            isSearchingMessages = false
        }
    }

    @ViewBuilder
    private var conversationSearchBar: some View {
        conversationSearchBar(isWindowedIPad: false, bottomSafeArea: 0)
    }

    @ViewBuilder
    private func conversationSearchBar(isWindowedIPad: Bool, bottomSafeArea: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            // Keep the resting shapes visually separate. The smaller merge
            // threshold still lets the interactive glass expansion join them
            // while the field or close button is being pressed.
            GlassEffectContainer(spacing: 4) {
                conversationSearchControls(useLiquidGlass: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, bottomControlPadding(isWindowedIPad: isWindowedIPad, bottomSafeArea: bottomSafeArea))
        } else {
            conversationSearchControls(useLiquidGlass: false)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, bottomControlPadding(isWindowedIPad: isWindowedIPad, bottomSafeArea: bottomSafeArea))
        }
    }

    private func bottomControlPadding(isWindowedIPad: Bool, bottomSafeArea: CGFloat) -> CGFloat {
        if keyboardHeight > 0 { return 18 }
        guard UIDevice.current.userInterfaceIdiom == .pad else { return -7 }
        guard isWindowedIPad else { return 0 }
        return max(0, 24 - bottomSafeArea)
    }

    private func isWindowedIPad(for size: CGSize) -> Bool {
        let screen = UIScreen.main.bounds.size
        let screenWidth = max(screen.width, screen.height)
        let screenHeight = min(screen.width, screen.height)
        let windowWidth = max(size.width, size.height)
        let windowHeight = min(size.width, size.height)
        return windowWidth < screenWidth - 48 || windowHeight < screenHeight - 48
    }

    private func conversationSearchControls(useLiquidGlass: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(cloudexLocalized("搜索对话"), text: $searchQuery)
                    .focused($searchFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { searchFieldFocused = false }

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索内容")
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Capsule())
            .modifier(SearchFieldSurface(useLiquidGlass: useLiquidGlass))

            if searchFieldFocused {
                Button {
                    searchQuery = ""
                    searchFieldFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .modifier(SearchCloseSurface(useLiquidGlass: useLiquidGlass))
                .accessibilityLabel("退出搜索")
                .transition(.scale(scale: 0.65).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: searchFieldFocused)
    }

}

private struct PinnedConversation: Identifiable, Equatable {
    let project: CloudexProject
    let thread: CloudexThread

    var id: String { thread.id }
    var projectCWD: String? {
        project.isNoProjectLike ? nil : project.cwd
    }
}

private struct SearchFieldSurface: ViewModifier {
    let useLiquidGlass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), useLiquidGlass {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

private struct SearchCloseSurface: ViewModifier {
    let useLiquidGlass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), useLiquidGlass {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

private final class SearchBarGlassContainerView: UIView {
    let searchBar = UISearchBar(frame: .zero)
    private var glassContentView: UIView?
    private var searchFieldGlassView: UIVisualEffectView?
    private var cancelButtonGlassView: UIVisualEffectView?

    override init(frame: CGRect) {
        super.init(frame: frame)

        let hostView: UIView
        if #available(iOS 26.0, *) {
            let containerEffect = UIGlassContainerEffect()
            // Apple defines this as the distance at which neighboring glass
            // elements begin merging. Keep it slightly wider than the native
            // search bar gap so the cancel button visibly adheres to the field.
            containerEffect.spacing = 20
            let effectView = UIVisualEffectView(effect: containerEffect)
            effectView.backgroundColor = .clear
            hostView = effectView

            let fieldEffect = UIGlassEffect(style: .regular)
            fieldEffect.isInteractive = true
            let fieldGlassView = UIVisualEffectView(effect: fieldEffect)
            fieldGlassView.isUserInteractionEnabled = false

            let cancelEffect = UIGlassEffect(style: .regular)
            cancelEffect.isInteractive = true
            let cancelGlassView = UIVisualEffectView(effect: cancelEffect)
            cancelGlassView.isUserInteractionEnabled = false
            cancelGlassView.isHidden = true

            effectView.contentView.addSubview(fieldGlassView)
            effectView.contentView.addSubview(cancelGlassView)
            effectView.contentView.addSubview(searchBar)
            glassContentView = effectView.contentView
            searchFieldGlassView = fieldGlassView
            cancelButtonGlassView = cancelGlassView
        } else {
            hostView = UIView(frame: .zero)
            hostView.addSubview(searchBar)
        }

        backgroundColor = .clear
        hostView.translatesAutoresizingMaskIntoConstraints = false
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostView)

        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostView.topAnchor.constraint(equalTo: topAnchor),
            hostView.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            searchBar.topAnchor.constraint(equalTo: hostView.topAnchor),
            searchBar.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard #available(iOS 26.0, *),
              let glassContentView,
              let searchFieldGlassView,
              let cancelButtonGlassView else { return }

        searchBar.layoutIfNeeded()

        let textField = searchBar.searchTextField
        let fieldFrame = textField.convert(textField.bounds, to: glassContentView)
        searchFieldGlassView.frame = fieldFrame
        searchFieldGlassView.layer.cornerRadius = fieldFrame.height / 2
        searchFieldGlassView.layer.cornerCurve = .continuous
        searchFieldGlassView.clipsToBounds = true

        let cancelButton = allSubviews(of: searchBar)
            .compactMap { $0 as? UIButton }
            .first { !$0.isDescendant(of: textField) && !$0.isHidden && $0.alpha > 0.01 }

        guard let cancelButton else {
            cancelButtonGlassView.isHidden = true
            return
        }

        let cancelFrame = cancelButton.convert(cancelButton.bounds, to: glassContentView)
        cancelButtonGlassView.frame = cancelFrame
        cancelButtonGlassView.layer.cornerRadius = cancelFrame.height / 2
        cancelButtonGlassView.layer.cornerCurve = .continuous
        cancelButtonGlassView.clipsToBounds = true
        cancelButtonGlassView.isHidden = cancelFrame.isEmpty
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}

private struct SystemSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SearchBarGlassContainerView {
        let container = SearchBarGlassContainerView(frame: .zero)
        let searchBar = container.searchBar
        searchBar.delegate = context.coordinator
        searchBar.searchBarStyle = .default
        searchBar.placeholder = prompt
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .search
        searchBar.setShowsCancelButton(false, animated: false)
        return container
    }

    func updateUIView(_ container: SearchBarGlassContainerView, context: Context) {
        context.coordinator.parent = self
        let searchBar = container.searchBar
        if searchBar.text != text {
            searchBar.text = text
        }
        if searchBar.showsCancelButton != isFocused {
            searchBar.setShowsCancelButton(isFocused, animated: searchBar.window != nil)
        }
        if isFocused, !searchBar.isFirstResponder {
            searchBar.becomeFirstResponder()
        } else if !isFocused, searchBar.isFirstResponder {
            searchBar.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: SystemSearchField

        init(_ parent: SystemSearchField) {
            self.parent = parent
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            // During Chinese/Japanese/Korean IME composition UISearchBar sends
            // textDidChange for the unfinished marked (拼音) text. Do not use
            // that temporary text to filter conversations until composition
            // has been committed.
            guard searchBar.searchTextField.markedTextRange == nil else { return }
            parent.text = searchText
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            parent.isFocused = false
            searchBar.resignFirstResponder()
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            parent.isFocused = true
            searchBar.setShowsCancelButton(true, animated: true)
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            parent.isFocused = false
        }

        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            parent.text = ""
            parent.isFocused = false
            searchBar.text = ""
            searchBar.setShowsCancelButton(false, animated: true)
            searchBar.resignFirstResponder()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var isPresented: Bool

    @State private var snapshot = SidebarSnapshot.empty

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        viewModel.startNewChat(projectCWD: viewModel.selectedProjectCWD)
                        isPresented = false
                    } label: {
                        Label("新对话", systemImage: "square.and.pencil")
                            .fontWeight(.semibold)
                    }
                }

                Section("有项目") {
                    if snapshot.projectGroups.isEmpty {
                        Text("没有项目").foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.projectGroups) { project in
                        NavigationLink(value: project.id) {
                            ProjectRow(project: project)
                                .equatable()
                        }
                    }
                }

                Section("无项目") {
                    if snapshot.noProjectThreads.isEmpty {
                        Text("没有对话").foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.noProjectThreads) { thread in
                        ThreadRow(thread: thread)
                            .equatable()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task {
                                    await viewModel.openThread(thread, projectCWD: nil)
                                    isPresented = false
                                }
                            }
                            .swipeActions {
                                archiveButton(thread)
                            }
                    }
                }
            }
            .navigationTitle("项目与对话")
            .navigationDestination(for: String.self) { projectID in
                if let project = snapshot.project(id: projectID) {
                    ProjectThreadsView(project: project, threads: project.sortedThreads, isPresented: $isPresented)
                        .environmentObject(viewModel)
                } else {
                    Text("项目不存在")
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear {
                snapshot = SidebarSnapshot(projects: viewModel.projects)
            }
            .onReceive(viewModel.$projects.removeDuplicates()) { projects in
                snapshot = SidebarSnapshot(projects: projects)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await viewModel.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { isPresented = false }
                }
            }
        }
    }

    private func archiveButton(_ thread: CloudexThread) -> some View {
        Button(role: .destructive) {
            Task { await viewModel.archive(thread.id) }
        } label: {
            Label("归档", systemImage: "archivebox")
        }
    }
}


private struct SidebarSnapshot: Equatable {
    static let empty = SidebarSnapshot(projectGroups: [], noProjectThreads: [])

    let projectGroups: [CloudexProject]
    let noProjectThreads: [CloudexThread]

    init(projects: [CloudexProject]) {
        self.projectGroups = projects
            .filter { !$0.isNoProjectLike }
            .map { $0.withSortedThreads }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        self.noProjectThreads = projects
            .filter(\.isNoProjectLike)
            .flatMap(\.threads)
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    private init(projectGroups: [CloudexProject], noProjectThreads: [CloudexThread]) {
        self.projectGroups = projectGroups
        self.noProjectThreads = noProjectThreads
    }

    func project(id: String) -> CloudexProject? {
        projectGroups.first { $0.id == id }
    }
}

private extension CloudexProject {
    var sortedThreads: [CloudexThread] {
        threads.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    var withSortedThreads: CloudexProject {
        CloudexProject(id: id, name: name, cwd: cwd, threads: sortedThreads, updatedAt: updatedAt)
    }
}

private struct ProjectThreadsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let project: CloudexProject
    let threads: [CloudexThread]
    @Binding var isPresented: Bool

    var body: some View {
        List {
            Section {
                Button {
                    viewModel.startNewChat(projectCWD: project.cwd)
                    isPresented = false
                } label: {
                    Label("在此项目中新建对话", systemImage: "square.and.pencil")
                }
            }

            Section("对话") {
                if threads.isEmpty {
                    Text("这个项目还没有对话").foregroundStyle(.secondary)
                }
                ForEach(threads) { thread in
                    ThreadRow(thread: thread)
                        .equatable()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task {
                                await viewModel.openThread(thread, projectCWD: project.cwd)
                                isPresented = false
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await viewModel.archive(thread.id) }
                            } label: {
                                Label("归档", systemImage: "archivebox")
                            }
                        }
                }
            }
        }
        .navigationTitle(project.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProjectRow: View, Equatable {
    let project: CloudexProject

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(.blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.displayName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(cloudexLocalized("%lld 个对话", Int64(project.threads.count)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ThreadRow: View, Equatable {
    let thread: CloudexThread

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(thread.title)
                .foregroundStyle(.primary)
                .lineLimit(2)
            HStack(spacing: 6) {
                if thread.isActive {
                    Text(cloudexLocalized("运行中"))
                        .foregroundStyle(.green)
                }
                Text(DateFormatting.string(from: thread.updatedAt))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
