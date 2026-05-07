import Foundation

enum CodexStatusPaths {
    static var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexStatusMonitor", isDirectory: true)
    }

    static var socketFile: URL {
        appSupportDirectory.appendingPathComponent("events.sock")
    }

    static var logFile: URL {
        appSupportDirectory.appendingPathComponent("app.log")
    }

    static var patchConfigFile: URL {
        appSupportDirectory.appendingPathComponent("patch-config.json")
    }
}
