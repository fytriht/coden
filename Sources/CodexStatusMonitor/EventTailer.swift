import Foundation

final class EventTailer: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "local.codex.status-monitor.event-tailer")
    private var source: DispatchSourceTimer?
    private var offset: UInt64 = 0
    private var partial = Data()
    private let onEvent: @Sendable (CodexStatusEvent, Bool) -> Void

    init(fileURL: URL, onEvent: @escaping @Sendable (CodexStatusEvent, Bool) -> Void) {
        self.fileURL = fileURL
        self.onEvent = onEvent
    }

    func start() {
        queue.async {
            self.ensureFile()
            self.offset = self.currentFileSize()
            self.installTimer()
        }
    }

    func stop() {
        queue.async {
            self.source?.cancel()
            self.source = nil
        }
    }

    private func ensureFile() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    private func installTimer() {
        source?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            self?.readNewData(isReplay: false)
        }
        self.source = source
        source.resume()
    }

    private func currentFileSize() -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attributes?[.size] as? NSNumber {
            return size.uint64Value
        }
        return 0
    }

    private func readNewData(isReplay: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            offset = 0
            partial.removeAll()
            ensureFile()
            return
        }

        let size = currentFileSize()
        if size < offset {
            offset = 0
            partial.removeAll()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            process(data, isReplay: isReplay)
        } catch {
            return
        }
    }

    private func process(_ data: Data, isReplay: Bool) {
        partial.append(data)
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[..<newline]
            partial.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            if let event = try? JSONDecoder().decode(CodexStatusEvent.self, from: Data(line)) {
                onEvent(event, isReplay)
            }
        }
    }
}
