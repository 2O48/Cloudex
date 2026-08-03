import SwiftUI
import Combine

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
