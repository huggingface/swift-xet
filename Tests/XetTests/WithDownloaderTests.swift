import Foundation
import Testing

import Xet

@Suite("withDownloader Tests")
struct WithDownloaderTests {
    /// A non-Sendable type, like the state of a view model.
    private final class Counter {
        var value = 0
    }

    /// Compiles only if the closure runs in the caller's isolation.
    @MainActor
    @Test func closureRunsInCallerIsolation() async throws {
        let counter = Counter()
        let url = URL(string: "https://huggingface.co/api/models/example/xet-read-token/main")!
        let result = try await Xet.withDownloader(refreshURL: url) { _ in
            counter.value += 1
            // A new non-Sendable value can be returned to the caller.
            let snapshot = Counter()
            snapshot.value = counter.value
            return snapshot
        }
        #expect(result.value == 1)
        #expect(counter.value == 1)
    }

    @Test func configurationInitializerUsesDefaults() {
        let configuration = XetDownloader.Configuration()
        let defaults = XetDownloader.Configuration.default
        #expect(configuration.maxConcurrentFetches == defaults.maxConcurrentFetches)
        #expect(configuration.readTimeout == defaults.readTimeout)
        #expect(configuration.allowsInsecureConnections == defaults.allowsInsecureConnections)
    }
}
