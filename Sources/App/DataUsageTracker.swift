import Foundation
import SQLite3

/// Accumulates bytes transferred into per-day buckets (download & upload),
/// persisted in a small SQLite database, so we can report today / this-month
/// usage and a day-by-day history.
///
/// Note: this counts machine-wide traffic seen while the app is running — the
/// same per-interface counters that drive the live speed readout. It starts
/// counting from app launch (we can't recover traffic from before we were
/// observing), and like the speed meter it is not per-app.
///
/// Storage: `~/Library/Application Support/WhatsMyIP/usage.sqlite`, one row per
/// day. Writes are batched — `record()` accumulates in memory and `flush()`
/// upserts to disk, so we don't hit the DB every couple of seconds.
final class DataUsageTracker {

    private var db: OpaquePointer?
    private let dbURL: URL

    /// In-memory accumulation since the last flush, attributed to `pendingDay`.
    private var pendingDay: String
    private var pendingDownload: UInt64 = 0
    private var pendingUpload: UInt64 = 0
    private var dirty = false

    /// Keep a bit over a year so the history view always has full months.
    private let retentionDays = 400

    init() {
        dbURL = Self.databaseURL()
        pendingDay = Self.dayKey(for: Date())
        openDatabase()
        createSchema()
        migrateFromUserDefaultsIfNeeded()
        pruneOldRows()
    }

    deinit {
        flush()
        if let db { sqlite3_close(db) }
    }

    // MARK: - Recording

    /// Add a sample interval's bytes to today's in-memory bucket. Cheap;
    /// persistence is deferred to `flush()`.
    func record(download: UInt64, upload: UInt64) {
        guard download > 0 || upload > 0 else { return }
        let today = Self.dayKey(for: Date())
        // Day rolled over since the last sample: persist the old day first.
        if today != pendingDay {
            flush()
            pruneOldRows()
            pendingDay = today
        }
        pendingDownload += download
        pendingUpload += upload
        dirty = true
    }

    /// Persist pending bytes into the DB. Safe to call often; no-op if clean.
    func flush() {
        guard dirty else { return }
        upsert(day: pendingDay, download: pendingDownload, upload: pendingUpload)
        pendingDownload = 0
        pendingUpload = 0
        dirty = false
    }

    // MARK: - Totals (include not-yet-flushed pending bytes so the UI is live)

    var todayDownload: UInt64 {
        let day = Self.dayKey(for: Date())
        return dbSum(where: "day = ?", bind: day).download + pending(forDay: day).download
    }
    var todayUpload: UInt64 {
        let day = Self.dayKey(for: Date())
        return dbSum(where: "day = ?", bind: day).upload + pending(forDay: day).upload
    }
    var monthDownload: UInt64 {
        let prefix = Self.monthPrefix(for: Date())
        return dbSum(where: "day LIKE ?", bind: prefix + "%").download + pending(forMonth: prefix).download
    }
    var monthUpload: UInt64 {
        let prefix = Self.monthPrefix(for: Date())
        return dbSum(where: "day LIKE ?", bind: prefix + "%").upload + pending(forMonth: prefix).upload
    }

    private func pending(forDay day: String) -> (download: UInt64, upload: UInt64) {
        (dirty && pendingDay == day) ? (pendingDownload, pendingUpload) : (0, 0)
    }
    private func pending(forMonth prefix: String) -> (download: UInt64, upload: UInt64) {
        (dirty && pendingDay.hasPrefix(prefix)) ? (pendingDownload, pendingUpload) : (0, 0)
    }

    // MARK: - History (flush first so the DB is authoritative, then query)

    /// Per-day totals, newest first. Each entry: (day "yyyy-MM-dd", down, up).
    func recentDays(_ count: Int) -> [(day: String, download: UInt64, upload: UInt64)] {
        flush()
        guard let db else { return [] }
        var rows: [(day: String, download: UInt64, upload: UInt64)] = []
        var stmt: OpaquePointer?
        let sql = "SELECT day, download, upload FROM daily_usage ORDER BY day DESC LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(count))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            rows.append((String(cString: c),
                         UInt64(max(0, sqlite3_column_int64(stmt, 1))),
                         UInt64(max(0, sqlite3_column_int64(stmt, 2)))))
        }
        return rows
    }

    /// Per-month totals, newest first. Each entry: (month "yyyy-MM", down, up).
    func monthlyTotals() -> [(month: String, download: UInt64, upload: UInt64)] {
        flush()
        guard let db else { return [] }
        var rows: [(month: String, download: UInt64, upload: UInt64)] = []
        var stmt: OpaquePointer?
        let sql = "SELECT substr(day,1,7) AS m, SUM(download), SUM(upload) FROM daily_usage GROUP BY m ORDER BY m DESC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            rows.append((String(cString: c),
                         UInt64(max(0, sqlite3_column_int64(stmt, 1))),
                         UInt64(max(0, sqlite3_column_int64(stmt, 2)))))
        }
        return rows
    }

    // MARK: - SQLite plumbing

    private func openDatabase() {
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            db = nil
            return
        }
        // WAL + NORMAL keeps the frequent small writes cheap and crash-safe.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
    }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS daily_usage (
            day      TEXT PRIMARY KEY,
            download INTEGER NOT NULL DEFAULT 0,
            upload   INTEGER NOT NULL DEFAULT 0
        );
        """)
    }

    private func upsert(day: String, download: UInt64, upload: UInt64) {
        guard let db, download > 0 || upload > 0 else { return }
        let sql = """
        INSERT INTO daily_usage(day, download, upload) VALUES(?,?,?)
        ON CONFLICT(day) DO UPDATE SET
            download = download + excluded.download,
            upload   = upload   + excluded.upload;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, day, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(clamping: download))
        sqlite3_bind_int64(stmt, 3, Int64(clamping: upload))
        sqlite3_step(stmt)
    }

    /// SUM(download/upload) over rows matching a single bound predicate.
    private func dbSum(where clause: String, bind value: String) -> (download: UInt64, upload: UInt64) {
        guard let db else { return (0, 0) }
        let sql = "SELECT COALESCE(SUM(download),0), COALESCE(SUM(upload),0) FROM daily_usage WHERE \(clause);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, value, -1, Self.SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (UInt64(max(0, sqlite3_column_int64(stmt, 0))),
                UInt64(max(0, sqlite3_column_int64(stmt, 1))))
    }

    private func pruneOldRows() {
        guard let db,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
        else { return }
        let cutoffKey = Self.dayKey(for: cutoff)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM daily_usage WHERE day < ?;", -1, &stmt, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cutoffKey, -1, Self.SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// One-time import of any data left over from the old UserDefaults store.
    private func migrateFromUserDefaultsIfNeeded() {
        let key = "dataUsageStore.v1"
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key) else { return }
        struct LegacyStore: Codable { var download: [String: UInt64]; var upload: [String: UInt64] }
        if let legacy = try? JSONDecoder().decode(LegacyStore.self, from: data) {
            let days = Set(legacy.download.keys).union(legacy.upload.keys)
            for day in days {
                upsert(day: day, download: legacy.download[day] ?? 0, upload: legacy.upload[day] ?? 0)
            }
        }
        defaults.removeObject(forKey: key) // import once, then forget it
    }

    // MARK: - Formatting

    /// "1.2 GB", "340 MB" — for cumulative totals (1024-based, matching the
    /// live speed readout).
    static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    // MARK: - Paths & date keys

    private static func databaseURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("WhatsMyIP", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.sqlite")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayKey(for date: Date) -> String { dayFormatter.string(from: date) }
    private static func monthPrefix(for date: Date) -> String { String(dayKey(for: date).prefix(7)) }

    /// SQLite's "make a private copy of this text" sentinel (not exposed to Swift).
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
