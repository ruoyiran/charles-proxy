import XCTest
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import ProxyLabCore

final class ReplayIntegrationTests: XCTestCase {
    func testExplicitReplaySendsEditedBodyAndPersistsNewRecordWhileRecordingPaused() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(ReplayEchoHandler()) }
        }.bind(host: "127.0.0.1", port: 0).get()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let original = CapturedTransaction(request: .init(method: "POST", url: "http://example.com/old", body: Data("old".utf8)))
        try await store.save(original)
        let engine = ProxyEngine(store: store)
        await engine.setRecordingEnabled(false)
        let result = try await engine.replay(.init(method: "POST", url: "http://127.0.0.1:\(origin.localAddress!.port!)/edited",
                                                    headers: [.init(name: "Content-Length", value: "800")], body: Data("new body".utf8)), replayOf: original.id)
        await engine.stop(); try await origin.close().get(); try await group.shutdownGracefully()
        XCTAssertNotEqual(result.id, original.id)
        XCTAssertEqual(result.replayOf, original.id)
        XCTAssertEqual(result.response?.status, 200)
        XCTAssertEqual(result.response?.body, Data("POST /edited 8:new body".utf8))
        let records = try await store.list()
        XCTAssertEqual(records.count, 2)
        let unchanged = try await store.load(id: original.id)
        XCTAssertEqual(unchanged?.request.body, Data("old".utf8))
    }

    func testRecordingExcludeLeavesClientResponseWorking() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(ReplayEchoHandler()) }
        }.bind(host: "127.0.0.1", port: 0).get()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let proxy = ProxyEngine(store: store)
        await proxy.setCapturePolicy(.init(exclude: [.init(match: .init(host: "127.0.0.1"))]))
        let port = try await proxy.start(port: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--noproxy", "", "--max-time", "5", "--proxy", "http://127.0.0.1:\(port)",
                             "http://127.0.0.1:\(origin.localAddress!.port!)/excluded"]
        let output = Pipe(); process.standardOutput = output
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        let body = output.fileHandleForReading.readDataToEndOfFile()
        await proxy.save(CapturedTransaction(request: .init(method: "GET", url: "https://retained.com/a")))
        await proxy.stop()
        try await origin.close().get(); try await group.shutdownGracefully()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(body, Data("GET /excluded nil:".utf8))
        let records = try await store.list()
        XCTAssertEqual(records.map { $0.request.url }, ["https://retained.com/a"])
    }

    func testFocusMatchesBeforePageLimitAndDoesNotDeleteRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        try await store.save(CapturedTransaction(startedAt: Date(timeIntervalSince1970: 1), request: .init(method: "GET", url: "https://focus.example/a")))
        try await store.save(CapturedTransaction(startedAt: Date(timeIntervalSince1970: 2), request: .init(method: "GET", url: "https://noise.example/a")))
        let list = try await store.listSummaries(limit: 1, focus: .init(enabled: true, rules: [.init(match: .init(host: "focus.example"))]))
        XCTAssertEqual(list.first?.host, "focus.example")
        let all = try await store.list()
        XCTAssertEqual(all.count, 2)
    }

    func testDeletingLiveWebSocketDoesNotResurrectItsMessagesOrHandshake() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let messages = try WebSocketMessageStore(path: store.path)
        let engine = ProxyEngine(store: store)
        var handshake = CapturedTransaction(request: .init(method: "GET", url: "ws://example.com/socket"), response: .init(status: 101))
        let saved = await engine.beginWebSocket(handshake)
        XCTAssertTrue(saved)
        await engine.saveWebSocketMessage(.init(direction: .serverToClient, opcode: .text, payload: Data("before".utf8)), transactionID: handshake.id)
        try await engine.deleteTransaction(handshake.id)
        await engine.saveWebSocketMessage(.init(direction: .serverToClient, opcode: .text, payload: Data("after".utf8)), transactionID: handshake.id)
        handshake.endedAt = Date()
        await engine.finishWebSocket(handshake)
        await engine.stop()
        let list = try await messages.list(transactionID: handshake.id)
        let record = try await store.load(id: handshake.id)
        XCTAssertTrue(list.isEmpty)
        XCTAssertNil(record)
    }

    func testNewCaptureExclusionStopsMessagesOnExistingWebSocket() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(path: directory.appendingPathComponent("sessions.sqlite").path)
        let messageStore = try WebSocketMessageStore(path: store.path)
        let engine = ProxyEngine(store: store)
        let handshake = CapturedTransaction(request: .init(method: "GET", url: "ws://example.com/socket"), response: .init(status: 101))
        _ = await engine.beginWebSocket(handshake)
        await engine.saveWebSocketMessage(.init(direction: .serverToClient, opcode: .text, payload: Data("before".utf8)), transactionID: handshake.id)
        await engine.setCapturePolicy(.init(exclude: [.init(match: .init(host: "example.com"))]))
        await engine.saveWebSocketMessage(.init(direction: .serverToClient, opcode: .text, payload: Data("after".utf8)), transactionID: handshake.id)
        await engine.stop()
        let messages = try await messageStore.list(transactionID: handshake.id)
        XCTAssertEqual(messages.map(\.decodedText), ["before"])
    }
}

private final class ReplayEchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?
    private var data = Data()
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let value): head = value; self.data = Data()
        case .body(var buffer): self.data.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            let text = "\(head!.method.rawValue) \(head!.uri) \(head!.headers.first(name: "Content-Length") ?? "nil"):\(String(decoding: self.data, as: UTF8.self))"
            context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: ["Content-Length": String(text.utf8.count)]))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(.init(string: text)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
