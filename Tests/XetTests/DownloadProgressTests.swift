import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import Xet

@Suite("Download Progress Tests")
struct DownloadProgressTests {
    private static let fileID = String(repeating: "a", count: 64)

    @Test func memoryDownloadCountsOutputAndReusesChunks() async throws {
        try await withFixture { downloader, requests in
            let progress = ProgressRecorder()
            let data = try await downloader.data(for: Self.fileID, progress: progress.record)

            #expect(data == Data("aaaaBBBBaaaa".utf8))
            #expect(progress.values.first == .init(completed: 4, total: 12))
            #expect(progress.values.last == .init(completed: 12, total: 12))
            #expect(progress.values.filter { $0.completed == $0.total }.count == 1)
            #expect(requests.count(for: "/a") == 1)
            #expect(requests.count(for: "/b") == 1)
            #expect(progress.values.map(\.completed) == progress.values.map(\.completed).sorted())
        }
    }

    @Test func diskDownloadCompletesAfterOutputIsAvailable() async throws {
        try await withFixture { downloader, requests in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let progress = ProgressRecorder()
            let written = try await downloader.download(Self.fileID, to: destination) { completed, total in
                progress.record(completed, total)
                if completed == total {
                    #expect((try? Data(contentsOf: destination)) == Data("aaaaBBBBaaaa".utf8))
                }
            }

            #expect(written == 12)
            #expect(progress.values.first == .init(completed: 4, total: 12))
            #expect(progress.values.last == .init(completed: written, total: written))
            #expect(progress.values.filter { $0.completed == $0.total }.count == 1)
            // One fetch serves both terms that reference xorb "a".
            #expect(requests.count(for: "/a") == 1)
        }
    }

    @Test func diskDownloadWritesTermsOutOfOrder() async throws {
        try await withFixture(
            hashes: ["b", "a"],
            delayB: .milliseconds(250),
            maxConcurrentFetches: 2
        ) { downloader, requests in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let progress = ProgressRecorder()
            let written = try await downloader.download(Self.fileID, to: destination) { completed, total in
                if progress.values.isEmpty {
                    // The second term is on disk before the first term's response arrives.
                    #expect(requests.responseCount(for: "/b") == 0)
                }
                progress.record(completed, total)
            }

            #expect(written == 8)
            #expect(progress.values.first == .init(completed: 4, total: 8))
            #expect(progress.values.last == .init(completed: 8, total: 8))
            let fileData = try Data(contentsOf: destination)
            #expect(fileData == Data("BBBBaaaa".utf8))
            #expect(try await downloader.data(for: Self.fileID) == fileData)
        }
    }

    @Test func partialDownloadExcludesSkippedAndTruncatedBytes() async throws {
        try await withFixture(offset: 2) { downloader, _ in
            let progress = ProgressRecorder()
            let data = try await downloader.data(for: Self.fileID, byteRange: 2 ..< 8, progress: progress.record)

            #expect(data == Data("aaBBBB".utf8))
            #expect(progress.values.first == .init(completed: 2, total: 6))
            #expect(progress.values.last == .init(completed: 6, total: 6))
        }
    }

    @Test func partialDiskDownloadExcludesSkippedAndTruncatedBytes() async throws {
        try await withFixture(offset: 2) { downloader, requests in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let progress = ProgressRecorder()
            let written = try await downloader.download(
                Self.fileID,
                byteRange: 2 ..< 8,
                to: destination,
                progress: progress.record
            )

            #expect(written == 6)
            #expect(try Data(contentsOf: destination) == Data("aaBBBB".utf8))
            #expect(progress.values.first == .init(completed: 2, total: 6))
            #expect(progress.values.last == .init(completed: 6, total: 6))
            #expect(requests.count(for: "/a") == 1)
        }
    }

    @Test func shortAndEmptyDownloadsComplete() async throws {
        try await withFixture { downloader, requests in
            let shortProgress = ProgressRecorder()
            let data = try await downloader.data(for: Self.fileID, byteRange: 0 ..< 1, progress: shortProgress.record)
            #expect(data == Data("a".utf8))
            #expect(shortProgress.values == [.init(completed: 1, total: 1)])

            let requestCount = requests.total
            let emptyProgress = ProgressRecorder()
            let empty = try await downloader.data(for: Self.fileID, byteRange: 5 ..< 5, progress: emptyProgress.record)
            #expect(empty.isEmpty)
            #expect(emptyProgress.values == [.init(completed: 0, total: 0)])

            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let written = try await downloader.download(
                Self.fileID,
                byteRange: 5 ..< 5,
                to: destination,
                progress: emptyProgress.record
            )
            #expect(written == 0)
            #expect(try Data(contentsOf: destination).isEmpty)
            #expect(emptyProgress.values.count == 2)
            #expect(requests.total == requestCount)
        }
    }

    @Test func emptyReconstructionCompletes() async throws {
        try await withFixture(hashes: []) { downloader, _ in
            let progress = ProgressRecorder()
            let data = try await downloader.data(for: Self.fileID, progress: progress.record)
            #expect(data.isEmpty)
            #expect(progress.values == [.init(completed: 0, total: 0)])
        }
    }

    @Test func invalidOutputLengthDoesNotReportCompletion() async throws {
        try await withFixture(unpackedLength: 8) { downloader, _ in
            let progress = ProgressRecorder()
            await #expect(throws: XetDownloaderError.self) {
                _ = try await downloader.data(for: Self.fileID, progress: progress.record)
            }
            #expect(progress.values.isEmpty)
        }
    }

    @Test func rangeBeyondEndReportsActualOutputSize() async throws {
        try await withFixture { downloader, _ in
            let progress = ProgressRecorder()
            let data = try await downloader.data(
                for: Self.fileID,
                byteRange: 0 ..< UInt64.max,
                progress: progress.record
            )
            #expect(data.count == 12)
            #expect(progress.values.last == .init(completed: 12, total: 12))
        }
    }

    @Test func failureAndRetryHaveIndependentCounts() async throws {
        try await withFixture(failFirstB: true) { downloader, _ in
            let failedProgress = ProgressRecorder()
            await #expect(throws: XetDownloaderError.self) {
                _ = try await downloader.data(for: Self.fileID, progress: failedProgress.record)
            }
            #expect(failedProgress.values == [.init(completed: 4, total: 12)])

            let retryProgress = ProgressRecorder()
            let data = try await downloader.data(for: Self.fileID, progress: retryProgress.record)
            #expect(data.count == 12)
            #expect(retryProgress.values.first == .init(completed: 4, total: 12))
            #expect(retryProgress.values.last == .init(completed: 12, total: 12))
            #expect(failedProgress.values.count == 1)
        }
    }

    @Test func cancellationDoesNotComplete() async throws {
        try await withFixture { downloader, _ in
            let progress = ProgressRecorder()
            let task = Task {
                try await downloader.data(for: Self.fileID) { completed, total in
                    progress.record(completed, total)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(progress.values == [.init(completed: 4, total: 12)])
        }
    }

    @Test func slowTransferReportsMoreThanOneIntermediateUpdate() async throws {
        try await withFixture(delayB: .milliseconds(250)) { downloader, _ in
            let progress = ProgressRecorder()
            _ = try await downloader.data(for: Self.fileID, progress: progress.record)
            #expect(
                progress.values == [
                    .init(completed: 4, total: 12),
                    .init(completed: 8, total: 12),
                    .init(completed: 12, total: 12),
                ]
            )
        }
    }

    @Test func largeSingleTermInMemoryReportsOnlyCompletion() async throws {
        let xorb = StreamedXorbFixture()
        try await withFixture(
            hashes: ["a"],
            unpackedLength: UInt32(xorb.output.count),
            streamedXorb: xorb
        ) { downloader, requests in
            let progress = ProgressRecorder()
            let output = try await downloader.data(for: Self.fileID) { completed, total in
                // Decoded chunks do not count until the complete term is written.
                #expect(requests.sentChunks == xorb.chunks.count)
                progress.record(completed, total)
            }

            #expect(output == xorb.output)
            #expect(requests.count(for: "/a") == 1)
            #expect(requests.sentChunks == 128)
            let expectedBytes: Int64 = 8 * 1024 * 1024
            #expect(progress.values == [.init(completed: expectedBytes, total: expectedBytes)])
        }
    }

    @Test func largeSingleTermOnDiskReportsChunksAsTheyArrive() async throws {
        let xorb = StreamedXorbFixture()
        try await withFixture(
            hashes: ["a"],
            unpackedLength: UInt32(xorb.output.count),
            streamedXorb: xorb
        ) { downloader, requests in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let progress = ProgressRecorder()
            let chunksSentAtFirstUpdate = Counter()
            let written = try await downloader.download(Self.fileID, to: destination) { completed, total in
                if progress.values.isEmpty {
                    chunksSentAtFirstUpdate.value = requests.sentChunks
                }
                progress.record(completed, total)
            }

            #expect(written == Int64(xorb.output.count))
            #expect(try Data(contentsOf: destination) == xorb.output)
            #expect(requests.count(for: "/a") == 1)
            // The first update arrives while the term is still downloading.
            #expect(chunksSentAtFirstUpdate.value < xorb.chunks.count)
            #expect(progress.values.first?.completed ?? 0 > 0)
            // The response spans more than six throttle intervals.
            #expect(progress.values.count > 3)
            #expect(progress.values.map(\.completed) == progress.values.map(\.completed).sorted())
            #expect(progress.values.allSatisfy { $0.total == Int64(xorb.output.count) })
            #expect(progress.values.filter { $0.completed == $0.total }.count == 1)
            #expect(progress.values.last?.completed == Int64(xorb.output.count))
        }
    }

    @Test(arguments: [false, true])
    func termsCoveringPartsOfOneFetchWriteInTermOrder(writeToDisk: Bool) async throws {
        let xorb = StreamedXorbFixture()
        // Two terms share one fetch and appear in the file in reverse chunk order.
        let termRanges = [64 ..< 128, 0 ..< 64]
        try await withFixture(streamedXorb: xorb, termRanges: termRanges) { downloader, requests in
            let output: Data
            if writeToDisk {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: destination) }
                let written = try await downloader.download(Self.fileID, to: destination)
                #expect(written == Int64(xorb.output.count))
                output = try Data(contentsOf: destination)
            } else {
                output = try await downloader.data(for: Self.fileID)
            }

            let half = xorb.output.count / 2
            #expect(output == xorb.output[half...] + xorb.output[..<half])
            #expect(requests.count(for: "/a") == 1)
        }
    }

    @Test func cancellationWhileWaitingForFetchDoesNotComplete() async throws {
        try await withFixture(delayB: .seconds(2)) { downloader, requests in
            let progress = ProgressRecorder()
            let task = Task {
                try await downloader.data(for: Self.fileID, progress: progress.record)
            }
            defer { task.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while requests.count(for: "/b") == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(requests.count(for: "/b") == 1)
            task.cancel()
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(progress.values == [.init(completed: 4, total: 12)])
        }
    }

    @Test func diskFailureDoesNotComplete() async throws {
        try await withFixture(failFirstB: true) { downloader, _ in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let progress = ProgressRecorder()
            await #expect(throws: XetDownloaderError.self) {
                try await downloader.download(Self.fileID, to: destination, progress: progress.record)
            }
            #expect(progress.values == [.init(completed: 4, total: 12)])
            // The file holds the terms written before the failure and nothing from "b".
            let data = try Data(contentsOf: destination)
            #expect(data.prefix(4) == Data("aaaa".utf8))
            #expect(data.count <= 12)
            #expect(!data.contains(UInt8(ascii: "B")))
        }
    }

    @Test func concurrentDownloadsKeepSeparateCounts() async throws {
        try await withFixture { downloader, _ in
            let full = ProgressRecorder()
            let partial = ProgressRecorder()
            async let data = downloader.data(for: Self.fileID, progress: full.record)
            async let range = downloader.data(for: Self.fileID, byteRange: 0 ..< 6, progress: partial.record)
            let (fullData, partialData) = try await (data, range)
            #expect(fullData.count == 12)
            #expect(partialData.count == 6)
            #expect(full.values.allSatisfy { $0.total == 12 })
            #expect(partial.values.allSatisfy { $0.total == 6 })
            #expect(full.values.last?.completed == 12)
            #expect(partial.values.last?.completed == 6)
        }
    }

    @Test func fastCachedTermsLimitCallbackFrequency() async throws {
        try await withFixture(hashes: Array(repeating: "a", count: 500)) { downloader, requests in
            let progress = ProgressRecorder()
            let data = try await downloader.data(for: Self.fileID, progress: progress.record)
            #expect(data.count == 2000)
            #expect(requests.count(for: "/a") == 1)
            #expect(
                progress.values == [
                    .init(completed: 4, total: 2000),
                    .init(completed: 2000, total: 2000),
                ]
            )
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    struct Value: Equatable {
        let completed: Int64
        let total: Int64
    }

    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] { lock.withLock { storage } }

    func record(_ completed: Int64, _ total: Int64) {
        lock.withLock {
            storage.append(Value(completed: completed, total: total))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: Int] = [:]
    private var responses: [String: Int] = [:]
    private var chunkCount = 0

    var total: Int { lock.withLock { paths.values.reduce(0, +) } }
    var sentChunks: Int { lock.withLock { chunkCount } }
    func count(for path: String) -> Int { lock.withLock { paths[path, default: 0] } }
    func responseCount(for path: String) -> Int { lock.withLock { responses[path, default: 0] } }

    func recordChunk() {
        lock.withLock { chunkCount += 1 }
    }

    func record(_ path: String) -> Int {
        lock.withLock {
            paths[path, default: 0] += 1
            return paths[path, default: 0]
        }
    }

    func recordResponse(_ path: String) {
        lock.withLock { responses[path, default: 0] += 1 }
    }
}

/// An 8 MiB term containing 128 distinct, uncompressed 64 KiB chunks.
private struct StreamedXorbFixture: Sendable {
    let chunks: [Data]
    let output: Data

    var encodedByteCount: Int { chunks.reduce(0) { $0 + $1.count } }

    init() {
        var chunks: [Data] = []
        var output = Data()
        for index in 0 ..< 128 {
            let payload = Data(repeating: UInt8(index), count: 64 * 1024)
            // Both 24-bit length fields contain 65536, in little-endian order.
            chunks.append(Data([0, 0, 0, 1, 0, 0, 0, 1]) + payload)
            output.append(payload)
        }
        self.chunks = chunks
        self.output = output
    }
}

/// Serves token, reconstruction, and uncompressed xorb responses over loopback.
private final class FixtureHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let hashes: [String]
    private let offset: UInt64
    private let unpackedLength: UInt32
    private let failFirstB: Bool
    private let delayB: TimeAmount
    private let streamedXorb: StreamedXorbFixture?
    private let termRanges: [Range<Int>]?
    private let requests: RequestRecorder

    init(
        hashes: [String],
        offset: UInt64,
        unpackedLength: UInt32,
        failFirstB: Bool,
        delayB: TimeAmount,
        streamedXorb: StreamedXorbFixture?,
        termRanges: [Range<Int>]?,
        requests: RequestRecorder
    ) {
        self.hashes = hashes
        self.offset = offset
        self.unpackedLength = unpackedLength
        self.failFirstB = failFirstB
        self.delayB = delayB
        self.streamedXorb = streamedXorb
        self.termRanges = termRanges
        self.requests = requests
    }

    /// Terms for the reconstruction response.
    ///
    /// `termRanges` describes terms that cover parts of the streamed xorb;
    /// otherwise every term covers the whole fetch range.
    private var terms: [CASClient.ReconstructionResponse.Term] {
        if let termRanges, let streamedXorb {
            let chunkSize = streamedXorb.output.count / streamedXorb.chunks.count
            return termRanges.map { .init(hash: "a", unpackedLength: UInt32($0.count * chunkSize), range: $0) }
        }
        let chunkRange = 0 ..< (streamedXorb?.chunks.count ?? 1)
        return hashes.map { .init(hash: $0, unpackedLength: unpackedLength, range: chunkRange) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(let request) = unwrapInboundIn(data) else { return }
        let attempt = requests.record(request.uri)
        if request.uri == "/a", let streamedXorb {
            #expect(request.headers.first(name: "Range") == "bytes=0-\(streamedXorb.encodedByteCount - 1)")
            send(streamedXorb, context: context)
            return
        }
        let base = "http://127.0.0.1:\(context.channel.localAddress!.port!)"
        var status = HTTPResponseStatus.ok
        let body: Data
        if request.uri == "/token" {
            body = Data(
                """
                {"accessToken":"fixture","exp":4102444800,"casUrl":"\(base)"}
                """.utf8
            )
        } else if request.uri.hasPrefix("/v1/reconstructions/") {
            let chunkRange = 0 ..< (streamedXorb?.chunks.count ?? 1)
            let urlRange: ClosedRange<UInt64> = 0 ... UInt64((streamedXorb?.encodedByteCount ?? 12) - 1)
            let terms = self.terms
            let reconstruction = CASClient.ReconstructionResponse(
                offsetIntoFirstRange: offset,
                terms: terms,
                fetchInfo: Dictionary(
                    uniqueKeysWithValues: Set(terms.map(\.hash)).map {
                        ($0, [.init(url: "\(base)/\($0)", range: chunkRange, urlRange: urlRange)])
                    }
                )
            )
            body = try! JSONEncoder().encode(reconstruction)
        } else if request.uri == "/b", failFirstB, attempt == 1 {
            status = .internalServerError
            body = Data()
        } else if request.uri == "/a" || request.uri == "/b" {
            body = Data([0, 4, 0, 0, 0, 4, 0, 0]) + Data((request.uri == "/a" ? "aaaa" : "BBBB").utf8)
        } else {
            status = .notFound
            body = Data()
        }
        let head = HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: HTTPHeaders([("Content-Length", "\(body.count)")])
        )
        let response = NIOLoopBound((context, head, body), eventLoop: context.eventLoop)
        let requests = self.requests
        let path = request.uri
        context.eventLoop.scheduleTask(in: request.uri == "/b" ? delayB : .nanoseconds(0)) {
            let (context, head, body) = response.value
            requests.recordResponse(path)
            context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
        }
    }

    private func send(_ xorb: StreamedXorbFixture, context: ChannelHandlerContext) {
        let head = HTTPResponseHead(
            version: .http1_1,
            status: .partialContent,
            headers: HTTPHeaders([
                ("Content-Length", "\(xorb.encodedByteCount)"),
                ("Content-Range", "bytes 0-\(xorb.encodedByteCount - 1)/\(xorb.encodedByteCount)"),
            ])
        )
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let requests = self.requests
        for (index, chunk) in xorb.chunks.enumerated() {
            // Spread the response over more than six progress reporting intervals.
            context.eventLoop.scheduleTask(in: .milliseconds(Int64(index) * 5)) {
                let context = boundContext.value
                guard context.channel.isActive else { return }
                requests.recordChunk()
                context.writeAndFlush(
                    NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: chunk)))),
                    promise: nil
                )
                if index == xorb.chunks.count - 1 {
                    context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
                }
            }
        }
    }
}

private func withFixture(
    hashes: [String] = ["a", "b", "a"],
    offset: UInt64 = 0,
    unpackedLength: UInt32 = 4,
    failFirstB: Bool = false,
    delayB: TimeAmount = .nanoseconds(0),
    streamedXorb: StreamedXorbFixture? = nil,
    termRanges: [Range<Int>]? = nil,
    maxConcurrentFetches: Int = 1,
    _ body: (XetDownloader, RequestRecorder) async throws -> Void
) async throws {
    let requests = RequestRecorder()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel = try await ServerBootstrap(group: group)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(
                    FixtureHandler(
                        hashes: hashes,
                        offset: offset,
                        unpackedLength: unpackedLength,
                        failFirstB: failFirstB,
                        delayB: delayB,
                        streamedXorb: streamedXorb,
                        termRanges: termRanges,
                        requests: requests
                    )
                )
            }
        }
        .bind(host: "127.0.0.1", port: 0).get()
    var configuration = XetDownloader.Configuration.default
    configuration.allowsInsecureConnections = true
    configuration.enableMultipath = false
    configuration.poolSize = 1
    configuration.prewarmedConnections = 0
    configuration.maxConcurrentFetches = maxConcurrentFetches
    configuration.autoScaleFetchConcurrency = false
    let url = URL(string: "http://127.0.0.1:\(channel.localAddress!.port!)/token")!
    do {
        try await Xet.withDownloader(refreshURL: url, configuration: configuration) { downloader in
            try await body(downloader, requests)
        }
        try await channel.close()
        try await group.shutdownGracefully()
    } catch {
        try? await channel.close()
        try? await group.shutdownGracefully()
        throw error
    }
}
