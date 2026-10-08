import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import Xet

@Suite("Token Provider Tests")
struct TokenProviderTests {
    @Test func concurrentCallersShareOneRequest() async throws {
        try await withTokenFixture(delay: .milliseconds(200)) { provider, url, requests in
            async let first = provider.connectionInfo(for: url, hubToken: nil)
            async let second = provider.connectionInfo(for: url, hubToken: nil)
            async let third = provider.connectionInfo(for: url, hubToken: nil)
            let infos = try await [first, second, third]
            #expect(infos.allSatisfy { $0.accessToken == "fixture" })
            #expect(requests.value == 1)

            // A later call uses the cached token.
            _ = try await provider.connectionInfo(for: url, hubToken: nil)
            #expect(requests.value == 1)
        }
    }

    @Test func canceledCallerStopsWaitingWhileTheRequestRetries() async throws {
        let policy = RetryPolicy(maxRetries: 5, baseDelay: 60, maxDelay: 60)
        try await withTokenFixture(fails: true, retryPolicy: policy) { provider, url, requests in
            let task = Task { try await provider.connectionInfo(for: url, hubToken: nil) }
            try await waitUntil { requests.value == 1 }

            let clock = ContinuousClock()
            let start = clock.now
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(clock.now - start < .seconds(5))

            // The request was canceled during its wait, so it isn't retried.
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(requests.value == 1)
        }
    }

    @Test func remainingCallerGetsTheResultAfterAnotherIsCanceled() async throws {
        try await withTokenFixture(delay: .milliseconds(500)) { provider, url, requests in
            let canceled = Task { try await provider.connectionInfo(for: url, hubToken: nil) }
            let remaining = Task { try await provider.connectionInfo(for: url, hubToken: nil) }
            try await waitUntil { requests.value == 1 }

            canceled.cancel()
            await #expect(throws: CancellationError.self) { try await canceled.value }
            let info = try await remaining.value
            #expect(info.accessToken == "fixture")
            #expect(requests.value == 1)
        }
    }

    @Test func callAfterEveryCallerCanceledStartsANewRequest() async throws {
        try await withTokenFixture(delay: .milliseconds(300)) { provider, url, requests in
            let canceled = Task { try await provider.connectionInfo(for: url, hubToken: nil) }
            try await waitUntil { requests.value == 1 }
            canceled.cancel()
            await #expect(throws: CancellationError.self) { try await canceled.value }

            let info = try await provider.connectionInfo(for: url, hubToken: nil)
            #expect(info.accessToken == "fixture")
            #expect(requests.value == 2)
        }
    }

    /// Waits up to 5 seconds for a condition to become true.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(condition())
    }
}

private final class TokenRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// Answers token requests after a delay, with a token or with HTTP 503.
private final class TokenFixtureHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let delay: TimeAmount
    private let fails: Bool
    private let requests: TokenRequestCounter

    init(delay: TimeAmount, fails: Bool, requests: TokenRequestCounter) {
        self.delay = delay
        self.fails = fails
        self.requests = requests
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head = unwrapInboundIn(data) else { return }
        requests.increment()
        let body =
            fails
            ? Data()
            : Data(#"{"accessToken":"fixture","exp":4102444800,"casUrl":"http://127.0.0.1:1"}"#.utf8)
        let head = HTTPResponseHead(
            version: .http1_1,
            status: fails ? .serviceUnavailable : .ok,
            headers: HTTPHeaders([("Content-Length", "\(body.count)")])
        )
        let response = NIOLoopBound((context, head, body), eventLoop: context.eventLoop)
        context.eventLoop.scheduleTask(in: delay) {
            let (context, head, body) = response.value
            context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
        }
    }
}

private func withTokenFixture(
    delay: TimeAmount = .nanoseconds(0),
    fails: Bool = false,
    retryPolicy: RetryPolicy = RetryPolicy(maxRetries: 0),
    _ body: (XetDownloader.TokenProvider, URL, TokenRequestCounter) async throws -> Void
) async throws {
    let requests = TokenRequestCounter()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel = try await ServerBootstrap(group: group)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(TokenFixtureHandler(delay: delay, fails: fails, requests: requests))
            }
        }
        .bind(host: "127.0.0.1", port: 0).get()
    let provider = XetDownloader.TokenProvider(retryPolicy: retryPolicy)
    let url = URL(string: "http://127.0.0.1:\(channel.localAddress!.port!)/token")!
    do {
        try await body(provider, url, requests)
        try await channel.close()
        try await group.shutdownGracefully()
    } catch {
        try? await channel.close()
        try? await group.shutdownGracefully()
        throw error
    }
}
