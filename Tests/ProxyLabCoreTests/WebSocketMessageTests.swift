import Foundation
import XCTest
import NIOCore
import NIOWebSocket
import GRDB
@testable import ProxyLabCore

final class WebSocketMessageTests: XCTestCase {
    func testSharedSessionStoresWaitForShortConcurrentDatabaseWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("sessions.sqlite").path
        let sessions = try SessionStore(path: path)
        let lock = try DatabaseQueue(path: path)
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = Task.detached {
            try lock.write { _ in acquired.signal(); release.wait() }
        }
        waitForFixtureLock(acquired)
        let releaser = Task.detached { try await Task.sleep(for: .milliseconds(100)); release.signal() }
        let messages = try WebSocketMessageStore(path: path)
        try await releaser.value
        try await holder.value
        let secondAcquired = DispatchSemaphore(value: 0)
        let secondRelease = DispatchSemaphore(value: 0)
        let secondHolder = Task.detached {
            try lock.write { _ in secondAcquired.signal(); secondRelease.wait() }
        }
        waitForFixtureLock(secondAcquired)
        let secondReleaser = Task.detached { try await Task.sleep(for: .milliseconds(100)); secondRelease.signal() }
        let transaction = CapturedTransaction(request: .init(method: "GET", url: "ws://example.com/socket"), response: .init(status: 101))
        try await sessions.save(transaction)
        try await secondReleaser.value
        try await secondHolder.value
        try await sessions.saveWebSocketMessage(.init(direction: .serverToClient, opcode: .text, payload: Data("saved".utf8)), transactionID: transaction.id)
        let recovered = try await messages.list(transactionID: transaction.id)
        XCTAssertEqual(recovered.map(\.decodedText), ["saved"])
    }

    // A continuation being captured independently would lose complete text and UTF-8 boundaries.
    func testFragmentsCaptureOneDecodedTextMessageWithInterleavedPing() throws {
        var capture = WebSocketMessageAssembler(direction: .clientToServer, captureLimit: 8)
        XCTAssertNil(try capture.receive(WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(bytes: [0xE4, 0xBD]))))
        let ping = try XCTUnwrap(capture.receive(WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer(string: "p"))))
        XCTAssertEqual(ping.opcode, .ping)
        let message = try XCTUnwrap(capture.receive(WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer(bytes: [0xA0, 0xE5, 0xA5, 0xBD]))))
        XCTAssertEqual(message.opcode, .text)
        XCTAssertEqual(message.decodedText, "你好")
        XCTAssertEqual(message.payloadLength, 6)
        XCTAssertFalse(message.isTruncated)
    }

    // Retaining all fragment payloads would allow unbounded capture memory.
    func testLargeFragmentedBinaryRetainsPrefixAndOriginalLength() throws {
        var capture = WebSocketMessageAssembler(direction: .serverToClient, captureLimit: 3)
        XCTAssertNil(try capture.receive(WebSocketFrame(fin: false, opcode: .binary, data: ByteBuffer(bytes: [0, 1]))))
        let message = try XCTUnwrap(capture.receive(WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer(bytes: [2, 3, 4]))))
        XCTAssertEqual(message.payload, Data([0, 1, 2]))
        XCTAssertEqual(message.payloadLength, 5)
        XCTAssertTrue(message.isTruncated)
        XCTAssertEqual(message.hexText, "00 01 02")
    }

    func testInvalidFragmentOrderingAndReservedBitsAreRejected() throws {
        var capture = WebSocketMessageAssembler(direction: .clientToServer)
        XCTAssertThrowsError(try capture.receive(WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer())))
        XCTAssertThrowsError(try capture.receive(WebSocketFrame(fin: true, rsv1: true, opcode: .text, data: ByteBuffer(string: "x"))))
        XCTAssertNil(try capture.receive(WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(string: "x"))))
        XCTAssertThrowsError(try capture.receive(WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer())))
    }

    func testMaskedPayloadCapturedUnmaskedAndControlFrameValidation() throws {
        var capture = WebSocketMessageAssembler(direction: .clientToServer)
        var payload = ByteBuffer(string: "hello")
        let key: WebSocketMaskingKey = [1, 2, 3, 4]
        payload.webSocketMask(key)
        let message = try XCTUnwrap(capture.receive(WebSocketFrame(fin: true, opcode: .text, maskKey: key, data: payload)))
        XCTAssertEqual(message.decodedText, "hello")
        XCTAssertThrowsError(try capture.receive(WebSocketFrame(fin: false, opcode: .ping, data: ByteBuffer())))
        XCTAssertThrowsError(try capture.receive(WebSocketFrame(fin: true, opcode: .pong, data: ByteBuffer(repeating: 0, count: 126))))
    }

    func testInvalidUTF8BeyondRetainedPrefixAndInvalidCloseCodeAreRejected() throws {
        var capture = WebSocketMessageAssembler(direction: .clientToServer, captureLimit: 1)
        XCTAssertNil(try capture.receive(WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(bytes: [0x61, 0xF0]))))
        XCTAssertThrowsError(try capture.receive(WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer(bytes: [0x80, 0x80, 0x80]))))
        var closeCapture = WebSocketMessageAssembler(direction: .serverToClient)
        XCTAssertThrowsError(try closeCapture.receive(WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer(bytes: [0x03, 0xED]))))
        XCTAssertThrowsError(try closeCapture.receive(WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer(bytes: [0x03]))))
    }

    func testRecentPageIncludesNewestMessagesInStableOrderAndReportsTotal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WebSocketMessageStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let connection = UUID()
        for text in ["old", "middle", "new"] {
            try await store.save(WebSocketMessage(direction: .serverToClient, opcode: .text, payload: Data(text.utf8)), transactionID: connection)
        }
        let page = try await store.recent(transactionID: connection, limit: 2, maxPayloadBytes: 100)
        XCTAssertEqual(page.messages.map(\.decodedText), ["middle", "new"])
        XCTAssertEqual(page.totalCount, 3)
        XCTAssertTrue(page.isLimited)
    }

    func testRecentPageCapsTotalPayloadAndKeepsNewestOversizedMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WebSocketMessageStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let connection = UUID()
        for text in ["old", "previous", "newest"] {
            try await store.save(WebSocketMessage(direction: .serverToClient, opcode: .text, payload: Data(text.utf8)), transactionID: connection)
        }
        let page = try await store.recent(transactionID: connection, limit: 200, maxPayloadBytes: 4)
        XCTAssertEqual(page.messages.count, 1)
        XCTAssertEqual(page.messages.first?.decodedText, "newe")
        XCTAssertEqual(page.messages.first?.payloadLength, 6)
        XCTAssertEqual(page.messages.first?.isTruncated, true)
        XCTAssertLessThanOrEqual(page.messages.reduce(0) { $0 + $1.payload.count }, 4)
        XCTAssertEqual(page.totalCount, 3)
        XCTAssertTrue(page.isLimited)
        let full = try await store.recent(transactionID: connection, limit: 200, maxPayloadBytes: 100)
        XCTAssertEqual(full.messages.map(\.decodedText), ["old", "previous", "newest"])
        XCTAssertFalse(full.isLimited)
    }

    func testRecentPageDoesNotSkipAnOlderMessageThatWouldExceedBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WebSocketMessageStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let connection = UUID()
        for text in ["a", "oversized", "last"] {
            try await store.save(WebSocketMessage(direction: .serverToClient, opcode: .text, payload: Data(text.utf8)), transactionID: connection)
        }
        let page = try await store.recent(transactionID: connection, limit: 200, maxPayloadBytes: 5)
        XCTAssertEqual(page.messages.map(\.decodedText), ["last"])
        XCTAssertEqual(page.totalCount, 3)
        XCTAssertTrue(page.isLimited)
    }

    func testPayloadPreviewCapsDecodedAndHexAllocation() throws {
        let message = WebSocketMessage(direction: .serverToClient, opcode: .text, payload: Data(repeating: 0x61, count: 300_000))
        let preview = message.previewPayload(maxBytes: 4)
        XCTAssertEqual(preview, Data("aaaa".utf8))
        XCTAssertEqual(message.decodedPreview(maxBytes: 4), "aaaa")
        XCTAssertEqual(message.hexPreview(maxBytes: 4), "61 61 61 61")
        XCTAssertEqual(message.previewPayload().count, 256 * 1_024)
        XCTAssertEqual(message.previewPayload(maxBytes: 1_000_000).count, 256 * 1_024)
        let unicode = WebSocketMessage(direction: .serverToClient, opcode: .text, payload: Data("你好".utf8))
        XCTAssertEqual(unicode.decodedPreview(maxBytes: 4), "你")
    }

    func testMessagesPersistByConnectionAndDeleteWithTransaction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("sessions.sqlite").path
        let first = UUID(), second = UUID()
        let store = try WebSocketMessageStore(path: path)
        let message = WebSocketMessage(direction: .clientToServer, opcode: .text, payload: Data("saved".utf8))
        try await store.save(message, transactionID: first)
        try await store.save(WebSocketMessage(direction: .serverToClient, opcode: .binary, payload: Data([0, 1])), transactionID: second)
        let reopened = try WebSocketMessageStore(path: path)
        let recovered = try await reopened.list(transactionID: first)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.decodedText, "saved")
        try await store.remove(transactionID: first)
        let removed = try await store.list(transactionID: first)
        let preserved = try await store.list(transactionID: second)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(preserved.count, 1)
        try await store.clear()
        let cleared = try await store.list(transactionID: second)
        XCTAssertTrue(cleared.isEmpty)
    }
}

private func waitForFixtureLock(_ semaphore: DispatchSemaphore) { semaphore.wait() }
