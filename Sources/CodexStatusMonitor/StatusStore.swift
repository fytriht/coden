import Foundation

@MainActor
final class StatusStore {
    private(set) var sessions: [String: SessionSnapshot] = [:]
    private(set) var recentEvents: [CodexStatusEvent] = []

    var onChange: (() -> Void)?
    var onTurnCompleted: ((CodexStatusEvent) -> Void)?
    var onRunningStarted: ((String) -> Void)?

    var aggregateState: CodexSessionState {
        sessions.values.map(\.state).max() ?? .idle
    }

    func apply(_ event: CodexStatusEvent, notify: Bool = true) {
        recordRecent(event)

        guard let nextState = Self.state(for: event) else {
            onChange?()
            return
        }

        let conversationId = event.conversationId ?? event.requestId ?? "unknown"
        let prevState = sessions[conversationId]?.state
        if nextState == .idle {
            if let prev = prevState {
                log("Session \(conversationId): \(prev.rawValue) → idle")
            }
            sessions.removeValue(forKey: conversationId)
            if notify && Self.isCompletion(event) {
                log("Turn completed for conv=\(conversationId), scheduling notification")
                onTurnCompleted?(event)
            }
        } else {
            if prevState != nextState {
                let from = prevState?.rawValue ?? "idle"
                log("Session \(conversationId): \(from) → \(nextState.rawValue)")
            }
            sessions[conversationId] = SessionSnapshot(
                conversationId: conversationId,
                state: nextState,
                lastEventType: event.eventType,
                requestType: event.requestType,
                updatedAt: event.date
            )
            if nextState == .running {
                onRunningStarted?(conversationId)
            }
        }
        onChange?()
    }

    func reset() {
        log("StatusStore reset (cleared \(sessions.count) sessions)")
        sessions.removeAll()
        recentEvents.removeAll()
        onChange?()
    }

    func recordRecent(_ event: CodexStatusEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 20 {
            recentEvents.removeLast(recentEvents.count - 20)
        }
    }

    static func state(for event: CodexStatusEvent) -> CodexSessionState? {
        switch event.eventType {
        case "item/completed" where event.requestType == "userMessage":
            return nil
        case "codex/event/task_started",
             "turn/started",
             "item/started",
             "item/agentMessage/delta",
             "item/reasoning/textDelta",
             "item/reasoning/summaryTextDelta",
             "item/plan/delta":
            return .running
        case "codex/event/request_user_input",
             "codex/event/exec_approval_request",
             "codex/event/apply_patch_approval_request",
             "codex/event/elicitation_request",
             "codex-status-monitor/pending_request":
            return .waiting
        case "notifications/tasks/status":
            if event.status == "input_required" {
                return .waiting
            }
            if event.status == "working" {
                return .running
            }
            if ["completed", "failed", "cancelled"].contains(event.status ?? "") {
                return .idle
            }
            return nil
        case "item/completed" where event.requestType == "agentMessage",
             "codex/event/task_complete",
             "turn/completed",
             "codex/event/turn_aborted",
             "codex/event/error",
             "codex/event/stream_error":
            return .idle
        default:
            return nil
        }
    }

    static func isCompletion(_ event: CodexStatusEvent) -> Bool {
        event.eventType == "codex/event/task_complete"
            || event.eventType == "turn/completed"
            || (event.eventType == "item/completed" && event.requestType == "agentMessage")
            || (event.eventType == "notifications/tasks/status" && event.status == "completed")
    }
}
