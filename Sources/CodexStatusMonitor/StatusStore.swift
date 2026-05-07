import Foundation

@MainActor
final class StatusStore {
    private enum SessionMode {
        case task
        case turn
    }

    private(set) var sessions: [String: SessionSnapshot] = [:]
    private(set) var recentEvents: [CodexStatusEvent] = []
    private var sessionModes: [String: SessionMode] = [:]

    var onChange: (() -> Void)?
    var onTurnCompleted: ((CodexStatusEvent) -> Void)?
    var onWaitingStarted: ((String) -> Void)?

    var aggregateState: CodexSessionState {
        sessions.values.map(\.state).max() ?? .idle
    }

    func apply(_ event: CodexStatusEvent, notify: Bool = true) {
        recordRecent(event)

        let conversationId = event.conversationId ?? event.requestId ?? "unknown"
        let prevState = sessions[conversationId]?.state
        let prevMode = sessionModes[conversationId]
        guard let effect = Self.effect(for: event, previousState: prevState, mode: prevMode) else {
            onChange?()
            return
        }

        let nextState = effect.state
        if nextState == .idle {
            if let prev = prevState {
                log("Session \(conversationId): \(prev.rawValue) → idle")
            }
            sessions.removeValue(forKey: conversationId)
            sessionModes.removeValue(forKey: conversationId)
            if notify && effect.notifiesCompletion {
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
            sessionModes[conversationId] = effect.mode ?? prevMode
            if nextState == .waiting && prevState != .waiting {
                onWaitingStarted?(conversationId)
            }
        }
        onChange?()
    }

    func reset() {
        log("StatusStore reset (cleared \(sessions.count) sessions)")
        sessions.removeAll()
        sessionModes.removeAll()
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
        effect(for: event, previousState: nil, mode: nil)?.state
    }

    static func state(for event: CodexStatusEvent, previousState: CodexSessionState?) -> CodexSessionState? {
        effect(for: event, previousState: previousState, mode: nil)?.state
    }

    private struct EventEffect {
        let state: CodexSessionState
        let mode: SessionMode?
        let notifiesCompletion: Bool
    }

    private static func effect(
        for event: CodexStatusEvent,
        previousState: CodexSessionState?,
        mode: SessionMode?
    ) -> EventEffect? {
        if isTaskStart(event) {
            return EventEffect(state: .running, mode: .task, notifiesCompletion: false)
        }
        if isWaitingStart(event) {
            return EventEffect(state: .waiting, mode: mode ?? .task, notifiesCompletion: false)
        }
        if isTaskEnd(event) {
            return EventEffect(state: .idle, mode: nil, notifiesCompletion: isCompletion(event))
        }
        if mode == .turn && isTurnCompletion(event) {
            return EventEffect(state: .idle, mode: nil, notifiesCompletion: true)
        }
        if previousState == .waiting && isResumeAfterWaiting(event) {
            return EventEffect(state: .running, mode: mode, notifiesCompletion: false)
        }
        if mode == nil && isFallbackTurnStart(event) {
            return EventEffect(state: .running, mode: .turn, notifiesCompletion: false)
        }
        return nil
    }

    static func isCompletion(_ event: CodexStatusEvent) -> Bool {
        event.eventType == "codex/event/task_complete"
            || (event.eventType == "notifications/tasks/status" && event.status == "completed")
    }

    static func isTaskStart(_ event: CodexStatusEvent) -> Bool {
        event.eventType == "codex/event/task_started"
            || (event.eventType == "notifications/tasks/status" && event.status == "working")
    }

    static func isTaskEnd(_ event: CodexStatusEvent) -> Bool {
        isCompletion(event)
            || event.eventType == "codex/event/turn_aborted"
            || event.eventType == "codex/event/error"
            || event.eventType == "codex/event/stream_error"
            || (event.eventType == "notifications/tasks/status" && ["failed", "cancelled"].contains(event.status ?? ""))
    }

    static func isWaitingStart(_ event: CodexStatusEvent) -> Bool {
        event.eventType == "codex/event/request_user_input"
            || event.eventType == "codex/event/exec_approval_request"
            || event.eventType == "codex/event/apply_patch_approval_request"
            || event.eventType == "codex/event/elicitation_request"
            || event.eventType == "codex-status-monitor/pending_request"
            || (event.eventType == "notifications/tasks/status" && event.status == "input_required")
    }

    static func isResumeAfterWaiting(_ event: CodexStatusEvent) -> Bool {
        event.eventType == "item/started"
            || event.eventType == "item/agentMessage/delta"
            || event.eventType == "item/reasoning/textDelta"
            || event.eventType == "item/reasoning/summaryTextDelta"
            || event.eventType == "item/plan/delta"
    }

    static func isFallbackTurnStart(_ event: CodexStatusEvent) -> Bool {
        event.eventType == "turn/started"
            || event.eventType == "item/agentMessage/delta"
            || event.eventType == "item/reasoning/textDelta"
            || event.eventType == "item/reasoning/summaryTextDelta"
            || event.eventType == "item/plan/delta"
            || (event.eventType == "item/started" && ["agentMessage", "reasoning", "plan"].contains(event.requestType ?? ""))
    }

    static func isTurnCompletion(_ event: CodexStatusEvent) -> Bool {
        event.eventType == "turn/completed"
    }
}
