import Foundation
import CryptoKit

@MainActor
final class BackupRunner: ObservableObject {

    // MARK: - State
    @Published var status: RunStatus = .idle
    @Published var entries: [LogEntry] = []
    @Published var progress: Double = 0
    @Published var stats = Stats()
    @Published var currentFile = ""

    enum RunStatus { case idle, running, done, failed, cancelled }

    struct LogEntry: Identifiable {
        let id   = UUID()
        let text: String
        let kind: Kind
        enum Kind { case info, success, warning, error }
    }

    struct Stats {
        var total = 0, uploaded = 0, registered = 0, ignored = 0, errors = 0
    }

    private let api: APIService
    private var isCancelled = false

    /// Upload concurrency limit — mirrors Python client --workers default
    private let maxConcurrentUploads = 4
    /// Retry attempts per file on transient network errors
    private let maxRetries = 3

    init(api: APIService) { self.api = api }

    func cancel() {
        guard status == .running else { return }
        isCancelled = true
        log(L("runner.cancel_requested"), .warning)
    }

    // MARK: - Run

    func run(profile: BackupProfile) async {
        status      = .running
        isCancelled = false
        entries     = []
        stats       = Stats()
        progress    = 0

        let label  = profile.label
        let source = profile.sourcePath

        log(L("runner.starting", label), .info)
        log(L("runner.source", source), .info)

        // 1. Create / open backup
        do {
            try await createBackup(label: label)
            log(L("runner.backup_registered"), .success)
        } catch {
            log(L("runner.backup_register_error", error.localizedDescription), .error)
            DockProgress.shared.update(progress: nil)
            status = .failed; return
        }

        // 2. Create version
        let versionKey: String
        do {
            versionKey = try await createVersion(label: label)
            log(L("runner.version_created", versionKey), .success)
        } catch {
            log(L("runner.version_create_error", error.localizedDescription), .error)
            status = .failed; return
        }

        // 3. Walk filesystem
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: source),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            log(L("runner.source_unreadable", source), .error)
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            DockProgress.shared.update(progress: nil)
            status = .failed; return
        }

        var fileURLs: [URL] = []
        for case let url as URL in enumerator {
            if profile.excludes.contains(url.lastPathComponent) {
                enumerator.skipDescendants(); continue
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if !isDir.boolValue { fileURLs.append(url) }
        }

        stats.total = fileURLs.count
        log(L("runner.files_found", fileURLs.count), .info)

        // 4. Build server path list (needed for sync later)
        let serverPaths: [String] = fileURLs.map { url in
            guard !profile.prefix.isEmpty else { return url.path }
            let rel = url.path.hasPrefix(source)
                ? String(url.path.dropFirst(source.count))
                : "/" + url.lastPathComponent
            return profile.prefix.hasSuffix("/")
                ? profile.prefix + rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : profile.prefix + rel
        }

        // 5. Process files with bounded concurrency (TaskGroup)
        let pairs      = Array(zip(fileURLs, serverPaths))
        let totalFiles = pairs.count
        let accumulator = StatsAccumulator()

        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var index    = 0

            while index < pairs.count || inFlight > 0 {
                while inFlight < maxConcurrentUploads && index < pairs.count {
                    guard !isCancelled else { break }
                    let (url, serverPath) = pairs[index]
                    let i = index
                    index += 1
                    inFlight += 1

                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            let action = try await self.processFileWithRetry(
                                url: url, label: label,
                                versionKey: versionKey, serverPath: serverPath
                            )
                            await accumulator.record(action: action)
                        } catch {
                            await accumulator.recordError()
                            await MainActor.run {
                                self.log(L("runner.file_error", url.lastPathComponent,
                                           error.localizedDescription), .error)
                            }
                        }
                        await MainActor.run {
                            self.progress    = Double(i + 1) / Double(max(totalFiles, 1))
                            self.currentFile = url.lastPathComponent
                            DockProgress.shared.update(progress: self.progress)
                        }
                    }
                }

                if inFlight > 0 {
                    await group.next()
                    inFlight -= 1
                    let s = await accumulator.snapshot()
                    stats.uploaded   = s.uploaded
                    stats.registered = s.registered
                    stats.ignored    = s.ignored
                    stats.errors     = s.errors
                }
            }
        }

        if isCancelled {
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            progress    = 0
            currentFile = ""
            status      = .cancelled
            DockProgress.shared.update(progress: nil)
            log(L("runner.cancelled"), .warning)
            return
        }

        // 6. Sync
        do {
            let synced = try await syncVersion(label: label,
                                               versionKey: versionKey,
                                               paths: serverPaths)
            if synced { log(L("runner.sync_done"), .success) }
        } catch {
            log(L("runner.sync_skipped", error.localizedDescription), .warning)
        }

        // 7. Finalize
        await finalizeVersion(label: label, versionKey: versionKey, ok: stats.errors == 0)
        progress    = 1.0
        currentFile = ""
        status      = .done
        DockProgress.shared.update(progress: nil)
        DockProgress.shared.bounce()
        log("─────────────────────────────────────", .info)
        log(L("runner.summary",
              stats.uploaded, stats.registered, stats.ignored, stats.errors), .success)
    }

    // MARK: - API Helpers

    private func createBackup(label: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "label": label,
            "client_name": ProcessInfo.processInfo.hostName
        ])
        let req = try api.buildRequest("/backups", method: "POST", body: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 409 { return }  // Already exists — ok
        if !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "(sem mensagem)"
            throw NSError(domain: "BackupVault", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                            "HTTP \(http.statusCode) — \(msg.prefix(200))"])
        }
    }

    private func createVersion(label: String) async throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let versionKey = formatter.string(from: Date())
        let body = try JSONSerialization.data(withJSONObject: ["version_key": versionKey])
        let req  = try api.buildRequest("/backups/\(label.urlSafe)/versions", method: "POST", body: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "(sem mensagem)"
            throw NSError(domain: "BackupVault", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                            "HTTP \(http.statusCode) — \(msg.prefix(200))"])
        }
        if let r = try? JSONDecoder().decode(VersionCreatedResponse.self, from: data) {
            return r.version.versionKey
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ver  = json["version"] as? [String: Any],
           let key  = ver["version_key"] as? String { return key }
        return versionKey
    }

    /// Retries processFile up to maxRetries times with exponential back-off
    private func processFileWithRetry(url: URL, label: String,
                                      versionKey: String, serverPath: String) async throws -> String {
        var lastError: Error?
        for attempt in 1...maxRetries {
            do {
                return try await processFile(url: url, label: label,
                                             versionKey: versionKey, serverPath: serverPath)
            } catch {
                lastError = error
                if attempt < maxRetries {
                    // 0.5 s · 1 s · 2 s …
                    try? await Task.sleep(nanoseconds: UInt64(500_000_000) * UInt64(attempt))
                }
            }
        }
        throw lastError!
    }

    /// Streams SHA-256 + uploads via file URL — never loads full file into memory
    private func processFile(url: URL, label: String,
                             versionKey: String, serverPath: String) async throws -> String {
        let (sha256, size) = try computeSHA256Streaming(url: url)

        let mtime: Double = {
            if let date = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
                return date.timeIntervalSince1970
            }
            return 0
        }()

        // Check
        let checkBody = try JSONSerialization.data(withJSONObject: [
            "backup_label": label,
            "version_key":  versionKey,
            "original_path": serverPath,
            "sha256": sha256,
            "size":   size,
            "mtime":  mtime
        ] as [String: Any])
        let checkReq = try api.buildRequest("/check", method: "POST", body: checkBody)
        let (checkData, _) = try await URLSession.shared.data(for: checkReq)
        let checkResp     = try? JSONDecoder().decode(CheckResponse.self, from: checkData)
        let needsUpload   = checkResp?.needsUpload   ?? true
        let contentExists = checkResp?.contentExists ?? false

        if !needsUpload { return "ignore" }

        // Build upload request
        var req = try api.buildRequest("/upload", method: "POST", body: nil)
        let pathB64 = Data(serverPath.utf8).base64EncodedString()
        req.setValue(label,         forHTTPHeaderField: "X-Backup-Label")
        req.setValue(versionKey,    forHTTPHeaderField: "X-Version-Key")
        req.setValue(pathB64,       forHTTPHeaderField: "X-Original-Path")
        req.setValue(String(mtime), forHTTPHeaderField: "X-Mtime")

        let (respData, response): (Data, URLResponse)
        if !contentExists {
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // Upload directly from file — avoids loading large files into memory
            (respData, response) = try await URLSession.shared.upload(for: req, fromFile: url)
        } else {
            req.setValue(sha256, forHTTPHeaderField: "X-Content-Sha256")
            (respData, response) = try await URLSession.shared.data(for: req)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let serverMsg = String(data: respData, encoding: .utf8) ?? "(sem mensagem)"
            throw NSError(domain: "BackupVault", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                            "HTTP \(http.statusCode) — \(serverMsg.prefix(300))"])
        }
        return contentExists ? "register" : "upload"
    }

    /// Computes SHA-256 in 1 MB chunks — safe for files of any size
    private func computeSHA256Streaming(url: URL) throws -> (sha256: String, size: Int) {
        let bufferSize = 1_048_576  // 1 MB
        guard let stream = InputStream(url: url) else {
            throw NSError(domain: "BackupVault", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Não foi possível abrir: \(url.path)"])
        }
        stream.open()
        defer { stream.close() }

        var hasher    = SHA256()
        var totalSize = 0
        let buffer    = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                throw stream.streamError ?? NSError(domain: "BackupVault", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Erro de leitura: \(url.path)"])
            }
            if read == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: read))
            totalSize += read
        }

        let digest = hasher.finalize()
        let sha256  = digest.compactMap { String(format: "%02x", $0) }.joined()
        return (sha256, totalSize)
    }

    private func syncVersion(label: String, versionKey: String, paths: [String]) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: [
            "backup_label": label,
            "version_key":  versionKey,
            "existing_paths": paths
        ] as [String: Any])
        let req = try api.buildRequest("/sync", method: "POST", body: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try? JSONDecoder().decode(SyncResponse.self, from: data)
        return resp?.synced ?? false
    }

    private func finalizeVersion(label: String, versionKey: String, ok: Bool) async {
        guard let body = try? JSONSerialization.data(withJSONObject: ["status": ok ? "done" : "failed"]),
              let req  = try? api.buildRequest(
                  "/backups/\(label.urlSafe)/versions/\(versionKey.urlSafe)",
                  method: "PATCH", body: body)
        else { return }
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Log

    private func log(_ text: String, _ kind: LogEntry.Kind) {
        entries.append(LogEntry(text: text, kind: kind))
    }
}

// MARK: - Stats Accumulator (actor — thread-safe parallel counting)

private actor StatsAccumulator {
    private var uploaded   = 0
    private var registered = 0
    private var ignored    = 0
    private var errors     = 0

    func record(action: String) {
        switch action {
        case "upload":   uploaded   += 1
        case "register": registered += 1
        default:         ignored    += 1
        }
    }

    func recordError() { errors += 1 }

    struct Snapshot { var uploaded, registered, ignored, errors: Int }
    func snapshot() -> Snapshot {
        Snapshot(uploaded: uploaded, registered: registered, ignored: ignored, errors: errors)
    }
}

// MARK: - Helpers

private extension String {
    var urlSafe: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
