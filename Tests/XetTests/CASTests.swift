import Foundation
import Testing

@testable import Xet

typealias ReconstructionResponse = CASClient.ReconstructionResponse

@Suite("CAS Tests")
struct CASTests {

    // MARK: - ReconstructionResponse Codable

    @Test func reconstructionResponseDecodesFromJSON() throws {
        let json = """
            {
                "offset_into_first_range": 100,
                "terms": [
                    {
                        "hash": "abc123",
                        "unpacked_length": 1024,
                        "range": {"start": 0, "end": 5}
                    },
                    {
                        "hash": "def456",
                        "unpacked_length": 2048,
                        "range": {"start": 0, "end": 3}
                    }
                ],
                "fetch_info": {
                    "abc123": [
                        {
                            "url": "https://example.com/xorb1",
                            "range": {"start": 0, "end": 10},
                            "url_range": {"start": 0, "end": 999}
                        }
                    ],
                    "def456": [
                        {
                            "url": "https://example.com/xorb2",
                            "range": {"start": 0, "end": 5},
                            "url_range": {"start": 1000, "end": 1999}
                        }
                    ]
                }
            }
            """

        let response = try JSONDecoder().decode(
            ReconstructionResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.offsetIntoFirstRange == 100)
        #expect(response.terms.count == 2)

        let term0 = response.terms[0]
        #expect(term0.hash == "abc123")
        #expect(term0.unpackedLength == 1024)
        #expect(term0.range == 0 ..< 5)

        let term1 = response.terms[1]
        #expect(term1.hash == "def456")
        #expect(term1.unpackedLength == 2048)
        #expect(term1.range == 0 ..< 3)

        #expect(response.fetchInfo.count == 2)

        let fetchInfo0 = response.fetchInfo["abc123"]!.first!
        #expect(fetchInfo0.url == "https://example.com/xorb1")
        #expect(fetchInfo0.range == 0 ..< 10)
        #expect(fetchInfo0.urlRange == 0 ... 999)

        let fetchInfo1 = response.fetchInfo["def456"]!.first!
        #expect(fetchInfo1.url == "https://example.com/xorb2")
        #expect(fetchInfo1.range == 0 ..< 5)
        #expect(fetchInfo1.urlRange == 1000 ... 1999)
    }

    @Test func reconstructionResponseV2DecodesFromJSON() throws {
        let json = """
            {
                "offset_into_first_range": 0,
                "terms": [
                    {
                        "hash": "abc123",
                        "unpacked_length": 1024,
                        "range": {"start": 1, "end": 4}
                    }
                ],
                "xorbs": {
                    "abc123": [
                        {
                            "url": "https://example.com/xorb1?X-Xet-Signed-Range=bytes%3D0-99%2C500-999",
                            "ranges": [
                                {"chunks": {"start": 0, "end": 2}, "bytes": {"start": 0, "end": 99}},
                                {"chunks": {"start": 3, "end": 5}, "bytes": {"start": 500, "end": 999}}
                            ]
                        }
                    ]
                }
            }
            """

        let response = try JSONDecoder().decode(
            CASClient.ReconstructionResponseV2.self,
            from: Data(json.utf8)
        )

        #expect(response.offsetIntoFirstRange == 0)
        #expect(response.terms.count == 1)
        #expect(response.terms[0].range == 1 ..< 4)

        let fetch = try #require(response.xorbs["abc123"]?.first)
        #expect(fetch.url == "https://example.com/xorb1?X-Xet-Signed-Range=bytes%3D0-99%2C500-999")
        #expect(fetch.ranges.map(\.chunks) == [0 ..< 2, 3 ..< 5])
        #expect(fetch.ranges.map(\.bytes) == [0 ... 99, 500 ... 999])
    }

    @Test func reconstructionResponseV2ConvertsToOneFetchInfoPerRange() throws {
        let v2 = CASClient.ReconstructionResponseV2(
            offsetIntoFirstRange: 7,
            terms: [.init(hash: "hash1", unpackedLength: 512, range: 0 ..< 3)],
            xorbs: [
                "hash1": [
                    .init(
                        url: "https://cdn.example/a",
                        ranges: [
                            .init(chunks: 0 ..< 3, bytes: 0 ... 299),
                            .init(chunks: 5 ..< 6, bytes: 500 ... 599),
                        ]
                    ),
                    .init(url: "https://cdn.example/b", ranges: [.init(chunks: 8 ..< 9, bytes: 800 ... 899)]),
                ]
            ]
        )

        let response = ReconstructionResponse(v2)

        #expect(response.offsetIntoFirstRange == 7)
        #expect(response.terms.map(\.hash) == ["hash1"])
        let fetchInfo = try #require(response.fetchInfo["hash1"])
        #expect(fetchInfo.map(\.url) == ["https://cdn.example/a", "https://cdn.example/a", "https://cdn.example/b"])
        #expect(fetchInfo.map(\.range) == [0 ..< 3, 5 ..< 6, 8 ..< 9])
        #expect(fetchInfo.map(\.urlRangeHeaderValue) == ["bytes=0-299", "bytes=500-599", "bytes=800-899"])
    }

    @Test func reconstructionResponseEncodesToJSON() throws {
        let response = ReconstructionResponse(
            offsetIntoFirstRange: 50,
            terms: [
                .init(hash: "hash1", unpackedLength: 512, range: 0 ..< 3)
            ],
            fetchInfo: [
                "hash1": [
                    .init(url: "https://cdn.example/blob", range: 0 ..< 3, urlRange: 100 ... 500)
                ]
            ]
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ReconstructionResponse.self, from: data)

        #expect(decoded.offsetIntoFirstRange == response.offsetIntoFirstRange)
        #expect(decoded.terms.count == response.terms.count)
        #expect(decoded.terms[0].hash == response.terms[0].hash)
        #expect(decoded.terms[0].range == response.terms[0].range)
        #expect(decoded.fetchInfo["hash1"]!.first!.urlRange == 100 ... 500)
    }

    @Test func termDecodesSnakeCaseFields() throws {
        let json = """
            {
                "hash": "somehash",
                "unpacked_length": 4096,
                "range": {"start": 5, "end": 10}
            }
            """

        let term = try JSONDecoder().decode(
            ReconstructionResponse.Term.self,
            from: Data(json.utf8)
        )

        #expect(term.hash == "somehash")
        #expect(term.unpackedLength == 4096)
        #expect(term.range == 5 ..< 10)
    }

    @Test func fetchInfoDecodesNestedRanges() throws {
        let json = """
            {
                "url": "https://storage.example/file",
                "range": {"start": 0, "end": 100},
                "url_range": {"start": 1000, "end": 2000}
            }
            """

        let fetchInfo = try JSONDecoder().decode(
            ReconstructionResponse.FetchInfo.self,
            from: Data(json.utf8)
        )

        #expect(fetchInfo.url == "https://storage.example/file")
        #expect(fetchInfo.range == 0 ..< 100)
        #expect(fetchInfo.urlRange == 1000 ... 2000)
    }

    @Test func fetchInfoURLRangeHeaderValue() throws {
        let fetchInfo = ReconstructionResponse.FetchInfo(
            url: "https://example.com",
            range: 0 ..< 5,
            urlRange: 100 ... 500
        )

        #expect(fetchInfo.urlRangeHeaderValue == "bytes=100-500")
    }

    // MARK: - Edge Cases

    @Test func emptyTermsArray() throws {
        let json = """
            {
                "offset_into_first_range": 0,
                "terms": [],
                "fetch_info": {}
            }
            """

        let response = try JSONDecoder().decode(
            ReconstructionResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.offsetIntoFirstRange == 0)
        #expect(response.terms.isEmpty)
        #expect(response.fetchInfo.isEmpty)
    }

    @Test func multipleFetchInfosForSameHash() throws {
        let json = """
            {
                "offset_into_first_range": 0,
                "terms": [],
                "fetch_info": {
                    "hash1": [
                        {"url": "url1", "range": {"start": 0, "end": 5}, "url_range": {"start": 0, "end": 100}},
                        {"url": "url2", "range": {"start": 5, "end": 10}, "url_range": {"start": 100, "end": 200}}
                    ]
                }
            }
            """

        let response = try JSONDecoder().decode(
            ReconstructionResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.fetchInfo["hash1"]?.count == 2)
        #expect(response.fetchInfo["hash1"]?[0].url == "url1")
        #expect(response.fetchInfo["hash1"]?[1].url == "url2")
    }

    @Test func largeOffsetValue() throws {
        let json = """
            {
                "offset_into_first_range": 18446744073709551615,
                "terms": [],
                "fetch_info": {}
            }
            """

        let response = try JSONDecoder().decode(
            ReconstructionResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.offsetIntoFirstRange == UInt64.max)
    }

    @Test func rangeWithZeroLength() throws {
        let term = ReconstructionResponse.Term(
            hash: "empty",
            unpackedLength: 0,
            range: 5 ..< 5  // empty range
        )

        #expect(term.range.isEmpty)
        #expect(term.range.lowerBound == 5)
        #expect(term.range.upperBound == 5)
    }
}
