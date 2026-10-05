import Foundation
import Testing

@testable import Xet

@Suite("XetDownloaderError Tests")
struct XetDownloaderErrorTests {
    @Test func codeMatchesInSwitchWithDefault() {
        let error = XetDownloaderError.invalidFileID("xyz")
        let matched: Bool
        switch error.code {
        case .invalidFileID:
            matched = true
        default:
            matched = false
        }
        #expect(matched)
        #expect(error.invalidValue == "xyz")
    }

    @Test func requestFailuresKeepStatusCodeAndBody() {
        let body = Data("denied".utf8)
        let error = XetDownloaderError.tokenRequestFailed(statusCode: 401, body: body)
        #expect(error.code == .tokenRequestFailed)
        #expect(error.statusCode == 401)
        #expect(error.responseBody == body)
        #expect(error.localizedDescription == "Token request failed with HTTP status 401.")
    }

    @Test func descriptionMatchesErrorDescription() {
        let url = URL(string: "http://example.com/xorb")!
        let error = XetDownloaderError.insecureURL(url)
        #expect(error.url == url)
        #expect(error.description == error.errorDescription)
        #expect(error.code.description == "insecureURL")
    }
}
