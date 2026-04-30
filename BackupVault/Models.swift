import Foundation

// MARK: - BackupInfo  (GET /backups, GET /backups/{label})

struct BackupSummary: Codable, Identifiable, Hashable {
    let id: Int
    let label: String
    let clientName: String?
    let prefix: String?
    let status: String?
    let createdAt: String?
    let lastVersion: String?
    let versionCount: Int
    let fileCount: Int
    let totalSizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case id, label, prefix, status
        case clientName       = "client_name"
        case createdAt        = "created_at"
        case lastVersion      = "last_version"
        case versionCount     = "version_count"
        case fileCount        = "file_count"
        case totalSizeBytes   = "total_size_bytes"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }
    var lastVersionDate: Date? {
        guard let lv = lastVersion else { return nil }
        return parseISO(lv)
    }
    static func == (lhs: BackupSummary, rhs: BackupSummary) -> Bool { lhs.label == rhs.label }
    func hash(into hasher: inout Hasher) { hasher.combine(label) }
}

// MARK: - VersionInfo  (GET /backups/{label}/versions)

struct BackupVersion: Codable, Identifiable, Hashable {
    let id: Int
    let versionKey: String
    let backupLabel: String
    let status: String
    let createdAt: String?
    let finishedAt: String?
    let fileCount: Int
    let deletedCount: Int
    let totalSizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case id, status
        case versionKey     = "version_key"
        case backupLabel    = "backup_label"
        case createdAt      = "created_at"
        case finishedAt     = "finished_at"
        case fileCount      = "file_count"
        case deletedCount   = "deleted_count"
        case totalSizeBytes = "total_size_bytes"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }
    var date: Date?  { parseISO(versionKey) }
    var isDone: Bool { status == "done" }

    static func == (lhs: BackupVersion, rhs: BackupVersion) -> Bool { lhs.versionKey == rhs.versionKey }
    func hash(into hasher: inout Hasher) { hasher.combine(versionKey) }
}

// MARK: - FileInfo  (GET /files)

struct VersionFile: Codable, Identifiable {
    let id: Int
    let originalPath: String
    let sha256: String
    let size: Int64
    let mtime: Double?
    let status: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, sha256, size, mtime, status
        case originalPath = "original_path"
        case createdAt    = "created_at"
    }

    var isDeleted: Bool { status == "deleted" }
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - CheckResponse  (POST /check)

struct CheckResponse: Codable {
    let needsUpload: Bool
    let contentExists: Bool
    let reason: String?
    let fileId: Int?

    enum CodingKeys: String, CodingKey {
        case reason
        case needsUpload   = "needs_upload"
        case contentExists = "content_exists"
        case fileId        = "file_id"
    }
}

// MARK: - UploadResponse  (POST /upload)

struct UploadResponse: Codable {
    let status: String
    let fileId: Int?
    let sha256: String?
    let uploaded: Bool?

    enum CodingKeys: String, CodingKey {
        case status, sha256, uploaded
        case fileId = "file_id"
    }
}

// MARK: - SyncResponse  (POST /sync)

struct SyncResponse: Codable {
    let markedDeleted: [String]
    let deletedCount: Int

    enum CodingKeys: String, CodingKey {
        case markedDeleted = "marked_deleted"
        case deletedCount  = "deleted_count"
    }
}

// MARK: - CleanupResponse  (POST /backups/{label}/cleanup)

struct CleanupResult: Codable {
    /// Injected after decode — the server response itself does not include the label.
    var label: String = ""
    let kept: Int
    let versionsRemoved: [String]
    let storageFilesRemoved: Int

    enum CodingKeys: String, CodingKey {
        case kept
        case versionsRemoved     = "versions_removed"
        case storageFilesRemoved = "storage_files_removed"
    }

    var removed: Int { versionsRemoved.count }
}

// MARK: - VersionCreatedResponse  (POST /backups/{label}/versions)

struct VersionCreatedResponse: Codable {
    let created: Bool
    let version: BackupVersion   // full VersionInfo from server
}

// MARK: - Global Stats (computed locally)

struct GlobalStats {
    let totalBackups: Int
    let totalVersions: Int
    let totalFiles: Int
    let totalSize: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}


// MARK: - Backup Schedule

struct BackupSchedule: Codable, Hashable, Equatable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case off, hourly, daily, weekly, custom
        var id: String { rawValue }
    }

    var frequency: Frequency = .off
    var hour: Int    = 2          // for daily/weekly (0-23)
    var minute: Int  = 0          // for daily/weekly (0-59)
    var weekday: Int = 1          // for weekly (1=Sun … 7=Sat)
    var customMinutes: Int = 60   // for custom

    var enabled: Bool { frequency != .off }

    /// Computes the next run date given a baseline (typically Date()).
    func nextRun(after baseline: Date = Date(), lastRun: Date? = nil) -> Date? {
        let cal = Calendar.current
        switch frequency {
        case .off:
            return nil
        case .hourly:
            let from = lastRun ?? baseline
            return cal.date(byAdding: .hour, value: 1, to: from) ?? baseline.addingTimeInterval(3600)
        case .custom:
            let from = lastRun ?? baseline
            return cal.date(byAdding: .minute, value: customMinutes, to: from)
                   ?? baseline.addingTimeInterval(TimeInterval(customMinutes * 60))
        case .daily:
            return nextOccurrence(hour: hour, minute: minute, weekday: nil, after: baseline)
        case .weekly:
            return nextOccurrence(hour: hour, minute: minute, weekday: weekday, after: baseline)
        }
    }

    private func nextOccurrence(hour: Int, minute: Int, weekday: Int?, after baseline: Date) -> Date? {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        if let weekday { comps.weekday = weekday }
        return cal.nextDate(after: baseline, matching: comps,
                             matchingPolicy: .nextTime, direction: .forward)
    }

    /// True if a scheduled run is currently due (and the scheduler should fire).
    func isDue(now: Date = Date(), lastRun: Date?) -> Bool {
        guard enabled else { return false }
        guard let next = nextRun(after: lastRun ?? Date.distantPast, lastRun: lastRun)
        else { return false }
        return now >= next
    }
}

// MARK: - Local Backup Profile

struct BackupProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var label: String
    var sourcePath: String
    var excludes: [String]
    var workers: Int
    var prefix: String
    var serverOverride: String
    var enabled: Bool

    // Scheduling (v1.2)
    var schedule: BackupSchedule = BackupSchedule()
    var lastRun: Date?
    var lastRunStatus: String?     // "done" / "failed" / "cancelled"

    init(name: String = "Novo Backup", label: String = "", sourcePath: String = "",
         excludes: [String] = [], workers: Int = 4, prefix: String = "",
         serverOverride: String = "", enabled: Bool = true,
         schedule: BackupSchedule = BackupSchedule(),
         lastRun: Date? = nil, lastRunStatus: String? = nil) {
        self.name = name; self.label = label; self.sourcePath = sourcePath
        self.excludes = excludes; self.workers = workers; self.prefix = prefix
        self.serverOverride = serverOverride; self.enabled = enabled
        self.schedule = schedule
        self.lastRun  = lastRun
        self.lastRunStatus = lastRunStatus
    }

    func cliCommand(defaultServer: String) -> String {
        let server = serverOverride.isEmpty ? defaultServer : serverOverride
        var parts = [
            "python backup_client.py backup \(sourcePath.isEmpty ? "<pasta>" : sourcePath)",
            "    --label \"\(label.isEmpty ? "<label>" : label)\"",
            "    --server \(server)",
            "    --workers \(workers)"
        ]
        if !prefix.isEmpty   { parts.append("    --prefix \(prefix)") }
        if !excludes.isEmpty { parts.append("    --exclude \(excludes.joined(separator: " "))") }
        return parts.joined(separator: " \\\n")
    }

    static func == (lhs: BackupProfile, rhs: BackupProfile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - ISO 8601 parser (handles both ISO and SQLite "YYYY-MM-DD HH:MM:SS")

func parseISO(_ s: String) -> Date? {
    let iso: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
        let c = ISO8601DateFormatter(); c.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return [a, b, c]
    }()
    for f in iso { if let d = f.date(from: s) { return d } }
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    df.locale = Locale(identifier: "en_US_POSIX")
    return df.date(from: s)
}
