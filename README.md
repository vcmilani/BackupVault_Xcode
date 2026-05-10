# NestVault — macOS Client

Native macOS SwiftUI client for the [backup_files](https://github.com/vcmilani/backup_files) self-hosted backup server.

---

## Requirements

| Item | Minimum |
|------|---------|
| macOS | 14.0 (Sonoma) |
| Xcode | 15.0 |
| Swift | 5.9 |
| Server | backup_files v2.6+ |

---

## Project Structure

```
NestVault_Xcode/
├── NestVaultClient.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/NestVaultClient.xcscheme
└── NestVaultClient/
    │
    ├── # Entry & Core
    ├── BackupVaultApp.swift       # App entry · MenuBarExtra · Settings scene
    ├── ContentView.swift          # Main window · fixed sidebar · NavigationSplitView
    ├── Models.swift               # All data models (v2.6 API contract + BackupSchedule)
    ├── APIService.swift           # Network layer · backoff-aware checkHealth · batch check
    ├── ConfigStore.swift          # Local profile persistence (UserDefaults)
    │
    ├── # Views
    ├── DashboardView.swift        # Global stats · system explanation
    ├── BackupsView.swift          # 3-panel browser: backups → versions → files
    ├── BackupConfigsView.swift    # Profile CRUD · ExcludesEditor · ScheduleEditor
    ├── CleanupView.swift          # Old version cleanup with preview
    ├── SettingsView.swift         # Server URL · API Key · startup · system status
    ├── MenuBarView.swift          # Compact menu bar panel
    ├── PlaceholderView.swift      # ContentUnavailableView substitute (macOS 13/14)
    │
    ├── # Backup Execution
    ├── BackupRunner.swift         # Single backup engine · binary upload · dock progress
    ├── BackupRunnerView.swift     # Execution sheet with live log and cancel
    ├── BackupQueue.swift          # Sequential queue engine
    ├── BackupQueueView.swift      # Queue sheet with selection UI and per-item progress
    │
    ├── # Scheduling & System
    ├── ScheduleManager.swift      # Timer-based scheduler · respects power/network
    ├── ScheduleEditor.swift       # Schedule editor (Hourly/Daily/Weekly/Custom)
    ├── LoginItemManager.swift     # SMAppService wrapper for auto-start
    ├── PowerMonitor.swift         # Battery + network interface monitoring
    ├── BackoffPolicy.swift        # Exponential backoff for failed connections
    ├── DockProgress.swift         # Dock tile progress bar during backups
    │
    ├── # Utilities
    ├── L10n.swift                 # L("key") helper for non-view contexts
    ├── LegacyMigration.swift      # One-time migration from com.vcm.backupvault.app
    │
    ├── # Localization
    ├── en.lproj/Localizable.strings
    ├── pt-BR.lproj/Localizable.strings
    │
    └── # Resources
        ├── Info.plist             # ATS · NSLocalNetworkUsageDescription
        └── Assets.xcassets/AppIcon.appiconset/
```

---

## Setup

1. Open `NestVaultClient.xcodeproj` in Xcode
2. In **Signing & Capabilities**, select your Team
3. In **Assets.xcassets → AppIcon**, enable *Single Size* and drag a 1024×1024 PNG
4. ⌘R to run

**Bundle ID:** `com.vcm.nestvaultclient.app`

---

## Features

### Dashboard
- Cards: total backups, versions, files, and storage
- List of active backups with size and last version date
- Explanation panel: SHA-256 deduplication, versioning, label isolation, snapshots
- Alert banner when the server is unreachable

### Backups (Server Browser)
- 3-panel `HStack` layout: backups → versions → files
- Filter by backup label and file name
- File table with SHA-256, status, size
- Delete individual version via context menu

### My Backups (Local Profiles)
- Create and manage local backup profiles
- Each profile: name, label, source folder, server override, workers, prefix, excludes, schedule
- Native folder picker (`NSOpenPanel` via `panel.begin`)
- 4-tab editor: General / Server / Schedule / Exclusions
- Run individual backup (sheet with live log)
- Run queue with selection UI and per-item progress
- Delete backup from server (context menu)
- Python equivalent command preview

### Scheduling
- 5 modes: **Disabled / Hourly / Daily / Weekly / Custom (minutes)**
- Daily and Weekly respect a configured time-of-day
- Weekly also respects day of week
- Custom supports 5–10080 minutes
- `ScheduleManager` checks every 30s with a `Timer`
- Respects network reachability, battery state, and active backup lock
- Shows next run date in editor and last run time in detail view

### Cleanup
- Mode: all backups or specific label
- Keep N most recent versions (default: 5)
- Per-label preview table before executing
- Mandatory confirmation alert
- Detailed results: versions removed + storage files freed

### Menu Bar (`MenuBarExtra`)
- Connection indicator icon
- Compact panel: status, 3 mini-stats, 5 recent backups
- Quick actions: Open NestVault · Settings · Quit

### Settings
- **General tab:** Login Item (start with macOS via `SMAppService`), network status, power source, backoff info
- **Server tab:** Server URL and API Key, test connection, tips
- **About tab:** version, links to Swagger UI and GitHub

---

## API Contract (v2.6)

### Endpoints

| Method | Endpoint | Usage |
|--------|----------|-------|
| `GET` | `/health` | Check connection (backoff-aware) |
| `GET` | `/backups` | List backups with `version_count`, `file_count`, `total_size_bytes` |
| `GET` | `/backups/{label}/versions` | List versions |
| `GET` | `/files?backup_label=&version_key=` | List files |
| `POST` | `/backups` | Create backup (`label`, `client_name`) |
| `POST` | `/backups/{label}/versions` | Create version (`version_key`) |
| `POST` | `/check` | Check single file: returns `needs_upload`, `content_exists` |
| `POST` | `/check/batch` | Check up to 100 files in one request (v2.6+) |
| `POST` | `/upload` | Upload file (binary) or register (header only) |
| `POST` | `/sync` | Mark absent files as deleted (`existing_paths`) |
| `PATCH` | `/backups/{label}/versions/{key}` | Finalize version (`status: done/failed`) |
| `POST` | `/backups/{label}/cleanup` | Remove old versions (`keep`) |
| `DELETE` | `/backups/{label}/versions/{key}` | Delete version |
| `DELETE` | `/backups/{label}` | Delete entire backup |

### Upload Protocol

**New content** (`content_exists = false`):
```
POST /upload
Content-Type: application/octet-stream
X-Backup-Label:   <label>
X-Version-Key:    <version_key>
X-Original-Path:  <path base64>
X-Mtime:          <epoch float>

<raw file bytes>
```

**Already in storage** (`content_exists = true`):
```
POST /upload
X-Backup-Label:    <label>
X-Version-Key:     <version_key>
X-Original-Path:   <path base64>
X-Content-Sha256:  <sha256>
X-Mtime:           <epoch float>
(no body)
```

---

## Backup Engine

The `BackupRunner` performs backups in two phases:

**Phase 1 — Classify**
1. Walk the source directory once using `FileManager.enumerator` with `includingPropertiesForKeys` (`mtime`, `size`, `isDirectory`) — a single kernel `getattrlistbulk` pass.
2. Files matching the previous version's `mtime + size` are fast-tracked (no re-hash).
3. Remaining files are SHA-256 hashed in parallel.
4. Hashed files are classified via `POST /check/batch` (up to 100 files per request).

**Phase 2 — Execute**
- Files marked `skip`: ignored.
- Files marked `register`: `POST /upload` with SHA-256 header only (no body).
- Files marked `upload`: `POST /upload` with binary body.
- Configurable concurrency (`workers`), exponential retry (3 attempts).

---

## Local Persistence

| Key | Content |
|-----|---------|
| `server_url` | Server URL |
| `api_key` | API Key |
| `backupProfiles_v1` | JSON array of `BackupProfile` (includes `BackupSchedule`, `lastRun`) |
| `schedule.pauseOnBattery` | Bool — pause when on battery |
| `schedule.minBatteryPercent` | Int — minimum battery level to run |

---

## macOS Permissions

Declared in `Info.plist`:
- `NSLocalNetworkUsageDescription` — required on macOS 15+ for local network access
- `NSAppTransportSecurity` with `NSAllowsLocalNetworking` — allows HTTP on local IPs

On first connection, macOS will prompt for local network permission — click **Allow**.

---

## Localization

The app automatically uses the system language. Supported: **English** (default) and **Brazilian Portuguese**.

Files: `en.lproj/Localizable.strings` and `pt-BR.lproj/Localizable.strings`.

---

## Server Quick Start

```bash
cd backup_files/server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export BACKUP_API_KEY="your-key"
export STORAGE_DIR="/mnt/external/backups"
export DB_PATH="/mnt/external/backup.db"

uvicorn main:app --host 0.0.0.0 --port 8000
```

Web dashboard: `http://<pi-ip>:8000/`  
Swagger UI: `http://<pi-ip>:8000/docs`

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Error `-1009` | Local network permission denied | System Settings → Privacy → Local Network → enable NestVault |
| `BadRequest` on upload | Server older than v2.1 | Update server to v2.6+ |
| Keys shown raw (e.g. `menubar.open`) | Localizable.strings not in bundle | Verify `Localizable.strings` is in target Resources build phase |
| Schedule not running | Battery mode or network | Check Settings → General → System Status |
| `requiresApproval` on Login Item | macOS needs user consent | Click "Open Settings" in Settings → General |
| Connection refused | Server offline | `systemctl status backup-server` on the Pi |
