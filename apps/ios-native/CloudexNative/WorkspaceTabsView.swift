import Foundation
import Combine
import gitdiff
import QuickLook
import SwiftUI
import WebKit

struct WorkspaceFilesView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let rootPath: String

    @State private var currentPath: String
    @State private var history: [String] = []
    @State private var entries: [RemoteFileEntry] = []
    @State private var isLoading = false
    @State private var previewLoadingPath: String?
    @State private var previewItem: WorkspacePreviewItem?
    @State private var errorText: String?

    init(rootPath: String) {
        self.rootPath = rootPath
        _currentPath = State(initialValue: rootPath)
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if rootPath.isEmpty {
                    ContentUnavailableView("没有工作区", systemImage: "folder.badge.questionmark", description: Text("请先选择一个项目或打开带工作目录的对话。"))
                } else if isLoading && entries.isEmpty {
                    ProgressView("读取工作区…")
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
                                if previewLoadingPath == entry.path {
                                    ProgressView().controlSize(.small)
                                } else if entry.isDirectory {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Image(systemName: "eye")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(previewLoadingPath != nil)
                    }
                    .listStyle(.plain)
                    .refreshable { await load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !rootPath.isEmpty {
                    Color.clear
                        .frame(height: max(0, 78 - geometry.safeAreaInsets.bottom))
                }
            }
            .overlay(alignment: .bottom) {
                if !rootPath.isEmpty {
                    workspacePathBar
                        .padding(.horizontal, 30)
                        .padding(.bottom, 30)
                        .offset(y: geometry.safeAreaInsets.bottom)
                }
            }
        }
        .task(id: currentPath) { await load() }
        .sheet(item: $previewItem) { item in
            NavigationStack {
                Group {
                    if let code = item.code {
                        CodePreviewView(source: code, fileName: item.name)
                    } else {
                        QuickLookPreview(url: item.url)
                    }
                }
                    .navigationTitle(item.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { previewItem = nil }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .alert("无法预览文件", isPresented: Binding(
            get: { errorText != nil && !entries.isEmpty },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText ?? "未知错误")
        }
    }

    private var workspacePathBar: some View {
        WorkspacePathBar(
            rootPath: rootPath,
            currentPath: currentPath,
            canGoBack: !history.isEmpty,
            onBack: {
                if let previous = history.popLast() { currentPath = previous }
            },
            onSelectPath: jump(to:)
        )
    }

    private func jump(to path: String) {
        guard path != currentPath else { return }
        history.append(currentPath)
        currentPath = path
    }

    private func open(_ entry: RemoteFileEntry) {
        if entry.isDirectory {
            history.append(currentPath)
            currentPath = entry.path
            return
        }
        previewLoadingPath = entry.path
        Task {
            do {
                let data = try await viewModel.previewFile(path: entry.path)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("CloudexPreviews", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let localURL = directory.appendingPathComponent(entry.name)
                try data.write(to: localURL, options: .atomic)
                previewItem = WorkspacePreviewItem(
                    name: entry.name,
                    url: localURL,
                    code: CodePreviewFile.supports(fileName: entry.name) ? CodePreviewFile.decode(data) : nil
                )
            } catch {
                errorText = error.localizedDescription
            }
            previewLoadingPath = nil
        }
    }

    private func load() async {
        guard !currentPath.isEmpty else { return }
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

private struct ProjectReviewDisplayItem: Identifiable {
    let id: String
    let line: ProjectReviewLine?
    let hiddenLineCount: Int?
    let hiddenLineRange: ClosedRange<Int>?
}

struct ProjectReviewView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let rootPath: String

    @State private var review: ProjectReviewResponse?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var collapsedFileIDs = Set<String>()
    @State private var expandedHiddenSegmentIDs = Set<String>()
    @State private var hiddenLineContents: [String: [ProjectReviewLine]] = [:]
    @State private var loadingHiddenSegmentIDs = Set<String>()
    @State private var reviewLoadGeneration = 0

    var body: some View {
        Group {
            if rootPath.isEmpty {
                ContentUnavailableView("没有工作区", systemImage: "folder.badge.questionmark", description: Text("请先选择一个项目或打开带工作目录的对话。"))
            } else if isLoading && review == nil {
                ProgressView("读取改动…")
            } else if let errorText, review == nil {
                ContentUnavailableView("无法读取审阅内容", systemImage: "exclamationmark.triangle", description: Text(errorText))
            } else if let review, review.displayableFiles.isEmpty {
                ContentUnavailableView("没有可显示的文本改动", systemImage: "checkmark.circle", description: Text("二进制文件不会显示，当前没有可展开的文本差异。"))
            } else if review == nil {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("审阅暂时不可用")
                        .font(.headline)
                    Text("请下拉刷新，或检查服务器连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重新读取") {
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                reviewContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: rootPath) { await load() }
        .refreshable { await load() }
        .alert("无法读取审阅内容", isPresented: Binding(
            get: { errorText != nil && review != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText ?? "未知错误")
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        if let review {
            let files = review.displayableFiles
            let totalAdditions = files.reduce(0) { $0 + $1.additions }
            let totalDeletions = files.reduce(0) { $0 + $1.deletions }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                        Text("相对 \(review.base)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(files.count) 个文件")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("+\(totalAdditions)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.green)
                        Text("-\(totalDeletions)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.red)
                    }

                    ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                        reviewFile(file, identity: "\(index)-\(file.path)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func reviewFile(_ file: ProjectReviewFile, identity: String) -> some View {
        let isCollapsed = collapsedFileIDs.contains(identity)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusIcon(file.status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(file.status))
                Text(file.path)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text("+\(file.additions)")
                    .foregroundStyle(.green)
                Text("-\(file.deletions)")
                    .foregroundStyle(.red)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isCollapsed {
                            collapsedFileIDs.remove(identity)
                        } else {
                            collapsedFileIDs.insert(identity)
                        }
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isCollapsed ? "展开文件差异" : "收起文件差异")
            }
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemBackground))

            if !isCollapsed {
                if file.lines.isEmpty {
                    Text(statusTitle(file.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ForEach(displayItems(for: file, identity: identity)) { item in
                        if let line = item.line {
                            CodexDiffLineRow(line: makeDiffLine(line))
                        } else if let hiddenLineCount = item.hiddenLineCount,
                                  let hiddenLineRange = item.hiddenLineRange {
                            if expandedHiddenSegmentIDs.contains(item.id),
                               let expandedLines = hiddenLineContents[item.id] {
                                ForEach(expandedLines) { line in
                                    CodexDiffLineRow(line: makeDiffLine(line))
                                }
                            } else {
                                Button {
                                    expandHiddenSegment(
                                        item,
                                        file: file,
                                        range: hiddenLineRange
                                    )
                                } label: {
                                    HStack(spacing: 6) {
                                        if loadingHiddenSegmentIDs.contains(item.id) {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "ellipsis")
                                        }
                                        Text(loadingHiddenSegmentIDs.contains(item.id)
                                             ? "正在读取 \(hiddenLineCount) 行"
                                             : "\(hiddenLineCount) 行隐藏，点击展开")
                                    }
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 54)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .disabled(loadingHiddenSegmentIDs.contains(item.id))
                                .background(Color(.secondarySystemBackground).opacity(0.7))
                                .accessibilityLabel("展开隐藏的 \(hiddenLineCount) 行")
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator).opacity(0.45), lineWidth: 0.6)
        }
    }

    private func displayItems(for file: ProjectReviewFile, identity: String) -> [ProjectReviewDisplayItem] {
        let lines = file.lines
        guard !lines.isEmpty else { return [] }
        let changedIndexes = lines.indices.filter { index in
            lines[index].kind == "addition" || lines[index].kind == "deletion"
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

        if ranges.isEmpty {
            let lastIndex = min(lines.count - 1, 1)
            var items = (0...lastIndex).map { index in
                ProjectReviewDisplayItem(
                    id: "\(identity)-line-\(index)",
                    line: lines[index],
                    hiddenLineCount: nil,
                    hiddenLineRange: nil
                )
            }
            if let hiddenRange = hiddenLineRange(after: lines[lastIndex], in: file) {
                items.append(ProjectReviewDisplayItem(
                    id: "\(identity)-hidden-0",
                    line: nil,
                    hiddenLineCount: hiddenRange.count,
                    hiddenLineRange: hiddenRange
                ))
            }
            return items
        }

        var items: [ProjectReviewDisplayItem] = []
        var hiddenIndex = 0
        var lastVisibleLine: ProjectReviewLine?

        for range in ranges {
            let firstLine = lines[range.lowerBound]
            let hiddenRange: ClosedRange<Int>?
            if let lastVisibleLine {
                let start = diffLineNumber(lastVisibleLine) + 1
                let end = diffLineNumber(firstLine) - 1
                hiddenRange = start <= end ? start...end : nil
            } else {
                let end = diffLineNumber(firstLine) - 1
                hiddenRange = end > 0 ? 1...end : nil
            }
            if let hiddenRange {
                items.append(ProjectReviewDisplayItem(
                    id: "\(identity)-hidden-\(hiddenIndex)",
                    line: nil,
                    hiddenLineCount: hiddenRange.count,
                    hiddenLineRange: hiddenRange
                ))
                hiddenIndex += 1
            }

            for index in range {
                items.append(ProjectReviewDisplayItem(
                    id: "\(identity)-line-\(index)",
                    line: lines[index],
                    hiddenLineCount: nil,
                    hiddenLineRange: nil
                ))
            }
            lastVisibleLine = lines[range.upperBound]
        }

        if let lastVisibleLine {
            if let hiddenRange = hiddenLineRange(after: lastVisibleLine, in: file) {
                items.append(ProjectReviewDisplayItem(
                    id: "\(identity)-hidden-\(hiddenIndex)",
                    line: nil,
                    hiddenLineCount: hiddenRange.count,
                    hiddenLineRange: hiddenRange
                ))
            }
        }
        return items
    }

    private func diffLineNumber(_ line: ProjectReviewLine) -> Int {
        max(line.lineNumber, 1)
    }

    private func hiddenLineRange(after line: ProjectReviewLine, in file: ProjectReviewFile) -> ClosedRange<Int>? {
        let lineNumber = diffLineNumber(line)
        let totalLineCount = line.kind == "deletion"
            ? (file.oldLineCount ?? lineNumber)
            : (file.newLineCount ?? lineNumber)
        let start = lineNumber + 1
        guard start <= totalLineCount else { return nil }
        return start...totalLineCount
    }

    private func expandHiddenSegment(
        _ item: ProjectReviewDisplayItem,
        file: ProjectReviewFile,
        range: ClosedRange<Int>
    ) {
        guard !loadingHiddenSegmentIDs.contains(item.id) else { return }
        if hiddenLineContents[item.id] != nil {
            _ = withAnimation(.easeInOut(duration: 0.2)) {
                expandedHiddenSegmentIDs.insert(item.id)
            }
            return
        }

        loadingHiddenSegmentIDs.insert(item.id)
        Task { @MainActor in
            do {
                let filePath = (rootPath as NSString).appendingPathComponent(file.path)
                let data = try await viewModel.previewFile(path: filePath)
                guard let source = CodePreviewFile.decode(data) else {
                    throw NSError(
                        domain: "CloudexReview",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "无法读取隐藏行内容"]
                    )
                }
                let normalized = source
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                var sourceLines = normalized.components(separatedBy: "\n")
                if sourceLines.last == "" { sourceLines.removeLast() }
                let expandedLines = range.compactMap { lineNumber -> ProjectReviewLine? in
                    guard lineNumber >= 1,
                          lineNumber <= sourceLines.count else { return nil }
                    return ProjectReviewLine(
                        kind: "context",
                        text: sourceLines[lineNumber - 1],
                        lineNumber: lineNumber
                    )
                }
                hiddenLineContents[item.id] = expandedLines
                _ = withAnimation(.easeInOut(duration: 0.2)) {
                    expandedHiddenSegmentIDs.insert(item.id)
                }
            } catch {
                if !Task.isCancelled && !isCancellationError(error) {
                    errorText = error.localizedDescription
                }
            }
            loadingHiddenSegmentIDs.remove(item.id)
        }
    }

    private func makeDiffLine(_ line: ProjectReviewLine) -> DiffLine {
        switch line.kind {
        case "addition":
            return DiffLine(type: .added, content: line.text, oldLineNumber: nil, newLineNumber: line.lineNumber)
        case "deletion":
            return DiffLine(type: .removed, content: line.text, oldLineNumber: line.lineNumber, newLineNumber: nil)
        default:
            return DiffLine(type: .context, content: line.text, oldLineNumber: line.lineNumber, newLineNumber: line.lineNumber)
        }
    }

    private func statusTitle(_ status: String) -> String {
        switch status {
        case "added": return "新增文件"
        case "deleted": return "文件已删除"
        case "renamed": return "文件已重命名"
        default: return "文件已修改"
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "added": return "plus"
        case "deleted": return "minus"
        case "renamed": return "arrow.right"
        default: return "pencil"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "added": return .green
        case "deleted": return .red
        case "renamed": return .orange
        default: return .blue
        }
    }

    private func load() async {
        guard !rootPath.isEmpty else { return }
        reviewLoadGeneration += 1
        let generation = reviewLoadGeneration
        isLoading = true
        errorText = nil
        expandedHiddenSegmentIDs.removeAll()
        hiddenLineContents.removeAll()
        loadingHiddenSegmentIDs.removeAll()
        do {
            review = try await viewModel.loadProjectReview(path: rootPath)
        } catch {
            guard generation == reviewLoadGeneration else { return }
            if Task.isCancelled || isCancellationError(error) {
                isLoading = false
                return
            }
            errorText = error.localizedDescription
            if review == nil { review = nil }
        }
        guard generation == reviewLoadGeneration else { return }
        isLoading = false
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return (error as NSError).code == NSURLErrorCancelled
    }
}

struct WorkspacePathBar: View {
    let rootPath: String
    let currentPath: String
    let canGoBack: Bool
    let onBack: () -> Void
    let onSelectPath: (String) -> Void

    @State private var overflows = false
    @State private var scrollGeneration = 0

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)

            Divider()
                .frame(height: 20)

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 5) {
                            ForEach(Array(pathItems.enumerated()), id: \.element.path) { index, item in
                                let isCurrent = index == pathItems.count - 1
                                if index > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }

                                Button {
                                    onSelectPath(item.path)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: isCurrent ? "folder.fill" : "folder")
                                            .font(.caption)
                                            .foregroundStyle(isCurrent ? .blue : .secondary)
                                        Text(item.name)
                                            .font(.caption.weight(isCurrent ? .semibold : .regular))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(isCurrent ? .primary : .secondary)
                                    .padding(.horizontal, 6)
                                    .frame(height: 30)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isCurrent ? "当前文件夹，\(item.name)" : "返回文件夹，\(item.name)")
                                .id(item.path)
                            }
                        }
                        .padding(.horizontal, 8)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: geometry.size.height, alignment: .center)
                        .overlay(alignment: .trailing) {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("workspace-path-trailing-anchor")
                        }
                        .background {
                            GeometryReader { contentGeometry in
                                Color.clear.preference(
                                    key: WorkspacePathContentWidthKey.self,
                                    value: contentGeometry.size.width
                                )
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: geometry.size.height, alignment: .center)
                    .onPreferenceChange(WorkspacePathContentWidthKey.self) { contentWidth in
                        let overflowing = contentWidth > geometry.size.width + 1
                        if overflows != overflowing { overflows = overflowing }
                        guard overflowing else { return }
                        scrollToCurrent(using: proxy)
                    }
                    .onChange(of: currentPath) { _, _ in
                        guard overflows else { return }
                        scrollToCurrent(using: proxy)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 42)
        .modifier(WorkspacePathBarSurface())
    }

    private var pathItems: [WorkspacePathItem] {
        let normalizedRoot = (rootPath as NSString).standardizingPath
        let normalizedCurrent = (currentPath as NSString).standardizingPath
        let rootName = (normalizedRoot as NSString).lastPathComponent.isEmpty
            ? "工作区"
            : (normalizedRoot as NSString).lastPathComponent
        var items = [WorkspacePathItem(name: rootName, path: normalizedRoot)]

        guard normalizedCurrent != normalizedRoot,
              normalizedCurrent.hasPrefix(normalizedRoot + "/") else {
            return [WorkspacePathItem(
                name: (normalizedCurrent as NSString).lastPathComponent.isEmpty ? "工作区" : (normalizedCurrent as NSString).lastPathComponent,
                path: normalizedCurrent
            )]
        }

        let relativePath = String(normalizedCurrent.dropFirst(normalizedRoot.count + 1))
        var accumulatedPath = normalizedRoot
        for component in relativePath.split(separator: "/") {
            accumulatedPath = (accumulatedPath as NSString).appendingPathComponent(String(component))
            items.append(WorkspacePathItem(name: String(component), path: accumulatedPath))
        }
        return items
    }

    private func scrollToCurrent(using proxy: ScrollViewProxy) {
        scrollGeneration += 1
        let generation = scrollGeneration

        for delay in [0.0, 0.06, 0.18] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard overflows, scrollGeneration == generation else { return }
                proxy.scrollTo("workspace-path-trailing-anchor", anchor: .trailing)
            }
        }
    }
}

private struct WorkspacePathContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WorkspacePathItem {
    let name: String
    let path: String
}

private struct WorkspacePathBarSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = Capsule()
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: shape)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.28), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        }
    }
}

private struct WorkspacePreviewItem: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let code: String?
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct WorkspaceBrowserView: View {
    @StateObject private var model = WorkspaceBrowserModel()
    @State private var address = "https://www.google.com"
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoBack)
                .accessibilityLabel("返回")

                if model.canGoForward {
                    Button { model.goForward() } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("前进")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("输入网址", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit { openAddress() }
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { openAddress() } label: {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button { model.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新")
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.18), value: model.canGoForward)

            WorkspaceWebView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .onAppear {
            if model.currentURL == nil { model.load(address) }
        }
        .onReceive(model.$currentURL.compactMap { $0 }) { url in
            guard !addressFocused else { return }
            address = url.absoluteString
        }
    }

    private func openAddress() {
        addressFocused = false
        model.load(address)
    }
}

@MainActor
private final class WorkspaceBrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if URLComponents(string: normalized)?.scheme == nil { normalized = "https://" + normalized }
        guard let url = URL(string: normalized) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { webView.reload() }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { update(from: webView) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { update(from: webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { update(from: webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { update(from: webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { update(from: webView) }

    private func update(from webView: WKWebView) {
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }
}

private struct WorkspaceWebView: UIViewRepresentable {
    @ObservedObject var model: WorkspaceBrowserModel

    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
