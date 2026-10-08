import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import Xet

@Suite("Reconstruction Version Tests")
struct ReconstructionVersionTests {
    private static let fileID = String(repeating: "a", count: 64)

    @Test(arguments: [false, true])
    func v2FetchesEachRangeOfAURLSeparately(writeToDisk: Bool) async throws {
        try await withVersionFixture { downloader, requests in
            let data: Data
            if writeToDisk {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: destination) }
                try await downloader.download(Self.fileID, to: destination)
                data = try Data(contentsOf: destination)
            } else {
                data = try await downloader.data(for: Self.fileID)
            }

            #expect(data == Data("aaaacccc".utf8))
            #expect(requests.count(for: "/v2/reconstructions/\(Self.fileID)") == 1)
            #expect(requests.count(for: "/v1/reconstructions/\(Self.fileID)") == 0)
            #expect(requests.xorbRanges.sorted() == ["bytes=0-11", "bytes=24-35"])
        }
    }

    @Test(arguments: [404, 501])
    func fallsBackToV1WhenV2IsUnavailable(statusCode: Int) async throws {
        try await withVersionFixture(v2Status: HTTPResponseStatus(statusCode: statusCode)) { downloader, requests in
            let first = try await downloader.data(for: Self.fileID)
            #expect(first == Data("aaaacccc".utf8))
            #expect(requests.count(for: "/v2/reconstructions/\(Self.fileID)") == 1)
            #expect(requests.count(for: "/v1/reconstructions/\(Self.fileID)") == 1)

            // Later downloads go straight to version 1.
            let second = try await downloader.data(for: Self.fileID)
            #expect(second == Data("aaaacccc".utf8))
            #expect(requests.count(for: "/v2/reconstructions/\(Self.fileID)") == 1)
            #expect(requests.count(for: "/v1/reconstructions/\(Self.fileID)") == 2)
        }
    }

    @Test func missingFileThrowsAfterTryingBothVersions() async throws {
        try await withVersionFixture(fileExists: false) { downloader, requests in
            for attempt in 1 ... 2 {
                let error = await downloaderError {
                    _ = try await downloader.data(for: Self.fileID)
                }
                #expect(error?.code == .reconstructionRequestFailed)
                #expect(error?.statusCode == 404)
                // A failed fallback doesn't switch later requests to version 1.
                #expect(requests.count(for: "/v2/reconstructions/\(Self.fileID)") == attempt)
                #expect(requests.count(for: "/v1/reconstructions/\(Self.fileID)") == attempt)
            }
        }
    }

    @Test func otherV2ErrorsDontFallBack() async throws {
        try await withVersionFixture(v2Status: .internalServerError) { downloader, requests in
            let error = await downloaderError {
                _ = try await downloader.data(for: Self.fileID)
            }
            #expect(error?.code == .reconstructionRequestFailed)
            #expect(error?.statusCode == 500)
            // The first attempt and the fixture's 2 retries.
            #expect(requests.count(for: "/v2/reconstructions/\(Self.fileID)") == 3)
            #expect(requests.count(for: "/v1/reconstructions/\(Self.fileID)") == 0)
        }
    }

    /// Returns the `XetDownloaderError` that `body` throws,
    /// and records an issue if it throws another error or none.
    private func downloaderError(_ body: () async throws -> Void) async -> XetDownloaderError? {
        do {
            try await body()
            Issue.record("Expected a XetDownloaderError, but nothing was thrown")
        } catch let error as XetDownloaderError {
            return error
        } catch {
            Issue.record("Expected a XetDownloaderError, but \(error) was thrown")
        }
        return nil
    }
}

private final class VersionRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: Int] = [:]
    private var ranges: [String] = []

    var xorbRanges: [String] { lock.withLock { ranges } }
    func count(for path: String) -> Int { lock.withLock { paths[path, default: 0] } }

    func record(_ path: String, range: String?) {
        lock.withLock {
            paths[path, default: 0] += 1
            if path == "/xorb", let range {
                ranges.append(range)
            }
        }
    }
}

/// Serves a file made of chunks 0 and 2 of a three-chunk xorb.
///
/// Version 2 lists both byte ranges under one URL,
/// and version 1 lists a URL for each range.
/// The xorb endpoint rejects a range that its URL doesn't list,
/// like a presigned URL does.
private final class VersionFixtureHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Three uncompressed chunks, `aaaa`, `BBBB`, and `cccc`, 12 bytes each.
    private static let xorb = ["aaaa", "BBBB", "cccc"].reduce(into: Data()) { data, payload in
        data.append(Data([0, 4, 0, 0, 0, 4, 0, 0]) + Data(payload.utf8))
    }

    private let v2Status: HTTPResponseStatus?
    private let fileExists: Bool
    private let requests: VersionRequestRecorder

    init(v2Status: HTTPResponseStatus?, fileExists: Bool, requests: VersionRequestRecorder) {
        self.v2Status = v2Status
        self.fileExists = fileExists
        self.requests = requests
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(let request) = unwrapInboundIn(data) else { return }
        let components = URLComponents(string: request.uri)
        let path = components?.path ?? request.uri
        let range = request.headers.first(name: "Range")
        requests.record(path, range: range)

        let base = "http://127.0.0.1:\(context.channel.localAddress!.port!)"
        let terms: [CASClient.ReconstructionResponse.Term] = [
            .init(hash: "x", unpackedLength: 4, range: 0 ..< 1),
            .init(hash: "x", unpackedLength: 4, range: 2 ..< 3),
        ]
        var status = HTTPResponseStatus.ok
        var body = Data()
        if path == "/token" {
            body = Data(
                """
                {"accessToken":"fixture","exp":4102444800,"casUrl":"\(base)"}
                """.utf8
            )
        } else if path.hasPrefix("/v2/reconstructions/") {
            if !fileExists {
                status = .notFound
            } else if let v2Status {
                status = v2Status
            } else {
                let reconstruction = CASClient.ReconstructionResponseV2(
                    offsetIntoFirstRange: 0,
                    terms: terms,
                    xorbs: [
                        "x": [
                            .init(
                                url: "\(base)/xorb?signed=0-11,24-35",
                                ranges: [
                                    .init(chunks: 0 ..< 1, bytes: 0 ... 11),
                                    .init(chunks: 2 ..< 3, bytes: 24 ... 35),
                                ]
                            )
                        ]
                    ]
                )
                body = try! JSONEncoder().encode(reconstruction)
            }
        } else if path.hasPrefix("/v1/reconstructions/") {
            if !fileExists {
                status = .notFound
            } else {
                let reconstruction = CASClient.ReconstructionResponse(
                    offsetIntoFirstRange: 0,
                    terms: terms,
                    fetchInfo: [
                        "x": [
                            .init(url: "\(base)/xorb?signed=0-11", range: 0 ..< 1, urlRange: 0 ... 11),
                            .init(url: "\(base)/xorb?signed=24-35", range: 2 ..< 3, urlRange: 24 ... 35),
                        ]
                    ]
                )
                body = try! JSONEncoder().encode(reconstruction)
            }
        } else if path == "/xorb" {
            let signed = components?.queryItems?.first(where: { $0.name == "signed" })?.value ?? ""
            let requested = range.map { String($0.dropFirst("bytes=".count)) } ?? ""
            let bounds = requested.split(separator: "-").compactMap { Int($0) }
            if signed.split(separator: ",").contains(Substring(requested)), bounds.count == 2 {
                status = .partialContent
                body = Self.xorb.subdata(in: bounds[0] ..< (bounds[1] + 1))
            } else {
                status = .forbidden
            }
        } else {
            status = .notFound
        }

        let head = HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: HTTPHeaders([("Content-Length", "\(body.count)")])
        )
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
    }
}

private func withVersionFixture(
    v2Status: HTTPResponseStatus? = nil,
    fileExists: Bool = true,
    _ body: (XetDownloader, VersionRequestRecorder) async throws -> Void
) async throws {
    let requests = VersionRequestRecorder()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel = try await ServerBootstrap(group: group)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(
                    VersionFixtureHandler(v2Status: v2Status, fileExists: fileExists, requests: requests)
                )
            }
        }
        .bind(host: "127.0.0.1", port: 0).get()
    var configuration = XetDownloader.Configuration.default
    configuration.allowsInsecureConnections = true
    configuration.poolSize = 1
    configuration.prewarmedConnections = 0
    configuration.maxRetries = 2
    configuration.retryBaseDelay = 0.01
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
