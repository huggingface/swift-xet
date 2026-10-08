import Foundation
import Testing

@testable import Xet

@Suite("Retry Tests")
struct RetryTests {
    @Test func defaultDelaysMatchXetCore() {
        let policy = RetryPolicy()
        #expect(policy.maxRetries == 5)
        for (retry, bound) in zip(1 ... 6, [3.0, 9, 27, 81, 243, 360]) {
            for _ in 0 ..< 100 {
                let delay = policy.delay(beforeRetry: retry)
                #expect(delay >= 0 && delay <= bound)
            }
        }
    }

    @Test(arguments: [408, 429, 500, 502, 503, 504])
    func retryableStatusCodes(statusCode: Int) {
        #expect(XetDownloaderError.tokenRequestFailed(statusCode: statusCode, body: Data()).isRetryable)
        #expect(XetDownloaderError.reconstructionRequestFailed(statusCode: statusCode, body: Data()).isRetryable)
        #expect(XetDownloaderError.fetchFailed(statusCode: statusCode, url: nil).isRetryable)
    }

    @Test(arguments: [400, 401, 403, 404, 416, 501])
    func nonRetryableStatusCodes(statusCode: Int) {
        #expect(!XetDownloaderError.tokenRequestFailed(statusCode: statusCode, body: Data()).isRetryable)
        #expect(!XetDownloaderError.reconstructionRequestFailed(statusCode: statusCode, body: Data()).isRetryable)
        #expect(!XetDownloaderError.fetchFailed(statusCode: statusCode, url: nil).isRetryable)
    }

    @Test func transportFailures() {
        #expect(XetDownloaderError.transportFailed(URLError(.timedOut), url: nil).isRetryable)
        #expect(XetDownloaderError.transportFailed(URLError(.networkConnectionLost), url: nil).isRetryable)
        #expect(XetDownloaderError.transportFailed(CocoaError(.fileReadUnknown), url: nil).isRetryable)
        #expect(!XetDownloaderError.transportFailed(URLError(.unsupportedURL), url: nil).isRetryable)
        #expect(!XetDownloaderError.transportFailed(URLError(.serverCertificateUntrusted), url: nil).isRetryable)
    }

    @Test func otherErrorsAreNotRetryable() {
        #expect(!XetDownloaderError.invalidReconstruction.isRetryable)
        #expect(!XetDownloaderError.invalidChunkData(XorbError.truncatedStream).isRetryable)
        #expect(!XetDownloaderError.fetchFailed(statusCode: nil, url: nil).isRetryable)
    }

    @Test func configurationSetsThePolicy() {
        var configuration = XetDownloader.Configuration()
        #expect(configuration.maxRetries == 5)
        #expect(configuration.retryBaseDelay == 3)
        configuration.maxRetries = -1
        configuration.retryBaseDelay = 0.5
        #expect(configuration.retryPolicy.maxRetries == 0)
        #expect(configuration.retryPolicy.baseDelay == 0.5)
        #expect(configuration.retryPolicy.maxDelay == 360)
    }

    @Test func withRetriesStopsAtTheLimit() async throws {
        let policy = RetryPolicy(maxRetries: 2, baseDelay: 0)
        var attempts = 0
        await #expect(throws: XetDownloaderError.self) {
            try await withRetries(policy) {
                attempts += 1
                throw XetDownloaderError.fetchFailed(statusCode: 503, url: nil)
            }
        }
        #expect(attempts == 3)
    }

    @Test func withRetriesThrowsOtherErrorsRightAway() async throws {
        let policy = RetryPolicy(maxRetries: 2, baseDelay: 0)
        var attempts = 0
        await #expect(throws: CancellationError.self) {
            try await withRetries(policy) {
                attempts += 1
                throw CancellationError()
            }
        }
        #expect(attempts == 1)
    }

    @Test func cancellationDuringAWaitThrowsCancellationError() async throws {
        let policy = RetryPolicy(maxRetries: 1, baseDelay: 60, maxDelay: 60)
        let task = Task {
            try await withRetries(policy) {
                throw XetDownloaderError.fetchFailed(statusCode: 503, url: nil)
            }
        }
        // The first attempt fails whether or not the task is canceled yet,
        // so the cancellation is seen during the wait.
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
