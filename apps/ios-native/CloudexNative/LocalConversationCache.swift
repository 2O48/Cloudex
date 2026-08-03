import Foundation

struct CachedThreadDetail: Codable {
    let threadID: String
    let detail: ThreadDetail
    let savedAt: Double
}

final class LocalConversationCache {
    static let shared = LocalConversationCache()

    private let rootURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        rootURL = base.appendingPathComponent("CloudexNative", isDirectory: true)
            .appendingPathComponent("ConversationCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        encoder.outputFormatting = [.sortedKeys]
    }

    func loadProjects() -> [CloudexProject]? {
        read([CloudexProject].self, from: rootURL.appendingPathComponent("projects.json"))
    }

    func saveProjects(_ projects: [CloudexProject]) {
        write(projects, to: rootURL.appendingPathComponent("projects.json"))
    }

    func loadThreadDetail(threadID: String) -> ThreadDetail? {
        read(CachedThreadDetail.self, from: threadFileURL(threadID)).map(\.detail)
    }

    func saveThreadDetail(_ detail: ThreadDetail, threadID: String) {
        write(CachedThreadDetail(threadID: threadID, detail: detail, savedAt: Date().timeIntervalSince1970),
              to: threadFileURL(threadID))
    }

    private func threadFileURL(_ threadID: String) -> URL {
        let safeID = threadID.replacingOccurrences(of: "/", with: "_")
        return rootURL.appendingPathComponent("thread-\(safeID).json")
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
