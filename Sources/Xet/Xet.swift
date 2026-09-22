import AsyncHTTPClient
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
#if canImport(NIOTransportServices)
    import NIOTransportServices
#endif

/// Namespace for Xet download helpers.
///
/// Use ``withDownloader(refreshURL:hubToken:configuration:_:)``
/// to create a downloader with a scoped lifetime,
///
/// ## Usage
///
/// Download a file to memory:
///
/// ```swift
/// let data = try await Xet.withDownloader(
///     refreshURL: tokenURL,
///     hubToken: "hf_..."
/// ) { downloader in
///     try await downloader.data(for: fileID)
/// }
/// ```
///
/// Download a file to disk:
///
/// ```swift
/// try await Xet.withDownloader(
///     refreshURL: tokenURL,
///     hubToken: "hf_..."
/// ) { downloader in
///     try await downloader.download(fileID, to: destinationURL)
/// }
/// ```
///
/// Both methods support partial downloads via the `byteRange` parameter.
/// The downloader handles chunk-level alignment automatically,
/// skipping bytes at the start and truncating at the end as needed.
public enum Xet {
    /// Creates a downloader for the duration of the closure, then shuts it down.
    public static func withDownloader<T>(
        refreshURL: URL,
        hubToken: String? = nil,
        configuration: XetDownloader.Configuration = .default,
        _ body: (XetDownloader) async throws -> T
    ) async throws -> T {
        let downloader = XetDownloader(
            refreshURL: refreshURL,
            hubToken: hubToken,
            configuration: configuration
        )
        do {
            let result = try await body(downloader)
            try await downloader.shutdown()
            return result
        } catch {
            try? await downloader.shutdown()
            throw error
        }
    }
}

/// Downloader for Hugging Face CAS files using the Xet protocol.
///
/// Use ``Xet/withDownloader(refreshURL:hubToken:configuration:_:)``
/// to create a downloader with a scoped lifetime.
/// If you instantiate directly,
/// call ``shutdown()`` when you are done to release HTTP client resources.
public final class XetDownloader: @unchecked Sendable {
    /// Hub token refresh endpoint for CAS credentials.
    private let refreshURL: URL

    /// Optional Hub token used to authenticate refresh requests.
    private let hubToken: String?

    /// Provides cached CAS access tokens with refresh coalescing.
    private let tokenProvider: TokenProvider

    /// Client for CAS reconstruction metadata requests.
    private let casClient: CASClient

    /// Pool of HTTP clients for xorb fetches.
    private let httpClientPool: HTTPClientPool

    /// Downloader configuration settings.
    private let configuration: Configuration

    /// Configuration for tuning downloader performance.
    public struct Configuration: Sendable {
        /// Maximum number of xorb fetches running at once. Defaults to 128.
        public var maxConcurrentFetches: Int = 128

        /// Maximum number of chunk decode operations running at once.
        /// Defaults to the active processor count.
        public var maxConcurrentDecodes: Int = max(
            1,
            ProcessInfo.processInfo.activeProcessorCount
        )

        /// Maximum number of received network buffers waiting to be decoded,
        /// per fetch. Defaults to 16.
        public var maxInflightBuffers: Int = 16

        /// Maximum concurrent HTTP/1 connections per host. Defaults to 24.
        public var connectionsPerHost: Int = 24

        /// Number of prewarmed HTTP/1 connections per host. Defaults to 16.
        public var prewarmedConnections: Int = 16

        /// Number of HTTP clients in the pool. Defaults to 4.
        public var poolSize: Int = 4

        /// Connection timeout for HTTP requests, in seconds. Defaults to 60.
        public var connectTimeout: TimeInterval = 60

        /// Read timeout for HTTP requests, in seconds. Defaults to 120.
        public var readTimeout: TimeInterval = 120

        /// Whether to scale fetch concurrency based on connection pool size.
        /// Defaults to true.
        public var autoScaleFetchConcurrency: Bool = true

        /// Whether to wait for network connectivity before failing.
        /// Defaults to true.
        public var waitsForConnectivity: Bool = true

        /// Idle timeout for pooled connections, in seconds. Defaults to 120.
        public var idleTimeout: TimeInterval = 120

        /// Whether to enable multipath connections. Defaults to true.
        ///
        /// Some environments or network stacks may not support multipath and can
        /// surface "Operation unsupported" connection failures if enabled.
        public var enableMultipath: Bool = true

        /// Whether to allow insecure (non-HTTPS) connections.
        ///
        /// By default, the downloader requires HTTPS for all CAS and fetch URLs.
        /// Set this to `true` only for local development or testing with
        /// non-production servers.
        ///
        /// - Warning: Enabling insecure connections in production is a security risk.
        ///   Tokens and file contents may be transmitted in plaintext.
        public var allowsInsecureConnections: Bool = false

        public static let `default` = Configuration()
    }

    /// Creates a downloader configured for a specific repository.
    ///
    /// - Parameters:
    ///   - refreshURL: The Hugging Face Hub URL for obtaining CAS tokens.
    ///     Format: `https://huggingface.co/api/{type}s/{repo}/xet-read-token/{ref}`
    ///   - hubToken: Optional Hugging Face Hub authentication token.
    ///     Required for private repositories.
    ///   - configuration: Downloader configuration.
    public init(
        refreshURL: URL,
        hubToken: String? = nil,
        configuration: Configuration = .default
    ) {
        self.refreshURL = refreshURL
        self.hubToken = hubToken
        self.configuration = configuration
        self.tokenProvider = TokenProvider(
            urlSession: .shared
        )
        self.casClient = CASClient(urlSession: .shared)
        #if canImport(NIOTransportServices)
            let effectiveEnableMultipath = configuration.enableMultipath
        #else
            let effectiveEnableMultipath = false
        #endif
        var httpConfiguration = HTTPClient.Configuration()
        httpConfiguration.httpVersion = .http1Only
        httpConfiguration.timeout = .init(
            connect: .seconds(Int64(configuration.connectTimeout)),
            read: .seconds(Int64(configuration.readTimeout))
        )
        httpConfiguration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = max(
            1,
            configuration.connectionsPerHost
        )
        httpConfiguration.connectionPool.idleTimeout = .seconds(Int64(max(1, configuration.idleTimeout)))
        httpConfiguration.connectionPool.preWarmedHTTP1ConnectionCount = max(
            0,
            min(configuration.prewarmedConnections, configuration.connectionsPerHost)
        )
        httpConfiguration.networkFrameworkWaitForConnectivity = configuration.waitsForConnectivity
        httpConfiguration.enableMultipath = effectiveEnableMultipath
        self.httpClientPool = HTTPClientPool(
            configuration: httpConfiguration,
            size: configuration.poolSize
        )
    }

    /// Best-effort fallback cleanup.
    ///
    /// Callers should explicitly shut down the downloader
    /// (for example, via `Xet.withDownloader` or by invoking `shutdown()`)
    /// to ensure deterministic resource cleanup.
    /// This `deinit` only attempts to
    /// shut down the underlying HTTP client pool and event loop group.
    /// The `alreadyShutdown` error is silently ignored since it's expected
    /// when shutdown was already called explicitly; other errors are logged.
    deinit {
        let pool = httpClientPool
        Task.detached {
            do {
                try await pool.shutdown()
            } catch {
                switch error as? HTTPClientError {
                case .alreadyShutdown:
                    break
                default:
                    if let data = "XetDownloader deinit: failed to shutdown HTTP client pool: \(error)\n".data(
                        using: .utf8
                    ) {
                        FileHandle.standardError.write(data)
                    }
                }
            }
        }
    }

    /// Downloads a file and returns its contents as `Data`.
    ///
    /// - Parameters:
    ///   - fileID: The 64-character hex file identifier (Merkle hash).
    ///   - byteRange: Optional byte range for partial downloads.
    ///     The range is half-open: `start..<end`.
    ///     An empty range (where `lowerBound == upperBound`) returns
    ///     an empty `Data` immediately without making any network requests.
    ///   - progress: Optional callback with completed and total output bytes.
    ///     See ``download(_:byteRange:to:fileManager:progress:)`` for its contract,
    ///     with two differences:
    ///     the callback runs on the calling task,
    ///     and intermediate updates occur after whole reconstruction terms
    ///     are appended, so a file reconstructed from one term reports
    ///     only the final update, regardless of its size.
    ///
    /// - Returns: The file contents, or the requested byte range.
    ///
    /// - Throws: ``XetDownloaderError`` for protocol-level failures,
    ///   ``XorbError`` for malformed chunk data,
    ///   ``LZ4Error`` for decompression failures,
    ///   or `URLError` for network failures.
    ///
    /// - Important: This method loads the entire file (or range) into memory.
    ///   For large files, use ``download(_:byteRange:to:fileManager:progress:)``
    ///   to write directly to disk instead.
    public func data(
        for fileID: String,
        byteRange: Range<UInt64>? = nil,
        progress: (@Sendable (_ completedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        if let byteRange, byteRange.isEmpty {
            progress?(0, 0)
            return Data()
        }
        let writer = DataOutputWriter()
        let target = WriteTarget.inMemory(writer)
        _ = try await download(
            fileID: fileID,
            byteRange: byteRange,
            target: target,
            progress: progress
        )
        let data = await writer.data
        try Task.checkCancellation()
        progress?(Int64(data.count), Int64(data.count))
        return data
    }

    /// Downloads a file and writes it to disk.
    ///
    /// Chunks are written at their final offsets as they decode,
    /// so fetches for different parts of the file complete in any order
    /// and memory use is bounded by network buffers, not by file size.
    /// If the download fails, the file may hold bytes from any part of the output.
    ///
    /// Progress counts reconstructed bytes written to the output,
    /// not compressed network bytes.
    /// For partial downloads, counts exclude skipped and truncated bytes.
    /// Reused chunks count once for each position they occupy in the output.
    ///
    /// The callback runs synchronously on the task that wrote the bytes,
    /// without a specific actor or queue, and should return promptly.
    /// Calls are serial within each download and counts never decrease.
    /// Intermediate updates occur as chunks are written,
    /// at most once every 100 milliseconds.
    /// The first intermediate update and the final update bypass this interval.
    /// Short downloads may report only the final update.
    ///
    /// On success, the final callback has equal completed and total counts,
    /// including `(0, 0)` for empty output.
    /// For disk downloads, this occurs after the file is closed.
    /// Failure or cancellation produces no final update.
    /// No callbacks occur after the method returns or throws.
    /// Each new call starts its own count, including retries by the caller.
    ///
    /// - Parameters:
    ///   - fileID: The 64-character hex file identifier (Merkle hash).
    ///   - byteRange: Optional byte range for partial downloads.
    ///     The range is half-open: `start..<end`.
    ///     An empty range (where `lowerBound == upperBound`) creates
    ///     an empty file at the destination and returns `0` without
    ///     making any network requests.
    ///   - destinationURL: The file URL where contents will be written.
    ///     If a file exists at this path, it will be replaced.
    ///   - fileManager: The file manager to use for file operations.
    ///     Defaults to `.default`.
    ///   - progress: Optional callback with completed and total output bytes.
    ///
    /// - Returns: The number of bytes written.
    ///
    /// - Throws: ``XetDownloaderError`` for protocol-level failures,
    ///   ``XorbError`` for malformed chunk data,
    ///   ``LZ4Error`` for decompression failures,
    ///   `URLError` for network failures,
    ///   or file system errors if writing to disk fails.
    @discardableResult
    public func download(
        _ fileID: String,
        byteRange: Range<UInt64>? = nil,
        to destinationURL: URL,
        fileManager: FileManager = .default,
        progress: (@Sendable (_ completedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> Int64 {
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        if let byteRange, byteRange.isEmpty {
            try Task.checkCancellation()
            progress?(0, 0)
            return 0
        }
        let writer = try FileOutputWriter(destinationURL: destinationURL)
        let target = WriteTarget.file(writer)
        do {
            let written = try await download(
                fileID: fileID,
                byteRange: byteRange,
                target: target,
                progress: progress
            )
            try await target.closeIfNeeded()
            try Task.checkCancellation()
            progress?(written, written)
            return written
        } catch {
            await target.closeIfNeeded(catching: { closeError in
                if let data = "Xet: failed to close file after download error: \(closeError)\n".data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
            })
            throw error
        }
    }

    /// Shuts down the internal HTTP client pool.
    ///
    /// Call this when you are done with the downloader to release resources.
    ///
    /// - SeeAlso: ``Xet/withDownloader(refreshURL:hubToken:configuration:_:)`` for a more convenient way to create and use a downloader.
    public func shutdown() async throws {
        try await httpClientPool.shutdown()
    }

    // MARK: -

    /// The fetch concurrency limit after applying `autoScaleFetchConcurrency`.
    private var maxConcurrentFetches: Int {
        let configured = max(1, configuration.maxConcurrentFetches)
        guard configuration.autoScaleFetchConcurrency else {
            return configured
        }
        let poolSize = max(1, configuration.poolSize)
        return max(configured, poolSize * max(1, configuration.connectionsPerHost))
    }

    /// Core download implementation that writes to any ``WriteTarget``.
    ///
    /// Resolves the reconstruction and works out where each term's bytes
    /// land in the output, then fetches and decodes xorb ranges.
    /// File targets receive each chunk at its final offset as it decodes,
    /// so fetches complete in any order and memory stays bounded by
    /// network buffers.
    /// In-memory targets receive whole terms in order.
    private func download(
        fileID: String,
        byteRange: Range<UInt64>?,
        target: WriteTarget,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> Int64 {
        // Validate file ID
        guard fileID.count == 64,
            fileID.allSatisfy({ $0.isHexDigit })
        else {
            throw XetDownloaderError.invalidFileID(fileID)
        }

        let conn = try await tokenProvider.connectionInfo(
            for: refreshURL,
            hubToken: hubToken
        )
        try Task.checkCancellation()
        // Validate CAS URL uses HTTPS unless insecure connections are allowed
        if !configuration.allowsInsecureConnections && conn.casURL.scheme != "https" {
            throw XetDownloaderError.insecureURL(conn.casURL)
        }

        let reconstruction = try await casClient.reconstruction(
            of: fileID,
            casURL: conn.casURL,
            accessToken: conn.accessToken,
            byteRange: byteRange
        )
        try Task.checkCancellation()
        let maxBytesToWrite = byteRange.map { $0.upperBound - $0.lowerBound }

        var reconstructedBytes: UInt64 = 0
        for term in reconstruction.terms {
            let (sum, overflow) = reconstructedBytes.addingReportingOverflow(UInt64(term.unpackedLength))
            guard !overflow else { throw XetDownloaderError.invalidReconstruction }
            reconstructedBytes = sum
        }
        guard reconstructedBytes >= reconstruction.offsetIntoFirstRange else {
            throw XetDownloaderError.invalidReconstruction
        }
        let availableBytes = reconstructedBytes - reconstruction.offsetIntoFirstRange
        guard let totalBytes = Int64(exactly: min(availableBytes, maxBytesToWrite ?? availableBytes)) else {
            throw XetDownloaderError.invalidReconstruction
        }

        // The output window within the concatenated terms.
        let outputStart = reconstruction.offsetIntoFirstRange
        let outputEnd = outputStart + UInt64(totalBytes)
        var termStart: UInt64 = 0

        var termContexts: [TermContext] = []
        termContexts.reserveCapacity(reconstruction.terms.count)
        for term in reconstruction.terms {
            guard let fetchInfos = reconstruction.fetchInfo[term.hash] else {
                throw XetDownloaderError.invalidReconstruction
            }
            guard
                let fetchInfo = fetchInfos.first(where: {
                    $0.range.lowerBound <= term.range.lowerBound
                        && $0.range.upperBound >= term.range.upperBound
                })
            else {
                throw XetDownloaderError.invalidReconstruction
            }

            guard let fetchURL = URL(string: fetchInfo.url) else {
                throw XetDownloaderError.invalidFetchURL(fetchInfo.url)
            }
            // Validate fetch URL uses HTTPS unless insecure connections are allowed
            if !configuration.allowsInsecureConnections && fetchURL.scheme != "https" {
                throw XetDownloaderError.insecureURL(fetchURL)
            }

            var request = URLRequest(url: fetchURL)
            request.httpMethod = "GET"
            request.setValue(fetchInfo.urlRangeHeaderValue, forHTTPHeaderField: "Range")
            let key = FetchRangeKey(
                hash: term.hash,
                start: fetchInfo.range.lowerBound,
                end: fetchInfo.range.upperBound,
                urlRangeStart: fetchInfo.urlRange.lowerBound,
                urlRangeEnd: fetchInfo.urlRange.upperBound
            )

            // Intersect the term with the output window.
            let termEnd = termStart + UInt64(term.unpackedLength)
            let writeStart = max(termStart, outputStart)
            let writeEnd = min(termEnd, outputEnd)
            let layout: TermLayout
            if writeStart < writeEnd {
                layout = TermLayout(
                    skip: Int(writeStart - termStart),
                    length: Int(writeEnd - writeStart),
                    outputOffset: Int64(writeStart - outputStart)
                )
            } else {
                layout = .empty
            }
            termStart = termEnd

            termContexts.append(
                TermContext(
                    term: term,
                    fetchInfo: fetchInfo,
                    key: key,
                    request: request,
                    layout: layout
                )
            )
        }

        let tracker = ProgressTracker(totalBytes: totalBytes, callback: progress)
        switch target {
        case .file(let writer):
            try await downloadToFile(termContexts, writer: writer, progress: tracker)
        case .inMemory(let writer):
            try await downloadInOrder(termContexts, writer: writer, progress: tracker)
        }

        try Task.checkCancellation()
        let totalWritten = tracker.completedBytes
        guard totalWritten == totalBytes else {
            throw XetDownloaderError.invalidReconstruction
        }
        return totalWritten
    }

    /// Fetches each distinct range once and writes its chunks at their
    /// final offsets as they decode.
    ///
    /// Fetches start in file order and complete in any order.
    /// At most `maxConcurrentFetches` run at once.
    private func downloadToFile(
        _ termContexts: [TermContext],
        writer: FileOutputWriter,
        progress: ProgressTracker
    ) async throws {
        // Group the terms by the range that serves them, in order of first use.
        var keys: [FetchRangeKey] = []
        var termsByKey: [FetchRangeKey: [TermContext]] = [:]
        for context in termContexts where context.layout.length > 0 {
            if termsByKey[context.key] == nil {
                keys.append(context.key)
            }
            termsByKey[context.key, default: []].append(context)
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, key) in keys.enumerated() {
                    if index >= maxConcurrentFetches {
                        // Wait for a fetch to finish before starting another.
                        try await group.next()
                    }
                    guard let contexts = termsByKey[key] else { continue }
                    group.addTask {
                        try await self.fetchAndWrite(contexts, writer: writer, progress: progress)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            // A canceled fetch fails with a decoding error; report the cancellation instead.
            try Task.checkCancellation()
            throw error
        }
    }

    /// Fetches one range and writes every term it serves.
    ///
    /// All contexts share the same fetch key.
    /// Chunks decode in order within the range, so a running byte count
    /// per term gives each chunk's position in that term's output.
    private func fetchAndWrite(
        _ contexts: [TermContext],
        writer: FileOutputWriter,
        progress: ProgressTracker
    ) async throws {
        guard let first = contexts.first else { return }
        try Task.checkCancellation()
        let firstChunkIndex = first.fetchInfo.range.lowerBound
        var decodedBytes = [Int](repeating: 0, count: contexts.count)
        try await fetchXorbChunks(request: first.request) { ordinal, chunk in
            let chunkIndex = firstChunkIndex + ordinal
            for (slot, context) in contexts.enumerated() where context.term.range.contains(chunkIndex) {
                let layout = context.layout
                let chunkStart = decodedBytes[slot]
                decodedBytes[slot] = chunkStart + chunk.count
                // Clip the chunk to the bytes this term contributes to the output.
                let lower = max(chunkStart, layout.skip)
                let upper = min(chunkStart + chunk.count, layout.skip + layout.length)
                guard lower < upper else { continue }
                let bytes = UnsafeRawBufferPointer(rebasing: chunk[(lower - chunkStart) ..< (upper - chunkStart)])
                try writer.write(contentsOf: bytes, at: layout.outputOffset + Int64(lower - layout.skip))
                progress.add(Int64(upper - lower))
            }
        }
        try Task.checkCancellation()
        for (slot, context) in contexts.enumerated() {
            guard decodedBytes[slot] == Int(context.term.unpackedLength) else {
                throw XetDownloaderError.invalidReconstruction
            }
        }
    }

    /// Fetches ranges ahead of the current term and appends whole terms in order.
    ///
    /// Ranges referenced by more than one term stay cached until the download ends.
    private func downloadInOrder(
        _ termContexts: [TermContext],
        writer: DataOutputWriter,
        progress: ProgressTracker
    ) async throws {
        var xorbUsageCount: [String: Int] = [:]
        var expectedUnpackedBytesByKey: [FetchRangeKey: Int] = [:]
        for context in termContexts {
            xorbUsageCount[context.term.hash, default: 0] += 1
            expectedUnpackedBytesByKey[context.key, default: 0] += Int(context.term.unpackedLength)
        }

        var chunkCache: [FetchRangeKey: FetchedXorb] = [:]
        let fetchSemaphore = AsyncSemaphore(maxConcurrentTasks: maxConcurrentFetches)
        var inflightFetches: [FetchRangeKey: Task<FetchedXorb, Error>] = [:]
        defer {
            for task in inflightFetches.values {
                task.cancel()
            }
        }

        func termRange(from fetched: FetchedXorb, for term: CASClient.ReconstructionResponse.Term) throws -> Range<Int>
        {
            let startIndex = term.range.lowerBound - fetched.chunkRange.lowerBound
            let endIndex = term.range.upperBound - fetched.chunkRange.lowerBound
            guard startIndex >= 0, endIndex >= startIndex, endIndex < fetched.chunkByteIndices.count else {
                throw XetDownloaderError.invalidReconstruction
            }
            let startByte = fetched.chunkByteIndices[startIndex]
            let endByte = fetched.chunkByteIndices[endIndex]
            guard endByte - startByte == Int(term.unpackedLength) else {
                throw XetDownloaderError.invalidReconstruction
            }
            if startByte >= endByte {
                return startByte ..< startByte
            }
            return startByte ..< endByte
        }

        func writeTermData(from fetched: FetchedXorb, for context: TermContext) async throws {
            try Task.checkCancellation()
            let range = try termRange(from: fetched, for: context.term)
            let layout = context.layout
            guard layout.length > 0 else {
                return
            }
            let lower = range.lowerBound + layout.skip
            try await writer.write(fetched.data.subdata(in: lower ..< (lower + layout.length)))
            try Task.checkCancellation()
            progress.add(Int64(layout.length))
        }

        func ensureFetchTask(for context: TermContext) {
            let key = context.key
            let shouldCacheAllForXorb = (xorbUsageCount[context.term.hash] ?? 0) > 1
            let expectedUnpackedLength = expectedUnpackedBytesByKey[key] ?? 0

            if inflightFetches[key] != nil {
                return
            }
            if shouldCacheAllForXorb, chunkCache[key] != nil {
                return
            }

            inflightFetches[key] = Task {
                await fetchSemaphore.wait()
                do {
                    try Task.checkCancellation()
                    let fetched = try await fetchXorbRange(
                        context,
                        expectedUnpackedLength: expectedUnpackedLength
                    )
                    await fetchSemaphore.signal()
                    return fetched
                } catch {
                    await fetchSemaphore.signal()
                    throw error
                }
            }
        }

        for (termIndex, context) in termContexts.enumerated() {
            try Task.checkCancellation()
            let key = context.key
            if progress.completedBytes == progress.totalBytes {
                break
            }
            if context.layout.length == 0 {
                continue
            }

            if let cached = chunkCache[key] {
                try await writeTermData(from: cached, for: context)
                continue
            }

            let shouldCacheAllForXorb = (xorbUsageCount[context.term.hash] ?? 0) > 1
            let prefetchLimit = min(termContexts.count, termIndex + maxConcurrentFetches)
            for prefetchIndex in termIndex ..< prefetchLimit where termContexts[prefetchIndex].layout.length > 0 {
                ensureFetchTask(for: termContexts[prefetchIndex])
            }
            guard let fetchTask = inflightFetches[key] else {
                continue
            }

            let pendingFetches = Array(inflightFetches.values)
            let fetchedChunks = try await withTaskCancellationHandler {
                try await fetchTask.value
            } onCancel: {
                for task in pendingFetches {
                    task.cancel()
                }
            }
            inflightFetches[key] = nil

            if shouldCacheAllForXorb {
                chunkCache[key] = fetchedChunks
            }
            try await writeTermData(from: fetchedChunks, for: context)
        }
    }

    /// Fetches one range and returns its decoded chunks as one buffer.
    private func fetchXorbRange(
        _ context: TermContext,
        expectedUnpackedLength: Int
    ) async throws -> FetchedXorb {
        var data = Data()
        data.reserveCapacity(expectedUnpackedLength)
        var chunkByteIndices: [Int] = [0]
        try await fetchXorbChunks(request: context.request) { _, chunk in
            data.append(contentsOf: chunk)
            chunkByteIndices.append(data.count)
        }
        return FetchedXorb(
            data: data,
            chunkByteIndices: chunkByteIndices,
            chunkRange: context.fetchInfo.range
        )
    }

    /// Fetches one xorb range and hands each decoded chunk to `sink`
    /// with its ordinal within the range.
    ///
    /// The chunk buffer is only valid for the duration of the call.
    private func fetchXorbChunks(
        request: URLRequest,
        sink: (_ ordinal: Int, _ chunk: UnsafeRawBufferPointer) throws -> Void
    ) async throws {
        guard let url = request.url else {
            throw XetDownloaderError.fetchFailed(statusCode: nil, url: URL(fileURLWithPath: "/"))
        }
        let client = await httpClientPool.nextClient()
        var httpRequest = HTTPClientRequest(url: url.absoluteString)
        httpRequest.method = .GET
        if let headers = request.allHTTPHeaderFields {
            for (name, value) in headers {
                httpRequest.headers.add(name: name, value: value)
            }
        }
        let response = try await client.execute(
            httpRequest,
            timeout: .seconds(Int64(max(1, configuration.readTimeout)))
        )
        let statusCode = Int(response.status.code)
        guard (200 ..< 300).contains(statusCode) || statusCode == 206 else {
            throw XetDownloaderError.fetchFailed(statusCode: statusCode, url: url)
        }
        let bufferSlots = max(
            2,
            min(
                max(1, configuration.maxInflightBuffers),
                max(1, configuration.maxConcurrentDecodes)
            )
        )
        let bufferSemaphore = AsyncSemaphore(maxConcurrentTasks: bufferSlots)
        let stream = AsyncThrowingStream<ByteBuffer, Error> { continuation in
            let task = Task {
                do {
                    for try await buffer in response.body {
                        if buffer.readableBytes == 0 {
                            continue
                        }
                        await bufferSemaphore.wait()
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        try await decodeXorbStream(stream: stream, bufferSemaphore: bufferSemaphore, sink: sink)
    }

    /// Decodes chunks from a xorb byte stream and hands each one to `sink`.
    ///
    /// Each chunk decodes into a scratch buffer that is reused for the next chunk,
    /// so memory stays at one chunk plus the undecoded bytes in the cursor.
    private func decodeXorbStream(
        stream: AsyncThrowingStream<ByteBuffer, Error>,
        bufferSemaphore: AsyncSemaphore,
        sink: (_ ordinal: Int, _ chunk: UnsafeRawBufferPointer) throws -> Void
    ) async throws {
        var cursor = ByteCursor()
        var output = ScratchBuffer()
        var grouped = ScratchBuffer()
        defer {
            output.deallocate()
            grouped.deallocate()
        }
        var ordinal = 0

        for try await buffer in stream {
            if buffer.readableBytes > 0 {
                buffer.withUnsafeReadableBytes { raw in
                    cursor.append(contentsOf: raw)
                }
            }
            await bufferSemaphore.signal()

            while cursor.count >= 8 {
                let header = try cursor.withUnsafeReadableBytes { try Xorb.parseHeader($0) }
                guard cursor.count >= 8 + header.compressedLength else { break }
                _ = cursor.skip(count: 8)

                let chunk = output.prepare(count: header.uncompressedLength)
                try cursor.withUnsafeReadableBytes { readable in
                    let compressed = UnsafeRawBufferPointer(
                        start: readable.baseAddress,
                        count: header.compressedLength
                    )
                    switch header.compressionScheme {
                    case .none:
                        guard header.compressedLength == header.uncompressedLength else {
                            throw XorbError.lengthMismatch(
                                expected: header.uncompressedLength,
                                actual: header.compressedLength
                            )
                        }
                        if let src = compressed.baseAddress, let dst = chunk.baseAddress {
                            memcpy(dst, src, header.compressedLength)
                        }

                    case .lz4:
                        _ = try LZ4.decompressBlock(
                            compressed,
                            uncompressedLength: header.uncompressedLength,
                            output: chunk
                        )

                    case .byteGrouping4LZ4:
                        let scratch = grouped.prepare(count: header.uncompressedLength)
                        _ = try LZ4.decompressBlock(
                            compressed,
                            uncompressedLength: header.uncompressedLength,
                            output: scratch
                        )
                        BG4.regroup(UnsafeRawBufferPointer(scratch), into: chunk)
                    }
                }
                cursor.consume(count: header.compressedLength)

                try sink(ordinal, UnsafeRawBufferPointer(chunk))
                ordinal += 1
            }
        }

        if cursor.count > 0 {
            throw XorbError.truncatedStream
        }
    }

    private struct TermContext {
        let term: CASClient.ReconstructionResponse.Term
        let fetchInfo: CASClient.ReconstructionResponse.FetchInfo
        let key: FetchRangeKey
        let request: URLRequest
        let layout: TermLayout
    }

    /// Where a term's decoded bytes land in the output.
    private struct TermLayout {
        /// Decoded bytes to skip at the start of the term.
        let skip: Int
        /// Decoded bytes to write after the skipped bytes.
        let length: Int
        /// Output offset of the first written byte.
        let outputOffset: Int64

        /// A term that contributes nothing to the output.
        static let empty = TermLayout(skip: 0, length: 0, outputOffset: 0)
    }
}

/// Counts written output bytes and throttles progress callbacks.
///
/// File downloads write from several fetch tasks at once,
/// so the count and the throttle timestamp live behind a lock.
/// The callback runs under that lock, which keeps calls serial
/// and the reported counts monotonic.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NIOLock()
    private var completed: Int64 = 0
    private var lastUpdate: TimeInterval?
    private let callback: (@Sendable (Int64, Int64) -> Void)?

    /// The expected output size.
    let totalBytes: Int64

    init(totalBytes: Int64, callback: (@Sendable (Int64, Int64) -> Void)?) {
        self.totalBytes = totalBytes
        self.callback = callback
    }

    /// The bytes written so far.
    var completedBytes: Int64 {
        lock.withLock { completed }
    }

    /// Adds written bytes and reports them,
    /// unless an update went out less than 100 milliseconds ago
    /// or the output is complete.
    ///
    /// The caller reports completion after the output is finalized.
    func add(_ count: Int64) {
        lock.withLock {
            completed += count
            guard let callback, completed < totalBytes else {
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if lastUpdate.map({ now - $0 >= 0.1 }) ?? true {
                lastUpdate = now
                callback(completed, totalBytes)
            }
        }
    }
}

/// A reusable buffer that grows to the largest chunk seen.
private struct ScratchBuffer {
    private var pointer: UnsafeMutableRawPointer?
    private var capacity = 0

    /// Returns a buffer of `count` bytes, reallocating if it must grow.
    mutating func prepare(count: Int) -> UnsafeMutableRawBufferPointer {
        if count > capacity {
            pointer?.deallocate()
            pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
            capacity = count
        }
        return UnsafeMutableRawBufferPointer(start: pointer, count: count)
    }

    mutating func deallocate() {
        pointer?.deallocate()
        pointer = nil
        capacity = 0
    }
}

/// Async semaphore for limiting concurrency.
private actor AsyncSemaphore {
    /// Available permits for waiters.
    private var availablePermits: Int
    /// FIFO queue of suspended waiters.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a semaphore with the specified limit.
    init(maxConcurrentTasks: Int) {
        self.availablePermits = max(0, maxConcurrentTasks)
    }

    /// Waits for a permit to become available.
    func wait() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Releases a permit to the next waiter.
    func signal() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        } else {
            availablePermits += 1
        }
    }
}

/// Round-robin pool of HTTP clients.
private actor HTTPClientPool {
    /// Shared HTTP client instances.
    private let clients: [HTTPClient]
    /// Shared event loop group for all clients.
    private let eventLoopGroup: EventLoopGroup
    /// Next client index for round-robin selection.
    private var nextIndex = 0

    /// Creates a pool with the specified size.
    init(configuration: HTTPClient.Configuration, size: Int) {
        let poolSize = max(1, size)
        var created: [HTTPClient] = []
        created.reserveCapacity(poolSize)
        let group: EventLoopGroup
        #if canImport(NIOTransportServices) && !os(Linux)
            if configuration.enableMultipath {
                group = NIOTSEventLoopGroup(loopCount: System.coreCount)
            } else {
                group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            }
        #else
            group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        #endif
        for _ in 0 ..< poolSize {
            created.append(
                HTTPClient(
                    eventLoopGroupProvider: .shared(group),
                    configuration: configuration
                )
            )
        }
        self.clients = created
        self.eventLoopGroup = group
    }

    /// Returns the next client in the pool.
    func nextClient() -> HTTPClient {
        let client = clients[nextIndex]
        nextIndex = (nextIndex + 1) % clients.count
        return client
    }

    /// Shuts down all clients in the pool.
    func shutdown() async throws {
        for client in clients {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                client.shutdown(queue: .global()) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            eventLoopGroup.shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Errors

/// Errors that can occur during Xet file downloads.
public enum XetDownloaderError: Error, Sendable {
    /// The token refresh request returned an invalid response.
    case invalidTokenResponse

    /// The token refresh request failed with an HTTP error.
    case tokenRequestFailed(statusCode: Int, body: Data)

    /// The CAS URL in the token response could not be parsed.
    case invalidCASURL(String)

    /// The CAS reconstruction request returned an invalid response.
    case invalidReconstructionResponse

    /// The CAS reconstruction request failed with an HTTP error.
    case reconstructionRequestFailed(statusCode: Int, body: Data)

    /// Failed to decode the reconstruction response JSON.
    case reconstructionDecodingFailed(Error)

    /// The reconstruction response is malformed or missing required fetch info.
    case invalidReconstruction

    /// The HTTP request to fetch xorb data failed.
    case fetchFailed(statusCode: Int?, url: URL)

    /// The fetch info URL could not be parsed.
    case invalidFetchURL(String)

    /// The file ID is not a valid 64-character hex string.
    case invalidFileID(String)

    /// A URL does not use HTTPS and insecure connections are not allowed.
    case insecureURL(URL)
}

extension XetDownloaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidTokenResponse:
            return "Token endpoint returned an invalid response."
        case let .tokenRequestFailed(statusCode, _):
            return "Token request failed with HTTP status \(statusCode)."
        case let .invalidCASURL(url):
            return "Invalid or insecure CAS URL: \(url)"
        case .invalidReconstructionResponse:
            return "Reconstruction endpoint returned an invalid response."
        case let .reconstructionRequestFailed(statusCode, _):
            return "Reconstruction request failed with HTTP status \(statusCode)."
        case let .reconstructionDecodingFailed(error):
            return "Failed to decode reconstruction response: \(error.localizedDescription)"
        case .invalidReconstruction:
            return "Reconstruction response is malformed or missing required data."
        case let .fetchFailed(statusCode, url):
            if let code = statusCode {
                return "Failed to fetch xorb data from \(url.host ?? "unknown"): HTTP \(code)"
            }
            return "Failed to fetch xorb data from \(url.host ?? "unknown")."
        case let .invalidFetchURL(url):
            return "Invalid fetch URL: \(url)"
        case let .invalidFileID(id):
            return "Invalid file ID (expected 64 hex characters): \(id.prefix(20))..."
        case let .insecureURL(url):
            return "Insecure URL not allowed: \(url). Set allowsInsecureConnections to true for local development."
        }
    }
}

// MARK: - TokenProvider

extension XetDownloader {
    /// Manages CAS access tokens with caching and coalesced refresh.
    ///
    /// Tokens are cached by refresh URL and Hub token combination.
    /// Concurrent requests for the same token are coalesced into a single
    /// network request.
    actor TokenProvider {
        /// URL session used for token refresh requests.
        private let urlSession: URLSession

        /// Window before expiration to treat tokens as stale.
        private let safetyWindow: TimeInterval

        /// Key for cached connection info.
        private struct CacheKey: Hashable, Sendable {
            let refreshURL: URL
            let hubToken: String?
        }

        /// CAS connection details obtained from the Hub token endpoint.
        struct ConnectionInfo: Equatable, Sendable {
            /// The CAS API base URL.
            let casURL: URL

            /// The bearer token for CAS API authentication.
            let accessToken: String

            /// When the access token expires.
            let expiresAt: Date
        }

        /// Cached connection info by refresh URL and Hub token.
        private var cache: [CacheKey: ConnectionInfo] = [:]

        /// Inflight token refresh tasks by cache key.
        private var inflight: [CacheKey: Task<ConnectionInfo, Error>] = [:]

        /// Creates a token provider.
        ///
        /// - Parameters:
        ///   - urlSession: The URL session for token requests.
        ///   - safetyWindow: Seconds before expiration to consider a token stale.
        ///     Defaults to 60 seconds.
        init(
            urlSession: URLSession = .shared,
            safetyWindow: TimeInterval = 60
        ) {
            self.urlSession = urlSession
            self.safetyWindow = safetyWindow
        }

        /// Obtains CAS connection info, using cached tokens when valid.
        ///
        /// - Parameters:
        ///   - refreshURL: The Hugging Face Hub token endpoint.
        ///   - hubToken: Optional Hub authentication token.
        ///
        /// - Returns: Connection info with CAS URL and access token.
        func connectionInfo(for refreshURL: URL, hubToken: String?) async throws -> ConnectionInfo {
            let key = CacheKey(refreshURL: refreshURL, hubToken: hubToken)

            if let cached = cache[key],
                cached.expiresAt > Date().addingTimeInterval(safetyWindow)
            {
                return cached
            }

            if let existing = inflight[key] {
                return try await existing.value
            }

            let task = Task { [urlSession] () throws -> ConnectionInfo in
                var request = URLRequest(url: refreshURL)
                request.httpMethod = "GET"
                request.cachePolicy = .reloadIgnoringLocalCacheData
                if let hubToken {
                    request.setValue("Bearer \(hubToken)", forHTTPHeaderField: "Authorization")
                }

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw XetDownloaderError.invalidTokenResponse
                }
                guard (200 ..< 300).contains(http.statusCode) else {
                    throw XetDownloaderError.tokenRequestFailed(
                        statusCode: http.statusCode,
                        body: data
                    )
                }

                let decoded: TokenResponse
                do {
                    decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
                } catch {
                    throw XetDownloaderError.invalidTokenResponse
                }
                guard let casURL = URL(string: decoded.casUrl) else {
                    throw XetDownloaderError.invalidCASURL(decoded.casUrl)
                }

                let expiresAt = Date(timeIntervalSince1970: TimeInterval(decoded.exp))
                return ConnectionInfo(
                    casURL: casURL,
                    accessToken: decoded.accessToken,
                    expiresAt: expiresAt
                )
            }

            inflight[key] = task
            do {
                let value = try await task.value
                inflight[key] = nil
                cache[key] = value
                return value
            } catch {
                inflight[key] = nil
                throw error
            }
        }
    }

    /// JSON response from the Hub token endpoint.
    private struct TokenResponse: Equatable, Codable, Sendable {
        let accessToken: String
        let exp: Int
        let casUrl: String
    }
}

// MARK: - Private Helpers

/// Key for tracking which fetch ranges have been downloaded.
private struct FetchRangeKey: Hashable {
    let hash: String
    let start: Int
    let end: Int
    let urlRangeStart: UInt64
    let urlRangeEnd: UInt64
}

/// A fetched xorb chunk.
private struct FetchedXorb {
    let data: Data
    let chunkByteIndices: [Int]
    let chunkRange: Range<Int>
}

/// A destination for downloaded bytes.
private enum WriteTarget: Sendable {
    /// Receives whole terms in order.
    case inMemory(DataOutputWriter)

    /// Receives chunks at their final offsets, in any order.
    case file(FileOutputWriter)

    func closeIfNeeded() async throws {
        if case .file(let writer) = self {
            try await writer.close()
        }
    }

    func closeIfNeeded(catching handler: (Error) -> Void) async {
        do {
            try await closeIfNeeded()
        } catch {
            handler(error)
        }
    }
}

/// An in-memory output writer that accumulates data.
actor DataOutputWriter {
    private(set) var data = Data()

    func write(_ data: Data) async throws {
        self.data.append(data)
    }
}

/// A random access output writer backed by POSIX pwrite.
///
/// Positional writes are safe to issue from several tasks at once.
final class FileOutputWriter: @unchecked Sendable {
    private let lock = NIOLock()
    private var fd: Int32

    init(destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        let flags = O_CREAT | O_RDWR | O_TRUNC
        let mode: mode_t = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        let fd = open(destinationURL.path, flags, mode)
        if fd < 0 {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        self.fd = fd
    }

    func write(contentsOf buffer: UnsafeRawBufferPointer, at offset: Int64) throws {
        if buffer.count == 0 {
            return
        }
        guard let baseAddress = buffer.baseAddress else {
            return
        }
        let currentFD = lock.withLock { fd }
        guard currentFD >= 0 else {
            throw POSIXError(.EBADF)
        }
        var bytesRemaining = buffer.count
        var localOffset = 0
        while bytesRemaining > 0 {
            let writeSize = bytesRemaining
            let written = pwrite(
                currentFD,
                baseAddress.advanced(by: localOffset),
                writeSize,
                off_t(offset + Int64(localOffset))
            )
            if written < 0 {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            bytesRemaining -= written
            localOffset += written
        }
    }

    func close() async throws {
        let currentFD = lock.withLock {
            let currentFD = fd
            fd = -1
            return currentFD
        }
        guard currentFD >= 0 else {
            return
        }
        #if canImport(Darwin)
            let closeResult = Darwin.close(currentFD)
        #elseif canImport(Glibc)
            let closeResult = Glibc.close(currentFD)
        #else
            let closeResult = -1
        #endif
        if closeResult != 0 {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }
}
