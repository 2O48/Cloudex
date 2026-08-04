import SwiftUI
import Combine
import UIKit

struct CloudexRootView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var navigationPath: [String] = []
    @State private var searchQuery = ""
    @State private var showingSettings = false
    @State private var searchFieldFocused = false
    @State private var keyboardHeight: CGFloat = 0

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    Button {
                        viewModel.startNewChat(projectCWD: viewModel.selectedProjectCWD)
                        navigationPath.append("new-\(UUID().uuidString)")
                    } label: {
                        Label("新对话", systemImage: "square.and.pencil")
                            .fontWeight(.semibold)
                    }
                }

                ForEach(filteredProjects) { project in
                    Section(project.displayName) {
                        ForEach(project.threads) { thread in
                            conversationButton(thread, projectCWD: project.isNoProjectLike ? nil : project.cwd)
                        }
                    }
                }

                if filteredProjects.isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("对话")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await viewModel.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新对话")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("打开设置")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                conversationSearchBar
            }
            .navigationDestination(for: String.self) { threadID in
                ContentView(expectedThreadID: threadID)
            }
        }
        .task {
            await viewModel.start()
            await viewModel.loadModelsIfNeeded()
        }
        .onChange(of: navigationPath) { _, _ in
            // Do not leave the keyboard attached while transitioning to a chat.
            searchFieldFocused = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
            keyboardHeight = max(0, UIScreen.main.bounds.maxY - value.cgRectValue.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(isPresented: $showingSettings)
                .environmentObject(viewModel)
        }
    }

    private var filteredProjects: [CloudexProject] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.projects.compactMap { project in
            let threads = project.threads
                .filter { thread in
                    query.isEmpty || [thread.title, thread.preview ?? "", thread.cwd ?? "", project.displayName]
                        .contains { $0.localizedCaseInsensitiveContains(query) }
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
        .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    private func conversationButton(_ thread: CloudexThread, projectCWD: String?) -> some View {
        Button {
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
    }

    private var conversationSearchBar: some View {
        HStack(spacing: 8) {
            SystemSearchField(
                text: $searchQuery,
                isFocused: $searchFieldFocused,
                prompt: "搜索对话"
            )
            .padding(.horizontal, 4)
            .frame(height: 52)
            .rootLiquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: true)

            if searchFieldFocused {
                Button {
                    searchQuery = ""
                    searchFieldFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .rootLiquidGlass(in: Circle(), interactive: true)
                .contentShape(Circle())
                .zIndex(20)
                .accessibilityLabel("退出搜索")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: searchFieldFocused)
        .shadow(color: .black.opacity(0.14), radius: 16, y: 7)
        // Match the device's bottom corner geometry: leave a wider side
        // inset and visually settle the controls into the bottom safe area.
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, keyboardHeight > 0 ? 18 : -7)
    }

}

private struct SystemSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar(frame: .zero)
        searchBar.delegate = context.coordinator
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = prompt
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .search
        searchBar.backgroundImage = UIImage()
        searchBar.backgroundColor = .clear
        searchBar.searchTextField.backgroundColor = .clear
        searchBar.searchTextField.clearButtonMode = .whileEditing
        searchBar.searchTextField.borderStyle = .none
        searchBar.searchTextField.textColor = .label
        searchBar.searchTextField.contentVerticalAlignment = .center
        let iconContainer = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        let iconView = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor, constant: 2),
            iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: -2),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.heightAnchor.constraint(equalToConstant: 20)
        ])
        searchBar.searchTextField.leftView = iconContainer
        searchBar.searchTextField.leftViewMode = .always
        return searchBar
    }

    func updateUIView(_ searchBar: UISearchBar, context: Context) {
        if searchBar.text != text {
            searchBar.text = text
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
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            parent.isFocused = false
        }
    }
}

private extension View {
    @ViewBuilder
    func rootLiquidGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.32), lineWidth: 0.7))
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
                Text("\(project.threads.count) 个对话")
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
                    Text("运行中")
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
