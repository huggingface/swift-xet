import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// When to retry a failed request, and how long to wait first.
///
/// The defaults match xet-core:
/// up to 5 retries, each after a random wait of up to
/// 3, 9, 27, 81, and 243 seconds.
struct RetryPolicy: Sendable {
    /// Maximum number of retries after the first attempt.
    var maxRetries: Int = 5

    /// Longest wait before the first retry, in seconds.
    /// Each later retry can wait three times as long as the one before it.
    var baseDelay: TimeInterval = 3

    /// Longest wait before any retry, in seconds.
    var maxDelay: TimeInterval = 360

    /// Returns a random wait before a retry, in seconds.
    ///
    /// - Parameter retry: The number of the retry, starting at 1.
    func delay(beforeRetry retry: Int) -> TimeInterval {
        let bound = min(maxDelay, baseDelay * pow(3, Double(retry - 1)))
        return bound > 0 ? Double.random(in: 0 ... bound) : 0
    }
}

/// Runs an operation,
/// and runs it again after a wait each time it throws a retryable error,
/// up to the policy's limit.
///
/// Errors that aren't retryable, including `CancellationError`, are thrown right away.
/// Cancellation during a wait throws `CancellationError`.
func withRetries<T>(
    _ policy: RetryPolicy,
    _ operation: () async throws -> T
) async throws -> T {
    var retries = 0
    while true {
        do {
            return try await operation()
        } catch let error as XetDownloaderError where error.isRetryable && retries < policy.maxRetries {
            retries += 1
            let delay = policy.delay(beforeRetry: retries)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

extension XetDownloaderError {
    /// Whether a later attempt of the same request can succeed.
    ///
    /// Following the Xet protocol and xet-core,
    /// these errors are retryable:
    /// HTTP 408, 429, and 5xx responses other than 501,
    /// and network failures.
    ///
    /// Token and reconstruction requests use `URLSession`,
    /// so their failures are `URLError` values,
    /// and the ones in `permanentURLErrorCodes`,
    /// such as invalid URLs and certificate errors, aren't retried.
    /// Xorb fetches use AsyncHTTPClient,
    /// whose failures, including TLS and certificate errors, are all retried.
    /// xet-core also retries TLS failures, as connection errors.
    var isRetryable: Bool {
        switch code {
        case .transportFailed:
            guard let urlError = underlyingError as? URLError else {
                return true
            }
            return !Self.permanentURLErrorCodes.contains(urlError.code)
        case .tokenRequestFailed, .reconstructionRequestFailed, .fetchFailed:
            guard let statusCode else {
                return false
            }
            return statusCode == 408 || statusCode == 429
                || ((500 ..< 600).contains(statusCode) && statusCode != 501)
        default:
            return false
        }
    }

    /// `URLSession` failures that fail the same way on every attempt.
    private static let permanentURLErrorCodes: Set<URLError.Code> = [
        .badURL,
        .unsupportedURL,
        .userAuthenticationRequired,
        .appTransportSecurityRequiresSecureConnection,
        .serverCertificateHasBadDate,
        .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid,
        .clientCertificateRejected,
        .clientCertificateRequired,
    ]
}
