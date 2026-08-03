import Foundation

final class SSEClient: NSObject, URLSessionDataDelegate {
    var onOpen: (() -> Void)?
    var onEvent: ((SSEEvent) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var pendingData = Data()
    private var endpoint: URL?
    private var token = ""
    private var intentionallyStopped = true
    private var reconnectScheduled = false
    private var reportedStatusError: String?

    func start(url: URL, token: String) {
        stop()
        endpoint = url
        self.token = token
        intentionallyStopped = false
        connect()
    }

    func stop() {
        intentionallyStopped = true
        reconnectScheduled = false
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        pendingData.removeAll(keepingCapacity: false)
    }

    private func connect() {
        guard !intentionallyStopped, let endpoint else { return }
        pendingData.removeAll(keepingCapacity: true)
        reportedStatusError = nil
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: endpoint)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            reportedStatusError = "实时连接响应无效"
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            reportedStatusError = "实时连接已关闭 (\(http.statusCode))"
            completionHandler(.cancel)
            return
        }
        onOpen?()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pendingData.append(data)
        let separator = Data([0x0A, 0x0A])
        while let range = pendingData.range(of: separator) {
            let block = pendingData.subdata(in: pendingData.startIndex..<range.lowerBound)
            pendingData.removeSubrange(pendingData.startIndex..<range.upperBound)
            parse(block)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !intentionallyStopped else { return }
        let message = reportedStatusError ?? error?.localizedDescription ?? "实时连接已关闭"
        onDisconnect?(message)
        scheduleReconnect()
    }

    private func parse(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var eventID: String?
        var eventName = "message"
        var dataLines: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix(":") { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            if key == "id" { eventID = value }
            if key == "event" { eventName = value }
            if key == "data" { dataLines.append(value) }
        }
        guard !dataLines.isEmpty, let payload = dataLines.joined(separator: "\n").data(using: .utf8) else { return }
        onEvent?(SSEEvent(id: eventID, name: eventName, data: payload))
    }

    private func scheduleReconnect() {
        guard !intentionallyStopped, !reconnectScheduled else { return }
        reconnectScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.intentionallyStopped else { return }
            self.reconnectScheduled = false
            self.session?.invalidateAndCancel()
            self.session = nil
            self.task = nil
            self.connect()
        }
    }

    deinit { stop() }
}
