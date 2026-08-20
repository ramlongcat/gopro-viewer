import Foundation

/// Rate-limits progress callbacks coming from the URLSession delegate queue.
private final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func fire(interval: TimeInterval = 0.1) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(last) >= interval {
            last = now
            return true
        }
        return false
    }
}

@MainActor
final class TransferManager: ObservableObject {
    struct Job: Identifiable {
        let id = UUID()
        let entryID: String
        let file: TransferFile
        var state: JobState = .pending
    }

    enum JobState: Equatable {
        case pending, running, done, skipped, cancelled
        case failed(String)
    }

    enum Phase: Equatable { case idle, running, finished }

    @Published var phase: Phase = .idle
    @Published var jobs: [Job] = []
    @Published var currentName = ""
    @Published var filesDone = 0
    @Published var doneBytes: Int64 = 0
    @Published var currentFileBytes: Int64 = 0
    @Published var totalKnownBytes: Int64 = 0
    /// Files actually being transferred this run (already-copied ones excluded).
    @Published var toTransferCount = 0
    @Published var speed: Double = 0
    @Published var failures: [String] = []
    @Published var wasCancelled = false

    weak var model: AppModel?

    var isActive: Bool { phase == .running }
    var fileCount: Int { jobs.count }

    private var runTask: Task<Void, Never>?
    private var speedWindow: [(Date, Int64)] = []
    /// Snapshot of files already present under the destination base, so
    /// already-copied media is skipped wherever it lives.
    private var preexisting: [String: [AppModel.DestHit]] = [:]

    func start(entries: [MediaEntry], client: GoProClient) {
        guard !entries.isEmpty else { return }
        let includeRaw = Prefs.includeRaw
        let includeProxies = Prefs.includeProxies
        var pairs: [(String, TransferFile)] = []
        for e in entries {
            for tf in e.transferFiles(includeRaw: includeRaw, includeProxies: includeProxies) {
                pairs.append((e.id, tf))
            }
        }
        startJobs(pairs, client: client)
    }

    var failedCount: Int {
        jobs.filter { if case .failed = $0.state { return true }; return false }.count
    }

    /// Re-queues only the jobs that failed in the last run.
    func retryFailed() {
        guard phase == .finished, let client = model?.client else { return }
        let failed = jobs.compactMap { j -> (String, TransferFile)? in
            if case .failed = j.state { return (j.entryID, j.file) }
            return nil
        }
        guard !failed.isEmpty else { return }
        AppLog.log("retrying \(failed.count) failed job(s)")
        startJobs(failed, client: client)
    }

    private func startJobs(_ pairs: [(String, TransferFile)], client: GoProClient) {
        guard phase != .running, !pairs.isEmpty else { return }
        let newJobs = pairs.map { Job(entryID: $0.0, file: $0.1) }
        preexisting = model?.destIndex ?? [:]
        AppLog.log("transfer start: \(newJobs.count) jobs [\(newJobs.map(\.file.name).joined(separator: " "))]")
        jobs = newJobs
        phase = .running
        wasCancelled = false
        failures = []
        filesDone = 0
        doneBytes = 0
        currentFileBytes = 0
        speed = 0
        speedWindow = []
        totalKnownBytes = 0
        toTransferCount = 0

        runTask = Task { await run(client: client) }
    }

    func cancel() {
        runTask?.cancel()
    }

    func dismiss() {
        guard phase == .finished else { return }
        phase = .idle
        jobs = []
        failures = []
    }

    private func run(client: GoProClient) async {
        // Pre-pass: settle "already copied" for the whole queue first, so the
        // progress bar's totals only ever cover files that actually transfer.
        var pendingBytes: Int64 = 0
        var pending = 0
        for idx in jobs.indices {
            let (_, alreadyThere) = resolveDestination(for: jobs[idx].file)
            if alreadyThere {
                jobs[idx].state = .skipped
            } else {
                pendingBytes += jobs[idx].file.size ?? 0
                pending += 1
            }
        }
        totalKnownBytes = pendingBytes
        toTransferCount = pending
        let preSkipped = jobs.count - pending
        if preSkipped > 0 {
            AppLog.log("  \(preSkipped) of \(jobs.count) file(s) already at destination")
        }

        guard pending > 0 else {
            speed = 0
            phase = .finished
            AppLog.log("transfer finished: \(summaryLine)")
            model?.transfersFinished()
            return
        }

        let useTurbo = pending > 1
        if useTurbo { await client.setTurbo(true) }

        for idx in jobs.indices {
            if jobs[idx].state == .skipped { continue }
            if Task.isCancelled {
                wasCancelled = true
                for rest in idx..<jobs.count where jobs[rest].state == .pending {
                    jobs[rest].state = .cancelled
                }
                break
            }
            jobs[idx].state = .running
            let job = jobs[idx]
            currentName = job.file.name
            currentFileBytes = 0
            do {
                let appearedMeanwhile = try await download(job, client: client)
                if appearedMeanwhile {
                    // Landed on disk after the pre-pass — drop it from the totals.
                    AppLog.log("  \(job.file.name): already present")
                    jobs[idx].state = .skipped
                    totalKnownBytes -= job.file.size ?? 0
                    toTransferCount -= 1
                    currentFileBytes = 0
                } else {
                    AppLog.log("  \(job.file.name): done")
                    jobs[idx].state = .done
                    filesDone += 1
                    doneBytes += job.file.size ?? currentFileBytes
                    currentFileBytes = 0
                }
                // The copied gauge and the tile check should turn as each
                // item completes, not when the whole batch does. An entry is
                // complete once no other job of its still has work left.
                let entryID = job.entryID
                let entryDone = !jobs.contains {
                    guard $0.entryID == entryID else { return false }
                    switch $0.state {
                    case .pending, .running, .failed, .cancelled: return true
                    case .done, .skipped: return false
                    }
                }
                if entryDone { model?.entryCopied(entryID) }
            } catch {
                if error is CancellationError || (error as? GoProError).map({ if case .cancelled = $0 { return true }; return false }) == true {
                    jobs[idx].state = .cancelled
                    wasCancelled = true
                    for rest in idx..<jobs.count where jobs[rest].state == .pending {
                        jobs[rest].state = .cancelled
                    }
                    break
                }
                AppLog.log("  \(job.file.name): FAILED \(error.localizedDescription)")
                jobs[idx].state = .failed(error.localizedDescription)
                failures.append("\(job.file.name): \(error.localizedDescription)")
            }
        }

        if useTurbo { await client.setTurbo(false) }
        speed = 0
        phase = .finished
        AppLog.log("transfer finished: \(summaryLine)")
        model?.transfersFinished()
    }

    /// Returns true if the file was already present with the right size.
    private func download(_ job: Job, client: GoProClient) async throws -> Bool {
        let fm = FileManager.default
        let (dest, alreadyThere) = resolveDestination(for: job.file)
        if alreadyThere { return true }

        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.appendingPathExtension("part")
        let url = client.downloadURL(path: job.file.cameraPath)

        let throttle = Throttle()
        try await Downloader.fetch(url: url, partURL: part) { [weak self] bytes in
            guard throttle.fire() else { return }
            Task { @MainActor [weak self] in self?.updateProgress(bytes) }
        }

        if let expected = job.file.size {
            let actual = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard actual == expected else {
                throw GoProError.badResponse("\(job.file.name) incomplete (\(Fmt.size(actual)) of \(Fmt.size(expected)))")
            }
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
        try? fm.setAttributes([
            .creationDate: job.file.created,
            .modificationDate: job.file.modified,
        ], ofItemAtPath: dest.path)
        return false
    }

    /// GoPro numbering recycles after SD formats, so a same-name file with a
    /// different size gets a " (2)" suffix instead of overwriting.
    private func resolveDestination(for tf: TransferFile) -> (URL, alreadyThere: Bool) {
        let fm = FileManager.default
        let baseURL = destinationURL(for: tf)
        if let hits = preexisting[tf.name] {
            if let expected = tf.size {
                if hits.contains(where: { $0.size == expected }) { return (baseURL, true) }
            } else if !hits.isEmpty {
                return (baseURL, true)
            }
        }
        let dir = baseURL.deletingLastPathComponent()
        let base = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension

        for attempt in 0..<10 {
            let name = attempt == 0 ? "\(base).\(ext)" : "\(base) (\(attempt + 1)).\(ext)"
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
                return (url, false)
            }
            guard let expected = tf.size else { return (url, true) }
            if (attrs[.size] as? NSNumber)?.int64Value == expected {
                return (url, true)
            }
        }
        return (baseURL, false)
    }

    private func updateProgress(_ bytes: Int64) {
        currentFileBytes = bytes
        let total = doneBytes + bytes
        let now = Date()
        speedWindow.append((now, total))
        speedWindow.removeAll { now.timeIntervalSince($0.0) > 4 }
        if let first = speedWindow.first, now.timeIntervalSince(first.0) > 0.5 {
            let dt = now.timeIntervalSince(first.0)
            let db = Double(total - first.1)
            if db >= 0 { speed = db / dt }
        }
    }

    // MARK: Display helpers

    var overallFraction: Double? {
        guard totalKnownBytes > 0 else { return nil }
        return min(1, Double(doneBytes + currentFileBytes) / Double(totalKnownBytes))
    }

    var summaryLine: String {
        let done = jobs.filter { $0.state == .done }.count
        let present = jobs.filter { $0.state == .skipped }.count
        let cancelled = jobs.filter { $0.state == .cancelled }.count
        if !jobs.isEmpty, present == jobs.count {
            return "All \(present == 1 ? "1 file is" : "\(present) files are") already copied — nothing to do"
        }
        var parts: [String] = []
        if done > 0 { parts.append("\(done) transferred") }
        if present > 0 { parts.append("\(present) already copied") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: " · ")
    }
}
