import XCTest
@testable import CodexStatusMonitor
import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class EventSocketServerTests: XCTestCase {
    func testReceivesSingleEvent() throws {
        let sockURL = tmpSocketURL()
        let expectation = expectation(description: "server receives event")

        let server = EventSocketServer(socketURL: sockURL) { event in
            XCTAssertEqual(event.eventType, "item/agentMessage/delta")
            XCTAssertEqual(event.conversationId, "socket-test")
            expectation.fulfill()
        }
        server.start()
        defer { server.stop() }

        // Give server time to bind
        Thread.sleep(forTimeInterval: 0.05)

        let client = try connectClient(to: sockURL)
        defer { close(client) }
        writeJSON(event("item/agentMessage/delta", conversationId: "socket-test"), to: client)

        wait(for: [expectation], timeout: 2.0)
    }

    func testReceivesMultipleEventsFromSameClient() throws {
        let sockURL = tmpSocketURL()
        let collector = StringCollector()
        let expectation = expectation(description: "receives 3 events")
        expectation.expectedFulfillmentCount = 3

        let server = EventSocketServer(socketURL: sockURL) { event in
            collector.append(event.eventType)
            expectation.fulfill()
        }
        server.start()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let client = try connectClient(to: sockURL)
        defer { close(client) }
        for type in ["turn/started", "item/started", "turn/completed"] {
            writeJSON(event(type, conversationId: "multi-test"), to: client)
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(collector.items, ["turn/started", "item/started", "turn/completed"])
    }

    func testReceivesEventsFromMultipleClients() throws {
        let sockURL = tmpSocketURL()
        let expectation = expectation(description: "receives events from 2 clients")
        expectation.expectedFulfillmentCount = 2

        let server = EventSocketServer(socketURL: sockURL) { _ in
            expectation.fulfill()
        }
        server.start()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let client1 = try connectClient(to: sockURL)
        let client2 = try connectClient(to: sockURL)
        defer { close(client1); close(client2) }

        writeJSON(event("turn/started", conversationId: "conv-1"), to: client1)
        writeJSON(event("turn/started", conversationId: "conv-2"), to: client2)

        wait(for: [expectation], timeout: 2.0)
    }

    func testHandlesPartialLines() throws {
        let sockURL = tmpSocketURL()
        let expectation = expectation(description: "receives assembled event")

        let server = EventSocketServer(socketURL: sockURL) { event in
            XCTAssertEqual(event.eventType, "turn/completed")
            expectation.fulfill()
        }
        server.start()
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 0.05)

        let client = try connectClient(to: sockURL)
        defer { close(client) }

        let json = (String(data: try! JSONEncoder().encode(event("turn/completed", conversationId: "partial")), encoding: .utf8)! + "\n").data(using: .utf8)!
        // Send in two chunks
        let half = json.count / 2
        let chunk1 = json[..<half]
        let chunk2 = json[half...]
        _ = chunk1.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }
        Thread.sleep(forTimeInterval: 0.05)
        _ = chunk2.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Helpers

    private final class StringCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [String] = []
        var items: [String] { lock.withLock { _items } }
        func append(_ item: String) { lock.withLock { _items.append(item) } }
    }

    private func tmpSocketURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-test-\(UUID().uuidString).sock")
    }

    private func connectClient(to sockURL: URL, retries: Int = 20) throws -> Int32 {
        var lastErrno: Int32 = 0
        for attempt in 0..<retries {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.05) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw XCTSkip("socket() failed") }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let path = sockURL.path
            withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
                path.withCString { ptr.baseAddress?.copyMemory(from: $0, byteCount: strlen($0) + 1) }
            }
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return fd }
            lastErrno = errno
            close(fd)
        }
        throw XCTSkip("connect() failed after \(retries) retries: \(lastErrno)")
    }

    private func writeJSON(_ event: CodexStatusEvent, to fd: Int32) {
        let line = (String(data: try! JSONEncoder().encode(event), encoding: .utf8)! + "\n").data(using: .utf8)!
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
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
