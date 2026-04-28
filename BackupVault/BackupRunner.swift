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
        var total = 0, uploaded = 0, registered = 0, ignored = 0, deleted = 0, errors = 0
    }

    private let api: APIService
    private var isCancelled = false

    init(api: APIService) { self.api = api }

    func cancel() {
        guard status == .running else { return }
        isCancelled = true
        log("Cancelamento solicitado…", .warning)
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

        log("Iniciando backup: \(label)", .info)
        log("Origem: \(source)", .info)

        // 1. Create / open backup
        do {
            try await createBackup(label: label)
            log("Backup registrado no servidor", .success)
        } catch {
            log("Erro ao registrar backup: \(error.localizedDescription)", .error)
            status = .failed; return
        }

        // 2. Create version
        let versionKey: String
        do {
            versionKey = try await createVersion(label: label)
            log("Versão criada: \(versionKey)", .success)
        } catch {
            log("Erro ao criar versão: \(error.localizedDescription)", .error)
            status = .failed; return
        }

        // 3. Walk filesystem
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: source),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            log("Não foi possível ler: \(source)", .error)
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
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
        log("Arquivos encontrados: \(fileURLs.count)", .info)

        // 4. Process each file
        var serverPaths: [String] = []
        for (i, url) in fileURLs.enumerated() {
            progress = Double(i) / Double(max(fileURLs.count, 1))
            currentFile = url.lastPathComponent

            let serverPath: String
            if profile.prefix.isEmpty {
                serverPath = url.path
            } else {
                let rel = url.path.hasPrefix(source)
                    ? String(url.path.dropFirst(source.count))
                    : "/" + url.lastPathComponent
                serverPath = profile.prefix.hasSuffix("/")
                    ? profile.prefix + rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    : profile.prefix + rel
            }
            serverPaths.append(serverPath)

            if isCancelled { break }

            do {
                let action = try await processFile(url: url, label: label,
                                                   versionKey: versionKey,
                                                   serverPath: serverPath)
                switch action {
                case "upload":   stats.uploaded    += 1
                case "register": stats.registered  += 1
                default:         stats.ignored      += 1
                }
            } catch {
                stats.errors += 1
                log("Erro: \(url.path) — \(error.localizedDescription)", .error)
            }
        }

        if isCancelled {
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            progress    = 0
            currentFile = ""
            status      = .cancelled
            log("Backup cancelado — versão marcada como failed.", .warning)
            return
        }

        // 5. Sync deletions
        do {
            let deleted = try await syncDeletions(label: label,
                                                   versionKey: versionKey,
                                                   paths: serverPaths)
            stats.deleted = deleted
            if deleted > 0 { log("Deletados marcados: \(deleted)", .warning) }
        } catch {
            log("Sync ignorado: \(error.localizedDescription)", .warning)
        }

        // 6. Finalize
        await finalizeVersion(label: label, versionKey: versionKey, ok: stats.errors == 0)
        progress    = 1.0
        currentFile = ""
        status      = .done
        log("─────────────────────────────────────", .info)
        log("Enviados: \(stats.uploaded)  Registrados: \(stats.registered)  Ignorados: \(stats.ignored)  Deletados: \(stats.deleted)  Erros: \(stats.errors)", .success)
    }

    // MARK: - API Helpers

    private func createBackup(label: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "label": label,
            "client_name": ProcessInfo.processInfo.hostName
        ])
        let req = try api.buildRequest("/backups", method: "POST", body: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 409 {
            // Already exists — ok
            return
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "(sem mensagem)"
            throw NSError(domain: "BackupVault", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                            "HTTP \(http.statusCode) — \(msg.prefix(200))"])
        }
    }

    private func createVersion(label: String) async throws -> String {
        let versionKey = ISO8601DateFormatter().string(from: Date())
        let body = try JSONSerialization.data(withJSONObject: ["version_key": versionKey])
        let req  = try api.buildRequest("/backups/\(label.urlSafe)/versions", method: "POST", body: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        // Server echoes the version_key inside {"created":..., "version":{"version_key":...}}
        if let resp = try? JSONDecoder().decode(VersionCreatedResponse.self, from: data) {
            return resp.version.versionKey
        }
        // Fallback: try raw JSON
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ver = json["version"] as? [String: Any],
           let key = ver["version_key"] as? String { return key }
        return versionKey
    }

    private func processFile(url: URL, label: String, versionKey: String, serverPath: String) async throws -> String {
        let data   = try Data(contentsOf: url)
        let sha256 = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let size   = data.count

        // mtime — file modification time (epoch float) per CheckRequest schema
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
        let checkResp = try? JSONDecoder().decode(CheckResponse.self, from: checkData)
        let needsUpload    = checkResp?.needsUpload    ?? true
        let contentExists  = checkResp?.contentExists  ?? false

        if !needsUpload { return "ignore" }

        // Build /upload request — binary stream with headers (v2.1 contract)
        var req = try api.buildRequest("/upload", method: "POST", body: nil)
        let pathB64 = Data(serverPath.utf8).base64EncodedString()
        req.setValue(label,         forHTTPHeaderField: "X-Backup-Label")
        req.setValue(versionKey,    forHTTPHeaderField: "X-Version-Key")
        req.setValue(pathB64,       forHTTPHeaderField: "X-Original-Path")
        req.setValue(String(mtime), forHTTPHeaderField: "X-Mtime")

        let (respData, response): (Data, URLResponse)
        if !contentExists {
            // Full upload: binary body, no X-Content-Sha256
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            (respData, response) = try await URLSession.shared.upload(for: req, from: data)
        } else {
            // Register only: no body, X-Content-Sha256 signals content already in storage
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

    private func syncDeletions(label: String, versionKey: String, paths: [String]) async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: [
            "backup_label": label,
            "version_key":  versionKey,
            "existing_paths": paths
        ] as [String: Any])
        let req = try api.buildRequest("/sync", method: "POST", body: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try? JSONDecoder().decode(SyncResponse.self, from: data)
        return resp?.deletedCount ?? 0
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

// MARK: - Helpers

private extension String {
    var urlSafe: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

private func += (lhs: inout Data, rhs: String) {
    if let d = rhs.data(using: .utf8) { lhs.append(d) }
}
private func += (lhs: inout Data, rhs: Data) { lhs.append(rhs) }
