import XCTest
@testable import CodexStatusMonitor

final class EventTailerTests: XCTestCase {
    func testPollsEventsAppendedAfterStart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-status-monitor-tailer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("events.jsonl")
        try Data().write(to: fileURL)

        let expectation = expectation(description: "tailer receives appended event")
        let tailer = EventTailer(fileURL: fileURL) { event, isReplay in
            XCTAssertFalse(isReplay)
            XCTAssertEqual(event.eventType, "item/agentMessage/delta")
            XCTAssertEqual(event.conversationId, "tailer-test")
            expectation.fulfill()
        }
        tailer.start()
        defer { tailer.stop() }

        append(event("item/agentMessage/delta", conversationId: "tailer-test"), to: fileURL)
        wait(for: [expectation], timeout: 2.0)
    }

    private func append(_ event: CodexStatusEvent, to fileURL: URL) {
        let data = (String(data: try! JSONEncoder().encode(event), encoding: .utf8)! + "\n").data(using: .utf8)!
        let handle = try! FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try! handle.write(contentsOf: data)
    }

    private func event(_ type: String, conversationId: String?) -> CodexStatusEvent {
        CodexStatusEvent(
            schemaVersion: 1,
            timestamp: ISO8601DateFormatter.codexStatusFormatter().string(from: Date()),
            extensionVersion: "test",
            source: "test",
            eventType: type,
            conversationId: conversationId,
            requestId: nil,
            requestType: nil,
            status: nil
        )
    }
}
