import SwiftUI

struct RemoteFilePickerView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var isPresented: Bool
    let initialPath: String
    let onSelect: (RemoteFileEntry) -> Void

    @State private var currentPath: String
    @State private var history: [String] = []
    @State private var entries: [RemoteFileEntry] = []
    @State private var isLoading = false
    @State private var errorText: String?

    init(isPresented: Binding<Bool>, initialPath: String, onSelect: @escaping (RemoteFileEntry) -> Void) {
        _isPresented = isPresented
        self.initialPath = initialPath
        self.onSelect = onSelect
        _currentPath = State(initialValue: initialPath)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    if isLoading && entries.isEmpty {
                        ProgressView("读取电脑文件…")
                    } else if let errorText, entries.isEmpty {
                        ContentUnavailableView("无法读取目录", systemImage: "exclamationmark.triangle", description: Text(errorText))
                    } else {
                        List(entries) { entry in
                            Button {
                                open(entry)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: iconName(for: entry))
                                        .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        if !entry.isDirectory, let size = entry.size {
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: entry.isDirectory ? "chevron.right" : "paperclip")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                        .refreshable { await load() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !initialPath.isEmpty {
                        Color.clear
                            .frame(height: max(0, 78 - geometry.safeAreaInsets.bottom))
                    }
                }
                .overlay(alignment: .bottom) {
                    if !initialPath.isEmpty {
                        WorkspacePathBar(
                            rootPath: initialPath,
                            currentPath: currentPath,
                            canGoBack: !history.isEmpty,
                            onBack: {
                                if let previous = history.popLast() { currentPath = previous }
                            },
                            onSelectPath: jump(to:)
                        )
                        .padding(.horizontal, 30)
                        .padding(.bottom, 30)
                        .offset(y: geometry.safeAreaInsets.bottom)
                    }
                }
            }
            .navigationTitle("选择电脑文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { isPresented = false }
                }
            }
            .task(id: currentPath) { await load() }
        }
    }

    private func open(_ entry: RemoteFileEntry) {
        if entry.isDirectory {
            history.append(currentPath)
            currentPath = entry.path
        } else {
            onSelect(entry)
            isPresented = false
        }
    }

    private func jump(to path: String) {
        guard path != currentPath else { return }
        history.append(currentPath)
        currentPath = path
    }

    private func load() async {
        guard !currentPath.isEmpty else {
            errorText = "请先选择一个项目"
            return
        }
        isLoading = true
        errorText = nil
        do {
            let result = try await viewModel.listFiles(path: currentPath)
            currentPath = result.path
            entries = result.entries
        } catch {
            entries = []
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private func iconName(for entry: RemoteFileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "swift", "js", "ts", "json", "html", "css", "py", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}
