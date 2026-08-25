import AppKit
import CryptoKit
import Foundation
import Network

/// Google Photos as an upload destination.
///
/// Uploading is all the API still allows a third-party app to do: Google
/// removed the library-reading scopes on 31 March 2025, leaving
/// `photoslibrary.appendonly` (send) and `…appcreateddata` (read back only
/// what this app sent). So this is a one-way door — copies go up, nothing
/// comes down, and the app tracks what it has sent itself.
///
/// Sign-in is the loopback flow Google documents for desktop apps: the system
/// browser handles the account, and a local listener catches the redirect.
/// PKCE means no client secret has to ship in the binary.
@MainActor
final class GooglePhotos: ObservableObject {
    static let shared = GooglePhotos()

    @Published private(set) var account: String?
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    /// Everything known about one file's place in Google Photos. The point
    /// of keeping more than a bare "it's up there" bit is trust: a mark that
    /// says *when* it was made and *whether Google confirmed it* can be
    /// audited later, which a naked set membership famously could not.
    struct UploadRecord: Codable, Equatable {
        /// When the mark was made — the moment Google confirmed the item,
        /// or the moment the user marked it by hand. Nil for marks written
        /// by 1.19 and earlier, which recorded only the key.
        var date: Date?
        /// "google" when mediaItems:batchCreate answered Success for this
        /// very file; "manual" for the context-menu override. The inspector
        /// says which, because they deserve different amounts of trust.
        var source: String?
        /// Google's productUrl for the created item — a direct link to it
        /// in the library, and proof the upload really happened.
        var link: String?
    }

    /// Keyed "name|size" for every file this app believes is in Google
    /// Photos, so a second pass doesn't send it twice.
    @Published private(set) var uploaded: [String: UploadRecord] = [:]
    @Published private(set) var sending = false
    /// A batch the user paused mid-flight, waiting for resume or cancel.
    @Published private(set) var uploadPaused = false
    @Published private(set) var sentCount = 0
    @Published private(set) var sendTotal = 0
    /// One file being sent right now, keyed by "name|size" — up to
    /// `parallelUploads` of them. The grid badges and the card's per-file
    /// lines read straight from this table.
    struct FileProgress {
        let name: String
        let size: Int64
        /// Confirmed-plus-buffered position, for display; resumes only ever
        /// trust the offset Google confirms.
        var bytes: Int64 = 0
        var fraction: Double = 0
        /// "stalled — retrying in 8 s" and friends; nil while moving.
        var note: String?
        /// Position in the batch, so the card lists workers in stable order.
        let ordinal: Int
    }
    @Published private(set) var inFlight: [String: FileProgress] = [:]
    /// Byte accounting for the sidebar's note line: whole files finished
    /// this batch, the batch total, and a speed measured the same way the
    /// copy card's is.
    @Published private(set) var sendDoneBytes: Int64 = 0
    @Published private(set) var sendTotalBytes: Int64 = 0
    @Published private(set) var sendSpeed: Double = 0
    /// What the last finished batch actually did — "3 files uploaded · 1
    /// failed" — shown in the Sync Status card until the next batch. The
    /// counts keep "confirmed by Google this run" strictly apart from
    /// "skipped because it was already marked": conflating the two once let
    /// a batch that sent nothing announce it had uploaded 214 files.
    @Published private(set) var lastBatchSummary: String?

    /// Several files at once: on a high-latency or per-connection-throttled
    /// link (satellite backhaul, hotel-grade QoS) one TCP stream cannot fill
    /// the pipe, and extra streams multiply aggregate throughput. On a good
    /// home uplink they merely share it — mild cost, big upside.
    private static let parallelUploads = 3
    private var speedWindow: [(Date, Int64)] = []
    private var speedTimer: Task<Void, Never>?
    /// Files the running batch hasn't started yet. A mutable queue rather
    /// than an index so "Upload Now" can move a file to the front.
    private var queue: [(url: URL, size: Int64)] = []
    private var pendingCreates: [PendingCreate] = []
    /// When the oldest entry in `pendingCreates` was queued — the age
    /// trigger for flushing (see `uploadWorker`).
    private var firstPendingAt: Date?
    private var rejectCount = 0
    /// Files this batch skipped because they were already marked uploaded.
    private var skippedCount = 0
    /// Files Google confirmed as media items this batch — the only number
    /// that may honestly be called "uploaded".
    private var createdCount = 0
    /// Order files were taken in, for the card's stable in-flight listing.
    private var takeCounter = 0

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var listener: NWListener?
    private var sendTask: Task<Void, Never>?
    /// The batch as begun, remembered so a pause knows what resume owes.
    private var batchItems: [(url: URL, size: Int64)] = []

    private let scopes = "https://www.googleapis.com/auth/photoslibrary.appendonly openid email"
    private let keychainService = "GoProViewer.GooglePhotos"

    private init() {
        account = UserDefaults.standard.string(forKey: Prefs.kGoogleAccount)
        uploaded = Self.loadUploaded()
        loadSessions()
    }

    var isSignedIn: Bool { account != nil && refreshToken != nil }

    static func key(name: String, size: Int64) -> String { "\(name)|\(size)" }

    private static func key(of item: (url: URL, size: Int64)) -> String {
        key(name: item.url.lastPathComponent, size: item.size)
    }

    /// The files of an entry Google Photos can take — videos and JPGs, never
    /// .LRV/.THM proxies or .GPR raws. Every uploader and every "is it up
    /// there" check goes through this one filter.
    static func sendables(of entry: MediaEntry) -> [CameraFile] {
        let files: [CameraFile]
        switch entry.kind {
        case .video(let chapters): files = chapters
        case .photo(let f), .photoGroup(let f), .other(let f): files = [f]
        }
        return files.filter { $0.isVideo || $0.ext == "JPG" }
    }

    /// Manual override for media that reached Google Photos some other way
    /// (their uploader, a backup tool): the API has no way to ask the
    /// library, so the user tells the app instead.
    func setUploaded(_ on: Bool, files: [CameraFile]) {
        for f in files {
            let k = Self.key(name: f.name, size: f.size)
            if on {
                // Never downgrade a Google-confirmed record (with its date
                // and link) to a weaker by-hand one.
                if uploaded[k]?.source != "google" {
                    uploaded[k] = UploadRecord(date: Date(), source: "manual")
                }
            } else {
                uploaded[k] = nil
            }
        }
        Self.saveUploaded(uploaded)
        AppLog.log("google photos: \(files.count) file(s) marked \(on ? "as uploaded" : "not uploaded") by hand")
    }

    // MARK: Sign in

    func signIn() async {
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            let verifier = Self.randomString(64)
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
            let (port, codeStream) = try startLoopback()
            defer { listener?.cancel(); listener = nil }

            let redirect = "http://127.0.0.1:\(port)"
            var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            comps.queryItems = [
                .init(name: "client_id", value: Prefs.googleClientID),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: scopes),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
            ]
            NSWorkspace.shared.open(comps.url!)

            guard let code = await codeStream() else {
                throw GoogleError.message("Sign-in was cancelled or timed out.")
            }
            let tokens = try await exchange(["grant_type": "authorization_code",
                                             "code": code,
                                             "redirect_uri": redirect,
                                             "code_verifier": verifier])
            guard let refresh = tokens["refresh_token"] as? String else {
                throw GoogleError.message("Google didn't return a refresh token.")
            }
            saveRefreshToken(refresh)
            apply(tokens)
            account = Self.email(fromIDToken: tokens["id_token"] as? String) ?? "Google Photos"
            UserDefaults.standard.set(account, forKey: Prefs.kGoogleAccount)
            AppLog.log("google photos: signed in as \(account ?? "?")")
        } catch {
            // A build whose client has no secret configured passes the whole
            // browser flow and then dies at the token exchange — the one
            // failure every fresh checkout hits — so that OAuth error becomes
            // the fix instead. The log keeps the raw HTTP detail.
            let raw = error.localizedDescription
            lastError = raw.contains("client_secret is missing")
                ? "Google needs this app's client secret. Paste it in Settings → Google Photos → \"Use my own Google client\"."
                : raw
            AppLog.log("google photos: sign-in failed — \(raw)")
        }
    }

    func signOut() {
        deleteRefreshToken()
        account = nil
        accessToken = nil
        accessExpiry = .distantPast
        UserDefaults.standard.removeObject(forKey: Prefs.kGoogleAccount)
    }

    // MARK: Upload

    /// One file's open resumable session, kept — and persisted to disk — so
    /// a failed, cancelled or quit-mid-file upload continues from the last
    /// byte Google holds instead of starting over. (Google keeps the session
    /// for 7 days; on a thin link, hours of progress hang on remembering it.)
    private struct ResumableSession: Codable {
        let url: URL
        let granularity: Int64
        var started = Date()
    }
    private var sessions: [String: ResumableSession] = [:]

    private static var sessionsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoProOffload/google-sessions.json")
    }

    private func loadSessions() {
        guard let data = try? Data(contentsOf: Self.sessionsFile),
              let dict = try? JSONDecoder().decode([String: ResumableSession].self, from: data)
        else { return }
        // Only sessions still inside Google's window come back; `upload`
        // queries each one before trusting a byte of it anyway.
        sessions = dict.filter { Date().timeIntervalSince($0.value.started) < 6.5 * 86_400 }
    }

    /// Every mutation goes through here so the on-disk copy stays current.
    private func setSession(_ key: String, _ session: ResumableSession?) {
        sessions[key] = session
        let snapshot = sessions
        let url = Self.sessionsFile
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: url)
        }
    }

    /// Chunking is paced by a *measured* link rate, not a fixed ladder. Each
    /// chunk is its own HTTP request, so trouble costs one slice, not the
    /// file — but the slice must be big enough not to waste a fast uplink on
    /// round trips, and small enough that a thin one finishes before its
    /// deadline. A grow-fast/shrink-on-stall ladder can't find that size on
    /// a shared link: three workers on a ~1 Mbps hotspot each see moments of
    /// speed (whenever the others sit between chunks), the lucky chunk
    /// doubled the size, and the steady share then stalled it — an endless
    /// grow→stall→shrink sawtooth seen in the field. So every confirmed
    /// chunk feeds an EWMA of this connection's real bytes/s, the next chunk
    /// aims for `chunkTarget` seconds at that rate, and the deadline gets
    /// 2.5× the expected time plus grace. Both follow the link wherever it
    /// drifts; even a cut-off chunk recalibrates from what Google confirms
    /// actually landed.
    private static let chunkCap: Int64 = 64 << 20
    /// A slice never shrinks below this — it stays a multiple of the 256 KB
    /// granularity Google's sessions ask for, and at the floor rate it still
    /// beats its deadline with room to spare.
    private static let chunkMin: Int64 = 512 << 10
    /// How long a chunk should take at the observed rate. Long enough to
    /// amortise the round trip, short enough that one lost chunk is cheap.
    private static let chunkTarget: TimeInterval = 15
    /// The rate estimate never drops below ~8 KB/s: below that the link is
    /// treated as dead-ish and deadlines stop growing.
    private static let rateFloor: Double = 8_000
    /// Base patience for small control requests, and the least any chunk
    /// deadline can be. (URLRequest's timeout is idle-based, but an upload's
    /// "activity" is bytes handed to the socket buffer — a whole small chunk
    /// buffers instantly, so in practice the deadline must cover the full
    /// wire time of the slice.)
    private static let chunkTimeout: TimeInterval = 30

    /// Observed per-connection upload rate (bytes/s). Nil until the first
    /// chunk of a batch lands — the first slice is a modest 1 MB probe with
    /// a patient deadline, then this takes over.
    private var linkRate: Double?

    private func noteRate(_ observed: Double) {
        let clamped = max(Self.rateFloor, observed)
        linkRate = linkRate.map { $0 * 0.6 + clamped * 0.4 } ?? clamped
    }

    /// A cut-off chunk whose bytes went nowhere: no observation to feed, so
    /// assume half the estimate and let real data correct it.
    private func pessimizeRate() {
        linkRate = max(Self.rateFloor, (linkRate ?? 100_000) / 2)
    }

    private func plannedChunk() -> Int64 {
        guard let r = linkRate else { return 1 << 20 }
        return min(Self.chunkCap, max(Self.chunkMin, Int64(r * Self.chunkTarget)))
    }

    private func chunkDeadline(for len: Int64) -> TimeInterval {
        guard let r = linkRate, r > 0 else { return 60 }
        return min(180, max(Self.chunkTimeout, Double(len) / r * 2.5 + 10))
    }
    /// The finalize chunk gets far longer: after the last byte, Google
    /// assembles the whole file before answering, and a big video's silence
    /// there is processing, not a stall — timing it out would fail an upload
    /// that actually succeeded.
    private static let finalizeTimeout: TimeInterval = 180
    /// Waits between retries of a stalled chunk. Short first — the timeout
    /// already burned half a minute — then backing off. Any confirmed
    /// progress resets the whole ladder.
    private static let retryDelays: [Int] = [1, 2, 5, 10, 30, 60]

    /// Sends one file's bytes and returns the upload token; the caller
    /// registers the token as a media item (creates are batched — see
    /// `flushCreates`) and records the file only once that succeeds. Photos
    /// and videos only — Google Photos has no use for .LRV/.THM proxies.
    ///
    /// This is Google's resumable protocol, not the obvious single raw POST.
    /// The single POST had two failure modes seen in the field: a one-minute
    /// network stall anywhere in a multi-gigabyte send timed the whole thing
    /// out and lost every byte already sent, and the progress callback counts
    /// bytes the socket has merely buffered — so a dead connection still
    /// "reached 20%" of a 9 MB photo before vanishing. Chunks are retried
    /// from the last byte Google confirms holding, and the fraction shown is
    /// anchored to confirmed progress.
    func upload(_ url: URL, size: Int64) async throws -> String {
        let key = Self.key(name: url.lastPathComponent, size: size)
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        // A session left over from an earlier failed or cancelled run picks
        // up where it stopped; anything else (expired, finalized) starts over.
        var offset: Int64 = 0
        var session: ResumableSession
        if let held = sessions[key], let got = try? await queryOffset(of: held) {
            session = held
            offset = min(got, size)
            if offset > 0 {
                AppLog.log("google photos: \(url.lastPathComponent) resuming at \(Self.pct(offset, size))")
            }
        } else {
            session = try await startSession(for: url, size: size)
            setSession(key, session)
        }

        let total = Double(max(1, size))
        // A resumed file starts the gauges where Google left off, not at 0.
        inFlight[key]?.fraction = Double(offset) / total
        inFlight[key]?.bytes = offset
        var attempts = 0
        var uploadToken: String?
        while uploadToken == nil {
            if Task.isCancelled { throw CancellationError() }
            let remaining = size - offset
            let planned = plannedChunk()
            var len = min(remaining, planned)
            if len < remaining {
                // Every chunk but the last must be a multiple of the
                // granularity the session stated.
                len = max(session.granularity, len - len % session.granularity)
                len = min(len, remaining)
            }
            let last = offset + len == size
            try fh.seek(toOffset: UInt64(offset))
            guard let body = try fh.read(upToCount: Int(len)), Int64(body.count) == len else {
                throw GoogleError.message("Couldn't read the file — did it change on disk?")
            }
            let base = offset
            // Publishing every callback made the whole window redraw
            // hundreds of times a second on a fast link — the grid visibly
            // stuttered while a batch ran. ~1% of a chunk is plenty live.
            let progress = UploadProgress(minStep: max(128 << 10, len / 100)) { [weak self] sent in
                let pos = base + min(sent, len)
                Task { @MainActor in
                    self?.inFlight[key]?.fraction = Double(pos) / total
                    self?.inFlight[key]?.bytes = pos
                }
            }
            let started = Date()
            do {
                var req = URLRequest(url: session.url)
                req.timeoutInterval = last ? Self.finalizeTimeout : chunkDeadline(for: len)
                req.httpMethod = "POST"
                req.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
                req.setValue(last ? "upload, finalize" : "upload", forHTTPHeaderField: "X-Goog-Upload-Command")
                req.setValue("\(offset)", forHTTPHeaderField: "X-Goog-Upload-Offset")
                let (data, resp) = try await URLSession.shared.upload(for: req, from: body,
                                                                      delegate: progress)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                // 4xx is Google's final word on these bytes (session gone,
                // bad offset): retrying can't change it, so the session is
                // dropped and the error surfaces. 5xx joins the retry path —
                // and so does 429, which is pressure, not a verdict: with
                // several workers Google may meter us for a moment.
                if (400..<500).contains(status), status != 429 {
                    setSession(key, nil)
                    try Self.check(resp, data, "Upload")
                }
                guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
                offset += len
                attempts = 0
                inFlight[key]?.fraction = Double(offset) / total
                inFlight[key]?.bytes = offset
                inFlight[key]?.note = nil
                // Feed the estimate from real slices only — the short final
                // sliver of a photo finishes fast at any speed and would
                // only add noise.
                if len >= Self.chunkMin {
                    noteRate(Double(len) / max(0.05, Date().timeIntervalSince(started)))
                }
                if last {
                    guard let t = String(data: data, encoding: .utf8), !t.isEmpty else {
                        setSession(key, nil)
                        throw GoogleError.message("Google returned no upload token.")
                    }
                    uploadToken = t
                }
            } catch let error as GoogleError {
                throw error
            } catch {
                // Transport trouble — a timeout, a dropped connection, a 5xx.
                if Task.isCancelled { throw error }
                attempts += 1
                let sendElapsed = Date().timeIntervalSince(started)
                guard attempts <= Self.retryDelays.count else { throw error }
                let delay = Self.retryDelays[attempts - 1]
                AppLog.log("google photos: \(url.lastPathComponent) stalled at \(Self.pct(offset, size)) — \(Fmt.size(len)) chunk cut at \(Int(sendElapsed)) s — retry \(attempts) of \(Self.retryDelays.count) in \(delay) s")
                // The wait counts down in the card — an unexplained frozen
                // bar is what this note exists to prevent.
                for left in stride(from: delay, through: 1, by: -1) {
                    inFlight[key]?.note = "stalled — retrying in \(left) s"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { throw CancellationError() }
                }
                inFlight[key]?.note = "stalled — retrying"
                // Trust only what Google says it holds — and if the link
                // moved at all since the last try, the retry budget resets.
                // Bytes that landed before the cut are also the most honest
                // rate sample there is (this is how a mis-sized chunk on a
                // thin link self-corrects instead of stalling again); a cut
                // with nothing to show halves the estimate instead.
                if let got = try? await queryOffset(of: session) {
                    let delta = min(got, size) - offset
                    if delta > 0 {
                        attempts = 0
                        // Adopted outright, not blended: the cut is proof the
                        // estimate was wrong, and this is a direct reading of
                        // what the link does *now*. Successes blend the
                        // estimate back up smoothly afterwards.
                        linkRate = max(Self.rateFloor, Double(delta) / max(1, sendElapsed))
                    } else {
                        pessimizeRate()
                    }
                    offset = min(got, size)
                } else {
                    pessimizeRate()
                }
            }
        }
        setSession(key, nil)
        guard let uploadToken else {
            // Unreachable — the loop only exits with a token — but honest
            // about it beats a force-unwrap.
            throw GoogleError.message("Google returned no upload token.")
        }
        return uploadToken
    }

    /// A fully-sent file waiting for its mediaItems:batchCreate.
    private struct PendingCreate {
        let token: String
        let name: String
        let size: Int64
    }

    /// Registers pending files as media items in one call, marks the
    /// successes as uploaded, and returns how many were rejected. Creates
    /// are batched because the round trip was pure dead air between files —
    /// on a photo batch, a large share of the wall clock. batchCreate
    /// answers 200 even when individual items fail, so results are checked
    /// one by one; they mirror the request's order.
    private func flushCreates(_ batch: [PendingCreate]) async -> Int {
        guard !batch.isEmpty else { return 0 }
        var failures = 0
        do {
            let token = try await validAccessToken()
            var create = URLRequest(url: URL(string: "https://photoslibrary.googleapis.com/v1/mediaItems:batchCreate")!)
            create.httpMethod = "POST"
            create.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            create.setValue("application/json", forHTTPHeaderField: "Content-Type")
            create.httpBody = try JSONSerialization.data(withJSONObject: [
                "newMediaItems": batch.map {
                    ["simpleMediaItem": ["uploadToken": $0.token, "fileName": $0.name]]
                },
            ])
            let (body, resp) = try await URLSession.shared.data(for: create)
            try Self.check(resp, body, "Create media items")
            let results = ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])
                .flatMap { $0["newMediaItemResults"] as? [[String: Any]] }) ?? []
            for (i, item) in batch.enumerated() {
                // Success carries status {"message": "Success"} with the code
                // omitted (proto3 drops zero); a missing result row is *not*
                // assumed successful.
                guard i < results.count,
                      let status = results[i]["status"] as? [String: Any],
                      (status["code"] as? Int ?? 0) == 0 else {
                    failures += 1
                    let msg = (i < results.count
                               ? (results[i]["status"] as? [String: Any])?["message"] as? String
                               : nil) ?? "Google rejected the item."
                    lastError = "\(item.name): \(msg)"
                    AppLog.log("google photos: \(item.name) rejected — \(msg)")
                    continue
                }
                let media = results[i]["mediaItem"] as? [String: Any]
                markUploaded(name: item.name, size: item.size,
                             link: media?["productUrl"] as? String)
                createdCount += 1
            }
            // The line that says it *actually* happened — per flush, so even
            // a batch the app doesn't survive leaves a record of what landed.
            if batch.count > failures {
                AppLog.log("google photos: \(batch.count - failures) item(s) confirmed by Google")
            }
        } catch {
            failures += batch.count
            lastError = error.localizedDescription
            AppLog.log("google photos: registering \(batch.count) item(s) failed — \(error.localizedDescription)")
        }
        return failures
    }

    /// Runs a flush outside the batch's task, so a cancel can't poison the
    /// bookkeeping: URLSession calls inside a cancelled task throw
    /// immediately, and bytes Google already holds in full deserve their
    /// create — without it they'd be sent again next time.
    private func flushDetached() async -> Int {
        guard !pendingCreates.isEmpty else { return 0 }
        let batch = pendingCreates
        pendingCreates = []
        firstPendingAt = nil
        return await Task { await self.flushCreates(batch) }.value
    }

    /// Sampled by a once-a-second clock while a batch runs — NOT from
    /// URLSession's send callbacks. Those arrive in a burst while the socket
    /// buffers a chunk, then go silent until Google answers; on a slow link
    /// no window ever spanned two bursts, so the speed either froze or never
    /// appeared at all. A steady clock also tells the truth about stalls:
    /// when nothing moves for a while, the rate honestly sinks to zero (and
    /// the card hides it in favour of the retry note).
    private func sampleSpeed() {
        guard sending else { return }
        let now = Date()
        let total = sendDoneBytes + inFlight.values.reduce(0) { $0 + $1.bytes }
        speedWindow.append((now, total))
        speedWindow.removeAll { now.timeIntervalSince($0.0) > 10 }
        if let first = speedWindow.first {
            let dt = now.timeIntervalSince(first.0)
            // A retry can move the position backwards (only Google's
            // confirmed offset is trusted); clamp rather than show a
            // negative rate.
            if dt >= 1 { sendSpeed = max(0, Double(total - first.1) / dt) }
        }
    }

    /// Kicks the batch off on its own task so Cancel has something to pull.
    func beginUpload(_ items: [(url: URL, size: Int64)]) {
        guard !sending else { return }
        batchItems = items
        sendTask = Task { await uploadAll(items) }
    }

    /// Aborts the file in flight too, not just the ones still queued —
    /// cancelling a 5 GB clip shouldn't have to wait for it to finish.
    func cancelUpload() {
        uploadPaused = false
        batchItems = []
        sendTask?.cancel()
    }

    /// Pause is the same pull Cancel makes — every worker stops mid-chunk —
    /// but the batch is remembered. Nothing already sent is lost: each
    /// file's resumable session survives (Google keeps them for 7 days), so
    /// Resume re-queues what's left and a partial file continues from the
    /// last byte Google confirmed holding.
    func pauseUpload() {
        guard sending, !uploadPaused else { return }
        uploadPaused = true
        sendTask?.cancel()
    }

    /// Sends what the paused batch still owes. `uploadPaused` stays set
    /// until the new run actually starts, so the card keeps its Paused state
    /// through the old task's teardown instead of flashing the idle slot.
    func resumeUpload() {
        guard uploadPaused, !sending else { return }
        let batch = batchItems
        let old = sendTask
        sendTask = Task {
            // The paused run may still be tearing down; queue behind it
            // rather than racing the `sending` guard.
            _ = await old?.value
            let left = batch.filter { self.uploaded[Self.key(of: $0)] == nil }
            guard !left.isEmpty else {
                self.uploadPaused = false
                return
            }
            await self.uploadAll(left)
        }
    }

    /// Files the paused batch still owes — what Resume would send.
    var pausedRemaining: Int {
        batchItems.filter { uploaded[Self.key(of: $0)] == nil }.count
    }

    /// The context menu's "Upload Now": send these files ahead of everything
    /// else. In a running batch they jump to the front of the queue (files
    /// already moving keep moving — the next free worker takes them); while
    /// paused they go first in what Resume owes, and Resume is pressed; idle,
    /// they become their own batch. Files already marked uploaded are left
    /// alone — unmark first to force a re-send.
    func uploadNow(_ items: [(url: URL, size: Int64)]) {
        let fresh = items.filter { uploaded[Self.key(of: $0)] == nil }
        guard !fresh.isEmpty else { return }
        let keys = Set(fresh.map(Self.key(of:)))
        if sending {
            // batchItems is the batch as begun plus everything added since —
            // the membership test for "was this already counted in the
            // totals". (Queue and in-flight alone would miss a file the
            // batch already tried and gave up on.)
            let inBatch = Set(batchItems.map(Self.key(of:)))
            queue.removeAll { keys.contains(Self.key(of: $0)) }
            // A file some worker is sending right now is as "now" as it gets.
            let jumpers = fresh.filter { inFlight[Self.key(of: $0)] == nil }
            queue.insert(contentsOf: jumpers, at: 0)
            // Newcomers weren't part of this batch — grow its totals so the
            // card's counts stay truthful.
            for item in jumpers where !inBatch.contains(Self.key(of: item)) {
                sendTotal += 1
                sendTotalBytes += item.size
                batchItems.append(item)
            }
            AppLog.log("google photos: \(jumpers.count) file(s) moved to the front of the queue")
        } else if uploadPaused {
            batchItems.removeAll { keys.contains(Self.key(of: $0)) }
            batchItems.insert(contentsOf: fresh, at: 0)
            resumeUpload()
        } else {
            beginUpload(fresh)
        }
    }

    /// A small pool of workers pulls files off one shared queue. A file
    /// Google *rejects* (unsupported codec, mostly) is logged and left
    /// behind — the rest deserve their chance. A file that fails on
    /// *transport* is never abandoned: its worker waits out the dead link,
    /// counting down in the card, and takes the same file again for as long
    /// as it takes — only Cancel ends that. Bytes Google has confirmed
    /// survive both kinds of trouble.
    func uploadAll(_ items: [(url: URL, size: Int64)]) async {
        guard !sending else { return }
        sending = true
        uploadPaused = false
        sentCount = 0
        sendTotal = items.count
        sendTotalBytes = items.map(\.size).reduce(0, +)
        sendDoneBytes = 0
        sendSpeed = 0
        speedWindow = []
        linkRate = nil
        lastError = nil
        lastBatchSummary = nil
        inFlight = [:]
        queue = items
        pendingCreates = []
        firstPendingAt = nil
        rejectCount = 0
        skippedCount = 0
        createdCount = 0
        takeCounter = 0
        speedTimer?.cancel()
        speedTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.sampleSpeed()
            }
        }
        // "Upload Now" can refill the queue after the workers drained it;
        // late arrivals get another round rather than being dropped.
        repeat {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<max(1, min(Self.parallelUploads, queue.count)) {
                    group.addTask { await self.uploadWorker() }
                }
            }
        } while !Task.isCancelled && !queue.isEmpty
        rejectCount += await flushDetached()
        speedTimer?.cancel()
        speedTimer = nil
        let cancelled = Task.isCancelled
        sending = false
        inFlight = [:]
        sendSpeed = 0
        // What one run may claim: only creates Google confirmed. Skips and
        // failures are named as what they are — the old "uploaded X of Y"
        // arithmetic counted every skip as an upload, so a batch that moved
        // no bytes could still announce victory.
        if cancelled, uploadPaused {
            AppLog.log("google photos: upload paused — \(createdCount) confirmed first, \(pausedRemaining) left")
        } else if cancelled {
            if createdCount > 0 {
                lastBatchSummary = "Stopped — \(createdCount) file\(createdCount == 1 ? "" : "s") uploaded first"
            }
            AppLog.log("google photos: upload cancelled — \(createdCount) of \(sendTotal) confirmed")
        } else {
            var bits = ["\(createdCount) file\(createdCount == 1 ? "" : "s") uploaded"]
            if skippedCount > 0 { bits.append("\(skippedCount) already there") }
            if rejectCount > 0 { bits.append("\(rejectCount) failed") }
            lastBatchSummary = bits.joined(separator: " · ")
            AppLog.log("google photos: batch finished — " + bits.joined(separator: ", "))
        }
        // The rare straggler: an "Upload Now" that landed while the batch
        // was already wrapping up becomes its own small batch.
        if !cancelled, !queue.isEmpty {
            let rest = queue
            queue = []
            beginUpload(rest)
        }
    }

    /// One worker: take the next file, see it through, repeat. Everything it
    /// mutates is MainActor-confined and touched without an await in
    /// between, so no file can be taken twice.
    private func uploadWorker() async {
        while !Task.isCancelled, !queue.isEmpty {
            let item = queue.removeFirst()
            takeCounter += 1
            let ordinal = takeCounter
            let key = Self.key(of: item)
            if uploaded[key] != nil {
                sentCount += 1
                skippedCount += 1
                sendDoneBytes += item.size
                // Skipped bytes were never transferred; without a reset the
                // jump would read as a burst of speed.
                speedWindow = []
                continue
            }
            inFlight[key] = FileProgress(name: item.url.lastPathComponent,
                                         size: item.size, ordinal: ordinal)
            var finished = false
            while !finished, !Task.isCancelled {
                do {
                    let token = try await upload(item.url, size: item.size)
                    pendingCreates.append(PendingCreate(token: token,
                                                        name: item.url.lastPathComponent,
                                                        size: item.size))
                    if firstPendingAt == nil { firstPendingAt = Date() }
                    // Twenty per flush, not batchCreate's ceiling of 50: the
                    // round trip is already amortised to noise, badges land
                    // sooner, and a crash can only orphan a few files' worth
                    // of sent bytes (orphans are simply re-sent next time).
                    // The age trigger exists because upload tokens die after
                    // 24 hours: on a thin link twenty files can take days,
                    // and a token must never rot in this queue — ten minutes
                    // is nothing next to any upload that slow, and the fast
                    // case reaches twenty long before it.
                    if pendingCreates.count >= 20
                        || Date().timeIntervalSince(firstPendingAt ?? Date()) > 600 {
                        rejectCount += await flushDetached()
                    }
                    finished = true
                } catch let error as GoogleError {
                    // Google's final word on this file — the next one
                    // deserves its chance.
                    rejectCount += 1
                    lastError = "\(item.url.lastPathComponent): \(error.localizedDescription)"
                    AppLog.log("google photos: \(item.url.lastPathComponent) failed — \(error.localizedDescription)")
                    // The unsent remainder joins sendDoneBytes below; reset
                    // so it can't masquerade as transfer speed.
                    speedWindow = []
                    finished = true
                } catch {
                    // A pulled cancel surfaces as CancellationError or a
                    // cancelled URLSession task; neither is worth a note.
                    if Task.isCancelled { break }
                    // Transport — the link is down, not the file. A batch
                    // left running overnight should outlive that: wait a
                    // minute, counting down in the card, then take the SAME
                    // file again, forever. Its resumable session survives,
                    // so bytes Google holds still count on reconnection.
                    speedWindow = []
                    AppLog.log("google photos: connection lost at \(item.url.lastPathComponent) — retrying in 60 s")
                    for left in stride(from: 60, through: 1, by: -1) {
                        inFlight[key]?.note = "connection lost — retrying in \(left) s"
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { break }
                    }
                    inFlight[key]?.note = nil
                }
            }
            inFlight[key] = nil
            if finished {
                sentCount += 1
                sendDoneBytes += item.size
            }
        }
    }

    private func markUploaded(name: String, size: Int64, link: String?) {
        uploaded[Self.key(name: name, size: size)] =
            UploadRecord(date: Date(), source: "google", link: link)
        Self.saveUploaded(uploaded)
    }

    /// Opens a resumable session: Google answers with the private URL all
    /// chunks go to and the byte alignment they must keep.
    private func startSession(for url: URL, size: Int64) async throws -> ResumableSession {
        let token = try await validAccessToken()
        var req = URLRequest(url: URL(string: "https://photoslibrary.googleapis.com/v1/uploads")!)
        // Same short leash as a chunk: on a dead link this is the first call
        // a retried file makes, and the default 60 s would set the pace.
        req.timeoutInterval = Self.chunkTimeout
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        req.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        req.setValue(Self.mime(for: url), forHTTPHeaderField: "X-Goog-Upload-Content-Type")
        req.setValue("\(size)", forHTTPHeaderField: "X-Goog-Upload-Raw-Size")
        req.setValue(url.lastPathComponent, forHTTPHeaderField: "X-Goog-Upload-File-Name")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: Data())
        try Self.check(resp, data, "Upload start")
        guard let http = resp as? HTTPURLResponse,
              let s = http.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let sessionURL = URL(string: s) else {
            throw GoogleError.message("Google didn't open an upload session.")
        }
        let gran = http.value(forHTTPHeaderField: "X-Goog-Upload-Chunk-Granularity")
            .flatMap { Int64($0) } ?? (256 << 10)
        return ResumableSession(url: sessionURL, granularity: max(1, gran))
    }

    /// Asks a session how many bytes Google actually holds — the only number
    /// an interrupted upload can safely continue from. Throws when the
    /// session is no longer usable (expired, finalized, cancelled).
    private func queryOffset(of session: ResumableSession) async throws -> Int64 {
        var req = URLRequest(url: session.url)
        req.timeoutInterval = 30
        req.httpMethod = "POST"
        req.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("query", forHTTPHeaderField: "X-Goog-Upload-Command")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: Data())
        try Self.check(resp, data, "Upload status")
        guard let http = resp as? HTTPURLResponse,
              http.value(forHTTPHeaderField: "X-Goog-Upload-Status") == "active",
              let received = http.value(forHTTPHeaderField: "X-Goog-Upload-Size-Received")
                  .flatMap({ Int64($0) }) else {
            throw GoogleError.message("Upload session expired.")
        }
        return received
    }

    /// Google wants the real type declared when the session opens.
    private static func mime(for url: URL) -> String {
        switch url.pathExtension.uppercased() {
        case "JPG", "JPEG": return "image/jpeg"
        case "MP4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func pct(_ part: Int64, _ whole: Int64) -> String {
        "\(whole > 0 ? Int(100 * Double(part) / Double(whole)) : 0)%"
    }

    // MARK: Tokens

    private func validAccessToken() async throws -> String {
        if let accessToken, accessExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = refreshToken else { throw GoogleError.message("Not signed in to Google Photos.") }
        let tokens = try await exchange(["grant_type": "refresh_token", "refresh_token": refresh])
        apply(tokens)
        guard let token = accessToken else { throw GoogleError.message("Google didn't return an access token.") }
        return token
    }

    private func apply(_ tokens: [String: Any]) {
        accessToken = tokens["access_token"] as? String
        let ttl = (tokens["expires_in"] as? Double) ?? 3000
        accessExpiry = Date().addingTimeInterval(ttl)
    }

    private func exchange(_ fields: [String: String]) async throws -> [String: Any] {
        var body = fields
        body["client_id"] = Prefs.googleClientID
        // Google's docs call the secret optional for desktop clients, but a
        // real one answers "client_secret is missing" without it, so it is
        // sent whenever it has been configured.
        if !Prefs.googleClientSecret.isEmpty { body["client_secret"] = Prefs.googleClientSecret }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.map { "\($0.key)=\(Self.escape($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data, "Token")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Loopback

    /// Listens on an ephemeral port and hands back the `code` parameter of the
    /// first request Google's redirect makes.
    private func startLoopback() throws -> (UInt16, () async -> String?) {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        var resume: ((String?) -> Void)?
        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let code = URLComponents(string: "http://127.0.0.1\(path)")?
                    .queryItems?.first { $0.name == "code" }?.value
                // Browsers pre-connect and ask for /favicon.ico on the same
                // port. Answering those with "cancelled" is what made a
                // successful sign-in look like nothing had happened: the
                // redirect arrived on a later connection, by which point the
                // flow had already given up. Only a request that actually
                // carries a code ends the wait.
                guard let code else {
                    let miss = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(miss.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                let page = "Signed in. You can close this tab and go back to GoProViewer."
                let http = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n"
                    + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                conn.send(content: Data(http.utf8), completion: .contentProcessed { _ in conn.cancel() })
                resume?(code)
                resume = nil
            }
        }
        listener.start(queue: .main)
        // The port is assigned asynchronously; wait briefly for it.
        var port: UInt16 = 0
        for _ in 0..<200 where port == 0 {
            port = listener.port?.rawValue ?? 0
            if port == 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        guard port != 0 else { throw GoogleError.message("Couldn't open a local port for sign-in.") }

        let wait: () async -> String? = {
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                var done = false
                resume = { code in
                    guard !done else { return }
                    done = true
                    cont.resume(returning: code)
                }
                // Nobody should sit on Google's consent screen for five
                // minutes; give up rather than leak a listener.
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                    guard !done else { return }
                    done = true
                    cont.resume(returning: nil)
                }
            }
        }
        return (port, wait)
    }

    // MARK: Keychain

    private var refreshToken: String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: keychainService,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveRefreshToken(_ token: String) {
        deleteRefreshToken()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: keychainService,
                                  kSecValueData as String: Data(token.utf8)]
        SecItemAdd(add as CFDictionary, nil)
    }

    private func deleteRefreshToken() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: keychainService] as CFDictionary)
    }

    // MARK: Odds and ends

    private static var uploadedFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoProOffload/google-uploaded.json")
    }

    private static func loadUploaded() -> [String: UploadRecord] {
        guard let data = try? Data(contentsOf: uploadedFile) else { return [:] }
        if let dict = try? JSONDecoder().decode([String: UploadRecord].self, from: data) {
            return dict
        }
        // 1.19 and earlier kept a bare list of keys. The marks stay trusted;
        // their history just wasn't written down yet, so the records are empty.
        if let list = try? JSONDecoder().decode([String].self, from: data) {
            return Dictionary(uniqueKeysWithValues: list.map { ($0, UploadRecord()) })
        }
        return [:]
    }

    private static func saveUploaded(_ dict: [String: UploadRecord]) {
        let url = uploadedFile
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? JSONEncoder().encode(dict).write(to: url)
        }
    }

    private static func check(_ resp: URLResponse, _ data: Data, _ what: String) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String
                    ?? $0["error_description"] as? String }
            throw GoogleError.message("\(what) failed (HTTP \(http.statusCode))"
                                      + (detail.map { ": \($0)" } ?? ""))
        }
    }

    /// The id token's middle segment carries the signed-in address. It is only
    /// used to label the account in Settings, so it is read, never trusted.
    private static func email(fromIDToken token: String?) -> String? {
        guard let parts = token?.split(separator: "."), parts.count > 1 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }

    private static func randomString(_ n: Int) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

/// Byte-count callbacks for one chunk request; delivered off-main, forwarded
/// by the closure. The count includes bytes the socket has only buffered,
/// which is why it feeds display within a chunk but never the offset the
/// upload trusts — that comes from Google.
private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let onBytes: (Int64) -> Void
    /// Callbacks below this step apart are swallowed: each one forwarded
    /// publishes an ObservableObject the entire window watches, and on a
    /// fast link they arrive hundreds of times a second. (Delegate calls
    /// for one task are serial, so the bookkeeping needs no lock.)
    let minStep: Int64
    private var lastSent: Int64 = 0

    init(minStep: Int64, _ onBytes: @escaping (Int64) -> Void) {
        self.minStep = minStep
        self.onBytes = onBytes
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesSent - lastSent >= minStep
                || totalBytesSent == totalBytesExpectedToSend else { return }
        lastSent = totalBytesSent
        onBytes(totalBytesSent)
    }
}

enum GoogleError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
