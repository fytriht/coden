import Foundation
import OSLog

private let osLog = Logger(subsystem: "com.zhangzhi.CodexStatusMonitor", category: "app")

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "local.codex.status-monitor.logger", qos: .utility)
    private var fileHandle: FileHandle?
    private let maxSize: Int = 2 * 1024 * 1024  // 2 MB
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    func setup(logFile: URL) {
        queue.async { self.openFile(at: logFile) }
    }

    private func openFile(at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: url.path)
        fileHandle?.seekToEndOfFile()
        rotateIfNeeded(url: url)
    }

    private func rotateIfNeeded(url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxSize,
              let fh = fileHandle else { return }
        fh.seek(toFileOffset: UInt64(size / 2))
        let tail = fh.readDataToEndOfFile()
        fh.seek(toFileOffset: 0)
        fh.write(tail)
        fh.truncateFile(atOffset: UInt64(tail.count))
        fh.seekToEndOfFile()
    }

    func write(_ level: String, _ message: String) {
        // Write to unified logging (Console.app)
        switch level {
        case "WARN":  osLog.warning("\(message, privacy: .public)")
        case "ERROR": osLog.error("\(message, privacy: .public)")
        default:      osLog.info("\(message, privacy: .public)")
        }

        // Write to file
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            self.fileHandle?.write(data)
        }
    }
}

func log(_ message: String) { AppLogger.shared.write("INFO", message) }
func logWarn(_ message: String) { AppLogger.shared.write("WARN", message) }
func logError(_ message: String) { AppLogger.shared.write("ERROR", message) }
