import Foundation

struct CachedThreadDetail: Codable {
    let threadID: String
    let detail: ThreadDetail
    let savedAt: Double
}

final class LocalConversationCache {
    static let shared = LocalConversationCache()

    private let rootURL: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        rootURL = base.appendingPathComponent("CloudexNative", isDirectory: true)
            .appendingPathComponent("ConversationCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func loadProjects() -> [CloudexProject]? {
        read([CloudexProject].self, from: rootURL.appendingPathComponent("projects.json"))
    }

    func saveProjects(_ projects: [CloudexProject]) {
        write(projects, to: rootURL.appendingPathComponent("projects.json"))
    }

    func loadThreadDetail(threadID: String) -> ThreadDetail? {
        read(CachedThreadDetail.self, from: threadFileURL(threadID)).map { compactDetail($0.detail) }
    }

    func saveThreadDetail(_ detail: ThreadDetail, threadID: String) {
        write(CachedThreadDetail(threadID: threadID, detail: compactDetail(detail), savedAt: Date().timeIntervalSince1970),
              to: threadFileURL(threadID))
    }

    func loadMessageIndex(threadID: String) -> [MessageIndexItem]? {
        read([MessageIndexItem].self, from: messageIndexFileURL(threadID))
    }

    func saveMessageIndex(_ items: [MessageIndexItem], threadID: String) {
        write(items, to: messageIndexFileURL(threadID))
    }

    private func compactDetail(_ detail: ThreadDetail) -> ThreadDetail {
        let turns = detail.turns.map { turn in
            let items = turn.items ?? []
            let finalAgentIndex = items.lastIndex { $0.type == "agentMessage" && $0.phase == "final_answer" }
                ?? items.lastIndex { $0.type == "agentMessage" }
            let visibleItems = items.enumerated().compactMap { index, item in
                item.type == "userMessage" || index == finalAgentIndex ? item : nil
            }
            let processItemCount = max(turn.processItemCount ?? 0, items.count - visibleItems.count)
            return CloudexTurn(
                id: turn.id,
                items: visibleItems,
                status: turn.status,
                error: turn.error,
                startedAt: turn.startedAt,
                completedAt: turn.completedAt,
                durationMs: turn.durationMs,
                compressed: turn.compressed,
                itemsView: turn.itemsView,
                processItemCount: processItemCount,
                detailsLoaded: processItemCount == 0
            )
        }
        return ThreadDetail(thread: detail.thread, turns: turns, hasMoreBefore: false, nextBefore: nil)
    }

    private func threadFileURL(_ threadID: String) -> URL {
        let safeID = threadID.replacingOccurrences(of: "/", with: "_")
        return rootURL.appendingPathComponent("thread-\(safeID).json")
    }

    private func messageIndexFileURL(_ threadID: String) -> URL {
        let safeID = threadID.replacingOccurrences(of: "/", with: "_")
        return rootURL.appendingPathComponent("message-index-\(safeID).json")
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
