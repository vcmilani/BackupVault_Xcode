import Foundation
import Combine

@MainActor
final class APIService: ObservableObject {

    // MARK: - Persisted Settings
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }

    // MARK: - Connection State
    @Published var isConnected: Bool = false
    @Published var connectionError: String?

    // MARK: - Backoff (avoid hammering offline servers)
    @Published var backoff = BackoffPolicy()

    // MARK: - Data
    @Published var backups: [BackupSummary] = []
    @Published var isLoadingBackups = false
    @Published var loadError: String?

    // MARK: - Init
    init() {
        // Migrate from old bundle ID if needed
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "serverURL") == nil {
            let oldBundles = ["com.backupvault.app", "BackupVault"]
            for old in oldBundles {
                if let oldDefaults = UserDefaults(suiteName: old),
                   let url = oldDefaults.string(forKey: "serverURL"), !url.isEmpty {
                    defaults.set(url, forKey: "serverURL")
                    if let key = oldDefaults.string(forKey: "apiKey") {
                        defaults.set(key, forKey: "apiKey")
                    }
                    break
                }
                // Also try reading from plist directly
                let plistPath = NSHomeDirectory() + "/Library/Preferences/\(old).plist"
                if let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
                   let url = dict["serverURL"] as? String, !url.isEmpty {
                    defaults.set(url, forKey: "serverURL")
                    if let key = dict["apiKey"] as? String {
                        defaults.set(key, forKey: "apiKey")
                    }
                    break
                }
            }
        }
        self.serverURL = defaults.string(forKey: "serverURL") ?? "http://localhost:8000"
        self.apiKey    = defaults.string(forKey: "apiKey")    ?? ""
    }

    /// Settings persist automatically via @Published didSet — this is a no-op convenience method.
    func saveSettings() {}

    // MARK: - Request Builder
    func buildRequest(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        guard let url = URL(string: base + path) else { throw AppError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }

    // MARK: - Health
    func checkHealth(forceTry: Bool = false) async {
        // Respect backoff window unless explicitly forced (user-initiated)
        if !forceTry && !backoff.shouldAttempt {
            return
        }
        do {
            let req = try buildRequest("/health")
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            isConnected = (200..<300).contains(code)
            connectionError = isConnected ? nil : "HTTP \(code) — \(serverURL)"
            if isConnected {
                backoff.recordSuccess()
            } else {
                backoff.recordFailure()
            }
        } catch {
            isConnected = false
            let msg = (error as NSError).code == -1009
                ? "Servidor inacessível em \(serverURL)."
                : error.localizedDescription
            connectionError = msg
            backoff.recordFailure()
        }
    }

    // MARK: - Backups
    func fetchBackups() async {
        isLoadingBackups = true
        loadError = nil
        do {
            let req = try buildRequest("/backups")
            let (data, _) = try await URLSession.shared.data(for: req)
            backups = try decode([BackupSummary].self, from: data)
        } catch {
            loadError = error.localizedDescription
        }
        isLoadingBackups = false
    }

    // MARK: - Versions
    func fetchVersions(label: String) async throws -> [BackupVersion] {
        let req = try buildRequest("/backups/\(label.urlEncoded)/versions")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try decode([BackupVersion].self, from: data)
    }

    func deleteVersion(label: String, versionKey: String) async throws {
        let req = try buildRequest("/backups/\(label.urlEncoded)/versions/\(versionKey.urlEncoded)", method: "DELETE")
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Files
    func fetchFiles(label: String, versionKey: String) async throws -> [VersionFile] {
        let params = "?backup_label=\(label.urlEncoded)&version_key=\(versionKey.urlEncoded)&include_deleted=true"
        let req = try buildRequest("/files" + params)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try decode([VersionFile].self, from: data)
    }

    // MARK: - Cleanup
    // MARK: - Delete Backup
    func deleteBackup(label: String) async throws {
        let req = try buildRequest("/backups/\(label.urlEncoded)", method: "DELETE")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "BackupVault", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) — \(msg)"])
        }
    }

    func cleanup(label: String, keep: Int) async throws -> CleanupResult {
        let body = try JSONSerialization.data(withJSONObject: ["backup_label": label, "keep": keep])
        let req = try buildRequest("/backups/\(label.urlEncoded)/cleanup", method: "POST", body: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        var result = try decode(CleanupResult.self, from: data)
        result.label = label
        return result
    }

    func cleanupAll(keep: Int) async throws -> [CleanupResult] {
        var results: [CleanupResult] = []
        for backup in backups {
            let r = try await cleanup(label: backup.label, keep: keep)
            results.append(r)
        }
        return results
    }

    // MARK: - Computed
    var globalStats: GlobalStats {
        GlobalStats(
            totalBackups: backups.count,
            totalVersions: backups.reduce(0) { $0 + $1.versionCount },
            totalFiles: backups.reduce(0) { $0 + $1.fileCount },
            totalSize: backups.reduce(0) { $0 + $1.totalSizeBytes }
        )
    }
}


// MARK: - Errors
enum AppError: LocalizedError {
    case invalidURL
    var errorDescription: String? {
        switch self { case .invalidURL: return "URL do servidor inválida" }
    }
}

// MARK: - String Helper
private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
