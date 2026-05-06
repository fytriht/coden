import Foundation

enum CodexStatusPaths {
    static var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexStatusMonitor", isDirectory: true)
    }

    static var eventsFile: URL {
        appSupportDirectory.appendingPathComponent("events.jsonl")
    }

    static var socketFile: URL {
        appSupportDirectory.appendingPathComponent("events.sock")
    }
}
