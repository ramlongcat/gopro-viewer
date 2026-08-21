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
    /// "name|size" of every file this app has put in Google Photos, so a
    /// second pass doesn't send it twice.
    @Published private(set) var uploaded: Set<String> = []
    @Published private(set) var sending = false
    @Published private(set) var sentCount = 0
    @Published private(set) var sendTotal = 0
    @Published private(set) var sendingName = ""
    /// "name|size" of the file in flight and how far through it is, so the
    /// grid can badge the exact tile being sent.
    @Published private(set) var sendingKey = ""
    @Published private(set) var sendingFraction = 0.0
    /// Byte accounting for the sidebar's note line: whole files finished this
    /// batch, the position inside the one in flight, the batch total, and a
    /// speed measured the same way the copy card's is.
    @Published private(set) var sendDoneBytes: Int64 = 0
    @Published private(set) var sendingBytes: Int64 = 0
    @Published private(set) var sendTotalBytes: Int64 = 0
    @Published private(set) var sendSpeed: Double = 0
    /// Set while the file in flight is in a retry loop, so the card can say
    /// "stalled — retrying" instead of a speed. The log line alone left the
    /// bar looking frozen for no reason.
    @Published private(set) var sendingNote: String?

    private var speedWindow: [(Date, Int64)] = []
    private var speedTimer: Task<Void, Never>?

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var listener: NWListener?
    private var sendTask: Task<Void, Never>?

    private let scopes = "https://www.googleapis.com/auth/photoslibrary.appendonly openid email"
    private let keychainService = "GoProViewer.GooglePhotos"

    private init() {
        account = UserDefaults.standard.string(forKey: Prefs.kGoogleAccount)
        uploaded = Self.loadUploaded()
    }

    var isSignedIn: Bool { account != nil && refreshToken != nil }

    static func key(name: String, size: Int64) -> String { "\(name)|\(size)" }

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
            if on { uploaded.insert(k) } else { uploaded.remove(k) }
        }
        Self.saveUploaded(uploaded)
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

    /// One file's open resumable session, kept for the life of the app so a
    /// failed or cancelled upload continues from the last byte Google holds
    /// instead of starting over. (Google keeps the session for 7 days.)
    private struct ResumableSession {
        let url: URL
        let granularity: Int64
    }
    private var sessions: [String: ResumableSession] = [:]

    /// Chunks start deliberately small: each is its own HTTP request, so
    /// URLSession's idle timeout — which used to kill a whole-file POST the
    /// first time the uplink stalled for a minute — scopes to one slice that
    /// even a dial-up-grade link finishes in time, and a failure costs one
    /// chunk, not the file. But on a fast uplink small chunks waste real time
    /// (a round trip of dead air after every 160 ms send), so each full chunk
    /// that finishes quickly doubles the next, up to a cap the timeout still
    /// covers at ~4.5 Mbps; the first sign of trouble drops straight back.
    /// The size persists across the batch — hundreds of small photos never
    /// individually last long enough to learn the link.
    private static let chunkFloor: Int64 = 4 << 20
    private static let chunkCap: Int64 = 64 << 20
    private static let chunkTimeout: TimeInterval = 120
    private var chunkBytes: Int64 = GooglePhotos.chunkFloor

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
            sessions[key] = session
        }

        let total = Double(max(1, size))
        // A resumed file starts the gauges where Google left off, not at 0.
        sendingFraction = Double(offset) / total
        sendingBytes = offset
        var attempts = 0
        var uploadToken: String?
        while uploadToken == nil {
            if Task.isCancelled { throw CancellationError() }
            let remaining = size - offset
            let planned = chunkBytes
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
            let progress = UploadProgress { [weak self] sent in
                let pos = base + min(sent, len)
                Task { @MainActor in
                    self?.sendingFraction = Double(pos) / total
                    self?.sendingBytes = pos
                }
            }
            let started = Date()
            do {
                var req = URLRequest(url: session.url)
                req.timeoutInterval = Self.chunkTimeout
                req.httpMethod = "POST"
                req.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
                req.setValue(last ? "upload, finalize" : "upload", forHTTPHeaderField: "X-Goog-Upload-Command")
                req.setValue("\(offset)", forHTTPHeaderField: "X-Goog-Upload-Offset")
                let (data, resp) = try await URLSession.shared.upload(for: req, from: body,
                                                                      delegate: progress)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                // 4xx is Google's final word on these bytes (session gone,
                // bad offset): retrying can't change it, so the session is
                // dropped and the error surfaces. 5xx joins the retry path.
                if (400..<500).contains(status) {
                    sessions[key] = nil
                    try Self.check(resp, data, "Upload")
                }
                guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
                offset += len
                attempts = 0
                sendingFraction = Double(offset) / total
                sendingBytes = offset
                sendingNote = nil
                // Only a full-size chunk proves the link — the short final
                // slice of a small photo finishes fast at any speed.
                if len == planned, Date().timeIntervalSince(started) < 30 {
                    chunkBytes = min(planned * 2, Self.chunkCap)
                }
                if last {
                    guard let t = String(data: data, encoding: .utf8), !t.isEmpty else {
                        sessions[key] = nil
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
                chunkBytes = Self.chunkFloor
                sendingNote = "stalled — retrying"
                guard attempts <= 4 else { throw error }
                AppLog.log("google photos: \(url.lastPathComponent) stalled at \(Self.pct(offset, size)) — retry \(attempts) of 4")
                try? await Task.sleep(nanoseconds: UInt64(1 << attempts) * 1_000_000_000)
                if Task.isCancelled { throw CancellationError() }
                // Trust only what Google says it holds — and if the link
                // moved at all since the last try, the retry budget resets.
                if let got = try? await queryOffset(of: session) {
                    if got > offset { attempts = 0 }
                    offset = min(got, size)
                }
            }
        }
        sessions[key] = nil
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
                markUploaded(name: item.name, size: item.size)
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
    private func flushDetached(_ pending: inout [PendingCreate]) async -> Int {
        guard !pending.isEmpty else { return 0 }
        let batch = pending
        pending = []
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
        let total = sendDoneBytes + sendingBytes
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
        sendTask = Task { await uploadAll(items) }
    }

    /// Aborts the file in flight too, not just the ones still queued —
    /// cancelling a 5 GB clip shouldn't have to wait for it to finish.
    func cancelUpload() {
        sendTask?.cancel()
    }

    /// One at a time, and it keeps going if a single item is rejected —
    /// Google refuses some files (unsupported codecs, mostly) and that
    /// shouldn't stop the rest.
    func uploadAll(_ items: [(url: URL, size: Int64)]) async {
        guard !sending else { return }
        sending = true
        sentCount = 0
        sendTotal = items.count
        sendTotalBytes = items.map(\.size).reduce(0, +)
        sendDoneBytes = 0
        sendingBytes = 0
        sendSpeed = 0
        speedWindow = []
        chunkBytes = Self.chunkFloor
        lastError = nil
        speedTimer?.cancel()
        speedTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.sampleSpeed()
            }
        }
        var failures = 0
        var pending: [PendingCreate] = []
        for item in items {
            if Task.isCancelled { break }
            if uploaded.contains(Self.key(name: item.url.lastPathComponent, size: item.size)) {
                sentCount += 1
                sendDoneBytes += item.size
                // Skipped bytes were never transferred; without a reset the
                // jump would read as a burst of speed.
                speedWindow = []
                continue
            }
            sendingName = item.url.lastPathComponent
            sendingKey = Self.key(name: item.url.lastPathComponent, size: item.size)
            sendingFraction = 0
            sendingBytes = 0
            sendingNote = nil
            do {
                let token = try await upload(item.url, size: item.size)
                pending.append(PendingCreate(token: token,
                                             name: item.url.lastPathComponent,
                                             size: item.size))
                // Twenty per flush, not batchCreate's ceiling of 50: the
                // round trip is already amortised to noise, badges land
                // sooner, and a crash can only orphan a few files' worth of
                // sent bytes (orphans are simply re-sent next time).
                if pending.count >= 20 { failures += await flushDetached(&pending) }
            } catch {
                // A pulled cancel surfaces as CancellationError or a
                // cancelled URLSession task; neither is a failure to report.
                if Task.isCancelled { break }
                failures += 1
                lastError = "\(item.url.lastPathComponent): \(error.localizedDescription)"
                AppLog.log("google photos: \(item.url.lastPathComponent) failed — \(error.localizedDescription)")
                // The unsent remainder joins sendDoneBytes below; reset so
                // it can't masquerade as transfer speed.
                speedWindow = []
            }
            sentCount += 1
            sendDoneBytes += item.size
            sendingBytes = 0
        }
        failures += await flushDetached(&pending)
        speedTimer?.cancel()
        speedTimer = nil
        let cancelled = Task.isCancelled
        sending = false
        sendingName = ""
        sendingKey = ""
        sendingFraction = 0
        sendingBytes = 0
        sendSpeed = 0
        sendingNote = nil
        AppLog.log(cancelled
                   ? "google photos: upload cancelled after \(sentCount) of \(sendTotal)"
                   : "google photos: uploaded \(items.count - failures) of \(items.count)")
    }

    private func markUploaded(name: String, size: Int64) {
        uploaded.insert(Self.key(name: name, size: size))
        objectWillChange.send()
        Self.saveUploaded(uploaded)
    }

    /// Opens a resumable session: Google answers with the private URL all
    /// chunks go to and the byte alignment they must keep.
    private func startSession(for url: URL, size: Int64) async throws -> ResumableSession {
        let token = try await validAccessToken()
        var req = URLRequest(url: URL(string: "https://photoslibrary.googleapis.com/v1/uploads")!)
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

    private static func loadUploaded() -> Set<String> {
        guard let data = try? Data(contentsOf: uploadedFile),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    private static func saveUploaded(_ set: Set<String>) {
        let url = uploadedFile
        let list = Array(set)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? JSONEncoder().encode(list).write(to: url)
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
    init(_ onBytes: @escaping (Int64) -> Void) { self.onBytes = onBytes }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
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
