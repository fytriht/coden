import XCTest
@testable import CodexStatusMonitor

@MainActor
final class StatusStoreTests: XCTestCase {
    func testSingleSessionStateTransitions() {
        let store = StatusStore()

        store.apply(event("codex/event/task_started", conversationId: "a"))
        XCTAssertEqual(store.aggregateState, .running)

        store.apply(event("codex/event/exec_approval_request", conversationId: "a", requestType: "exec"))
        XCTAssertEqual(store.aggregateState, .waiting)

        store.apply(event("codex/event/task_complete", conversationId: "a"))
        XCTAssertEqual(store.aggregateState, .idle)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testMultiSessionAggregationPrefersWaiting() {
        let store = StatusStore()

        store.apply(event("codex/event/task_started", conversationId: "a"))
        store.apply(event("codex/event/task_started", conversationId: "b"))
        XCTAssertEqual(store.aggregateState, .running)

        store.apply(event("codex/event/request_user_input", conversationId: "b", requestType: "userInput"))
        XCTAssertEqual(store.aggregateState, .waiting)

        store.apply(event("codex/event/task_complete", conversationId: "b"))
        XCTAssertEqual(store.aggregateState, .running)
    }

    func testTaskStatusInputRequiredMapsToWaiting() {
        let store = StatusStore()

        store.apply(event("notifications/tasks/status", conversationId: "task-1", status: "working"))
        XCTAssertEqual(store.aggregateState, .running)

        store.apply(event("notifications/tasks/status", conversationId: "task-1", status: "input_required"))
        XCTAssertEqual(store.aggregateState, .waiting)

        store.reset()
        XCTAssertEqual(store.aggregateState, .idle)
        XCTAssertTrue(store.recentEvents.isEmpty)
    }

    func testCurrentExtensionEventNamesDriveState() {
        let store = StatusStore()
        var completed = false
        store.onTurnCompleted = { _ in completed = true }

        store.apply(event("item/agentMessage/delta", conversationId: "a"))
        XCTAssertEqual(store.aggregateState, .running)

        store.apply(event("item/started", conversationId: "a", requestType: "commandExecution", status: "inProgress"))
        XCTAssertEqual(store.aggregateState, .running)

        store.apply(event("item/completed", conversationId: "a", requestType: "agentMessage"))
        XCTAssertEqual(store.aggregateState, .idle)
        XCTAssertTrue(completed)
    }

    func testCommandCompletionKeepsTurnRunningWithoutCompletionCallback() {
        let store = StatusStore()
        var completed = false
        store.onTurnCompleted = { _ in completed = true }

        store.apply(event("item/started", conversationId: "a", requestType: "commandExecution", status: "inProgress"))
        XCTAssertEqual(store.aggregateState, .running)

        store.apply(event("item/completed", conversationId: "a", requestType: "commandExecution", status: "completed"))
        XCTAssertEqual(store.aggregateState, .running)
        XCTAssertFalse(completed)
    }

    func testReasoningCompletionKeepsTurnRunning() {
        let store = StatusStore()

        store.apply(event("item/started", conversationId: "a", requestType: "reasoning"))
        XCTAssertEqual(store.aggregateState, .running)

        store.apply(event("item/completed", conversationId: "a", requestType: "reasoning"))
        XCTAssertEqual(store.aggregateState, .running)
    }

    func testUserMessageCompletionDoesNotClearRunningTurn() {
        let store = StatusStore()

        store.apply(event("turn/started", conversationId: "a"))
        XCTAssertEqual(store.aggregateState, .running)

        store.apply(event("item/completed", conversationId: "a", requestType: "userMessage"))
        XCTAssertEqual(store.aggregateState, .running)
    }

    func testCompletionCallbackFires() {
        let store = StatusStore()
        var completed = false
        store.onTurnCompleted = { _ in completed = true }

        store.apply(event("codex/event/task_started", conversationId: "a"))
        store.apply(event("codex/event/task_complete", conversationId: "a"))

        XCTAssertTrue(completed)
    }

    private func event(
        _ type: String,
        conversationId: String?,
        requestType: String? = nil,
        status: String? = nil
    ) -> CodexStatusEvent {
        CodexStatusEvent(
            schemaVersion: 1,
            timestamp: ISO8601DateFormatter.codexStatusFormatter().string(from: Date()),
            extensionVersion: "26.429.30905",
            source: "test",
            eventType: type,
            conversationId: conversationId,
            requestId: nil,
            requestType: requestType,
            status: status
        )
    }
}
