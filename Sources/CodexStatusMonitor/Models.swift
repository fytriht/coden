import Foundation

enum CodexSessionState: String, Codable, Comparable {
    case idle
    case running
    case waiting

    static func < (lhs: CodexSessionState, rhs: CodexSessionState) -> Bool {
        priority(lhs) < priority(rhs)
    }

    private static func priority(_ state: CodexSessionState) -> Int {
        switch state {
        case .idle: return 0
        case .running: return 1
        case .waiting: return 2
        }
    }
}

struct CodexStatusEvent: Codable, Equatable {
    let schemaVersion: Int
    let timestamp: String
    let extensionVersion: String?
    let source: String
    let eventType: String
    let conversationId: String?
    let requestId: String?
    let requestType: String?
    let status: String?

    var date: Date {
        ISO8601DateFormatter.codexStatusFormatter().date(from: timestamp) ?? Date()
    }
}

struct SessionSnapshot: Equatable {
    let conversationId: String
    var state: CodexSessionState
    var lastEventType: String
    var requestType: String?
    var updatedAt: Date
}

struct PatchStatus: Equatable {
    enum State: Equatable {
        case noExtensionFound
        case unsupported(version: String)
        case notInstalled(version: String, path: String)
        case installed(version: String, path: String)
        case error(String)
    }

    var state: State

    var title: String {
        switch state {
        case .noExtensionFound:
            return "Patch: no VSCode Codex extension"
        case .unsupported(let version):
            return "Patch: unsupported \(version)"
        case .notInstalled(let version, _):
            return "Patch: not installed \(version)"
        case .installed(let version, _):
            return "Patch: installed \(version)"
        case .error:
            return "Patch: error"
        }
    }
}

extension ISO8601DateFormatter {
    static func codexStatusFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
