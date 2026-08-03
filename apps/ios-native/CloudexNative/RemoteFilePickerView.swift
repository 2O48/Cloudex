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
            Group {
                if isLoading && entries.isEmpty {
                    ProgressView("读取电脑文件…")
                } else if let errorText, entries.isEmpty {
                    ContentUnavailableView("无法读取目录", systemImage: "exclamationmark.triangle", description: Text(errorText))
                } else {
                    List(entries) { entry in
                        Button {
                            if entry.isDirectory {
                                history.append(currentPath)
                                currentPath = entry.path
                            } else {
                                onSelect(entry)
                                isPresented = false
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                                    if !entry.isDirectory, let size = entry.size {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if entry.isDirectory { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                            }
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("选择电脑文件")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Text(currentPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.thinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let previous = history.popLast() { currentPath = previous }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(history.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { isPresented = false }
                }
            }
            .task(id: currentPath) { await load() }
        }
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
}
