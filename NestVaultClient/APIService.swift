import Foundation

// MARK: - APIService-only response types

struct HealthResponse: Decodable {
    let status: String
    let version: String
    let time: String
}

struct BackupDeletedResponse: Decodable {
    let status: String
    let label: String
}

struct VersionDeletedResponse: Decodable {
    let status: String
    let versionKey: String
    let filesRemovedFromStorage: Int

    enum CodingKeys: String, CodingKey {
        case status
        case versionKey               = "version_key"
        case filesRemovedFromStorage  = "files_removed_from_storage"
    }
}

// MARK: - Backoff

struct BackoffState {
    var failureCount: Int = 0
    var nextRetry: Date?  = nil

    var humanReadable: String {
        guard let next = nextRetry else { return "" }
        let secs = Int(next.timeIntervalSinceNow)
        if secs <= 0 { return L("backoff.ready") }
        return L("backoff.next", secs)
    }
}

// MARK: - APIService

@MainActor
final class APIService: ObservableObject {
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "server_url") ?? "http://192.168.1.100:8000"
    @Published var apiKey:    String = UserDefaults.standard.string(forKey: "api_key")    ?? ""
    @Published var isConnected: Bool = false
    @Published var connectionError: String? = nil
    @Published var isLoadingBackups: Bool = false
    @Published var backups: [BackupSummary] = []
    @Published var serverVersion: String = ""
    @Published var backoff = BackoffState()

    var globalStats: GlobalStats {
        GlobalStats(
            totalBackups:  backups.count,
            totalVersions: backups.reduce(0) { $0 + $1.versionCount },
            totalFiles:    backups.reduce(0) { $0 + $1.fileCount },
            totalSize:     backups.reduce(0) { $0 + $1.totalSizeBytes }
        )
    }

    func saveSettings() {
        UserDefaults.standard.set(serverURL, forKey: "server_url")
        UserDefaults.standard.set(apiKey,    forKey: "api_key")
    }

    // MARK: - Batch Support

    func supportsBatch() -> Bool {
        let parts = serverVersion.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return (parts[0], parts[1]) >= (2, 6)
    }

    func checkBatch(
        session: URLSession,
        label: String,
        versionKey: String,
        items: [CheckBatchItem]
    ) async throws -> [CheckBatchResultItem] {
        let body = try JSONEncoder().encode(
            CheckBatchRequest(backupLabel: label, versionKey: versionKey, files: items))
        var req = try buildRequest("/check/batch", method: "POST", body: body)
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw apiError(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode([CheckBatchResultItem].self, from: data)
    }

    // MARK: - Health

    func checkHealth() async {
        do {
            var req  = try buildRequest("/health", method: "GET", body: nil)
            req.timeoutInterval = 5
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let health = try JSONDecoder().decode(HealthResponse.self, from: data)
                isConnected    = true
                serverVersion  = health.version
                connectionError = nil
                backoff.failureCount = 0
                backoff.nextRetry    = nil
            } else {
                throw URLError(.badServerResponse)
            }
        } catch {
            isConnected     = false
            connectionError = error.localizedDescription
            backoff.failureCount += 1
        }
    }

    // MARK: - Backups

    func fetchBackups() async {
        isLoadingBackups = true
        defer { isLoadingBackups = false }
        do {
            var req = try buildRequest("/backups", method: "GET", body: nil)
            req.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: req)
            backups = try JSONDecoder().decode([BackupSummary].self, from: data)
        } catch {
            // Silently fail — caller can check isConnected
        }
    }

    func deleteBackup(label: String) async throws {
        var req = try buildRequest("/backups/\(label.urlSafe)", method: "DELETE", body: nil)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw apiError(http.statusCode, msg)
        }
    }

    // MARK: - Versions

    func fetchVersions(label: String) async throws -> [BackupVersion] {
        var req = try buildRequest("/backups/\(label.urlSafe)/versions", method: "GET", body: nil)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode([BackupVersion].self, from: data)
    }

    func fetchVersionDetail(label: String, versionKey: String) async throws -> BackupVersion {
        let req = try buildRequest(
            "/backups/\(label.urlSafe)/versions/\(versionKey.urlSafe)",
            method: "GET", body: nil)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(BackupVersion.self, from: data)
    }

    func deleteVersion(label: String, versionKey: String) async throws -> VersionDeletedResponse {
        var req = try buildRequest(
            "/backups/\(label.urlSafe)/versions/\(versionKey.urlSafe)",
            method: "DELETE", body: nil)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(VersionDeletedResponse.self, from: data)
    }

    // MARK: - Files

    func fetchFiles(label: String, versionKey: String) async throws -> [VersionFile] {
        let escaped = versionKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? versionKey
        var req = try buildRequest(
            "/files?backup_label=\(label.urlSafe)&version_key=\(escaped)",
            method: "GET", body: nil)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode([VersionFile].self, from: data)
    }

    // MARK: - Cleanup

    func cleanup(label: String, keep: Int) async throws -> CleanupResult {
        let body = try JSONSerialization.data(withJSONObject: [
            "backup_label": label, "keep": keep
        ] as [String: Any])
        var req = try buildRequest("/backups/\(label.urlSafe)/cleanup", method: "POST", body: body)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        var r = try JSONDecoder().decode(CleanupResult.self, from: data)
        r.label = label
        return r
    }

    func cleanupAll(keep: Int) async throws -> [CleanupResult] {
        var results: [CleanupResult] = []
        for backup in backups {
            let r = try await cleanup(label: backup.label, keep: keep)
            results.append(r)
        }
        return results
    }

    // MARK: - Absorb

    func absorb(session: URLSession, label: String,
                versionKey: String, sourceVersionKey: String) async throws -> AbsorbResponse {
        let body = try JSONEncoder().encode(AbsorbRequest(sourceVersionKey: sourceVersionKey))
        var req  = try buildRequest(
            "/backups/\(label.urlSafe)/versions/\(versionKey.urlSafe)/absorb",
            method: "POST", body: body)
        req.timeoutInterval = 300
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(AbsorbResponse.self, from: data)
    }

    // MARK: - Request Builder

    func buildRequest(_ path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: serverURL + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        if let body {
            req.httpBody = body
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        return req
    }

    // MARK: - Private helpers

    private func apiError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "NestVault", code: code,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) — \(message.prefix(200))"])
    }
}

// MARK: - Shared helpers

private extension String {
    var urlSafe: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
