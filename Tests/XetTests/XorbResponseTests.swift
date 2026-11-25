import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import Xet

@Suite("Xorb Response Tests")
struct XorbResponseTests {
    // Two LZ4 literal blocks. Each chunk occupies 13 encoded bytes and decodes to four bytes.
    private let headerAndToken: [UInt8] = [0, 5, 0, 0, 1, 4, 0, 0, 0x40]
    private let url = URL(string: "https://fixture.invalid/xorb")!

    @Test(arguments: [false, true])
    func shiftedPartialResponseFailsBeforeDeliveringAChunk(continuing: Bool) async throws {
        let xorb = headerAndToken + "AAAA".utf8 + headerAndToken + "BBBB".utf8
        let response = HTTPClientResponse(
            status: .partialContent,
            headers: ["Content-Range": "bytes 0-12/26"],
            body: .bytes(ByteBuffer(bytes: xorb[0 ... 12]))
        )
        try await Xet.withDownloader(refreshURL: url) { downloader in
            var output = Data()
            do {
                try await downloader.decodeXorbResponse(
                    response,
                    url: url,
                    requestedStart: 13,
                    continuing: continuing
                ) { _, chunk, _ in
                    output.append(contentsOf: chunk)
                }
                Issue.record("Accepted the first chunk for the second chunk's byte range")
            } catch let error as XetDownloaderError {
                #expect(error.code == .fetchFailed)
                #expect(error.statusCode == 206)
            }
            #expect(output.isEmpty)
        }
    }

    @Test(arguments: ["ByTeS 013-25/*", "bytes 13-25/26", nil] as [String?])
    func decodesPartialResponseAtEncodedOffset(contentRange: String?) async throws {
        var headers = HTTPHeaders()
        if let contentRange { headers.add(name: "Content-Range", value: contentRange) }
        let response = HTTPClientResponse(
            status: .partialContent,
            headers: headers,
            body: .bytes(ByteBuffer(bytes: headerAndToken + "BBBB".utf8))
        )
        try await Xet.withDownloader(refreshURL: url) { downloader in
            var output = Data()
            try await downloader.decodeXorbResponse(response, url: url, requestedStart: 13, continuing: true) {
                _,
                chunk,
                encodedLength in
                #expect(encodedLength == 13)
                output.append(contentsOf: chunk)
            }
            #expect(output == Data("BBBB".utf8))
        }
    }

    @Test func decodesFullObjectResponse() async throws {
        let response = HTTPClientResponse(body: .bytes(ByteBuffer(bytes: headerAndToken + "AAAA".utf8)))
        try await Xet.withDownloader(refreshURL: url) { downloader in
            var output = Data()
            try await downloader.decodeXorbResponse(response, url: url, requestedStart: 0, continuing: false) {
                _,
                chunk,
                _ in
                output.append(contentsOf: chunk)
            }
            #expect(output == Data("AAAA".utf8))
        }
    }
}
