import Foundation

/// Streams one URL to a local file with byte-level progress and HTTP Range
/// resume. Delegate-based rather than URLSession.bytes to keep per-chunk
/// overhead low at USB throughput.
final class Downloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var resumeOffset: Int64 = 0
    private let partURL: URL
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession!
    private var task: URLSessionDataTask?

    private init(partURL: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.partURL = partURL
        self.progress = progress
        super.init()
    }

    /// Downloads `url` to `partURL`, resuming from its current size if it exists.
    /// Calls `progress` with total bytes present locally (resume offset included).
    static func fetch(url: URL, partURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let d = Downloader(partURL: partURL, progress: progress)
        try await d.run(url: url)
    }

    private func run(url: URL) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: partURL.path) {
            fm.createFile(atPath: partURL.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: partURL)
        resumeOffset = Int64(try h.seekToEnd())
        handle = h

        var request = URLRequest(url: url)
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30       // stall detection; resets on each chunk
        cfg.timeoutIntervalForResource = 24 * 3600
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        received = resumeOffset
        progress(received)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                continuation = cont
                let t = session.dataTask(with: request)
                task = t
                t.resume()
            }
        } onCancel: {
            task?.cancel()
        }
        try? handle?.close()
        handle = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            completionHandler(.allow)
        case 200:
            // Server ignored the Range header — restart from zero.
            if resumeOffset > 0 {
                try? handle?.truncate(atOffset: 0)
                received = 0
            }
            completionHandler(.allow)
        default:
            completionHandler(.cancel)
            finish(with: GoProError.http(http.statusCode, "Download"))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            progress(received)
        } catch {
            dataTask.cancel()
            finish(with: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled {
                finish(with: continuationPending ? GoProError.cancelled : nil)
            } else {
                finish(with: error)
            }
        } else {
            finish(with: nil)
        }
    }

    private var continuationPending: Bool { continuation != nil }

    private func finish(with error: Error?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }
}
