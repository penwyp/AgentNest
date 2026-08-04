import Foundation
import SQLite3

public struct HistoryPoint: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let cpuFraction: Double?
    public let diskReadBytesPerSecond: Double?
    public let diskWriteBytesPerSecond: Double?
    public let networkReceiveBytesPerSecond: Double?
    public let networkSendBytesPerSecond: Double?
    public let coverage: Double

    public init(
        capturedAt: Date,
        cpuFraction: Double?,
        diskReadBytesPerSecond: Double?,
        diskWriteBytesPerSecond: Double?,
        networkReceiveBytesPerSecond: Double?,
        networkSendBytesPerSecond: Double?,
        coverage: Double
    ) {
        self.capturedAt = capturedAt
        self.cpuFraction = cpuFraction
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkReceiveBytesPerSecond = networkReceiveBytesPerSecond
        self.networkSendBytesPerSecond = networkSendBytesPerSecond
        self.coverage = coverage
    }
}

public enum HistoryStoreError: Error {
    case openFailed(String)
    case statementFailed(String)
    case disabled
}

public actor HistoryStore {
    private let fileURL: URL
    private let budgetBytes: UInt64
    private var retentionDays: Int
    private let clock: @Sendable () -> Date
    // SQLite is configured FULLMUTEX and all access is additionally serialized by this actor.
    nonisolated(unsafe) private var database: OpaquePointer?
    private var enabled = false

    public init(
        fileURL: URL,
        budgetBytes: UInt64 = 64 * 1_024 * 1_024,
        retentionDays: Int = 365,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.budgetBytes = min(max(budgetBytes, 32 * 1_024 * 1_024), 160 * 1_024 * 1_024)
        self.retentionDays = min(max(retentionDays, 7), 365)
        self.clock = clock
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func setEnabled(_ value: Bool) throws {
        if value {
            guard !enabled else { return }
            try openIfNeeded()
            enabled = true
            try prune()
        } else {
            enabled = false
            if let database { sqlite3_close(database); self.database = nil }
        }
    }

    @discardableResult
    public func setRetentionDays(_ days: Int) throws -> Int {
        retentionDays = min(max(days, 7), 365)
        if enabled {
            try openIfNeeded()
            try prune()
        }
        return retentionDays
    }

    public func append(_ snapshot: ActivitySnapshot) throws {
        guard enabled else { throw HistoryStoreError.disabled }
        try openIfNeeded()
        let sql = """
        INSERT INTO activity_samples(
          captured_at, cpu_fraction, disk_read_bps, disk_write_bps,
          network_receive_bps, network_send_bps, coverage
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw statementError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, snapshot.capturedAt.timeIntervalSince1970)
        bind(snapshot.cpuFraction.value, to: statement, index: 2)
        bind(snapshot.diskReadBytesPerSecond.value, to: statement, index: 3)
        bind(snapshot.diskWriteBytesPerSecond.value, to: statement, index: 4)
        bind(snapshot.networkReceiveBytesPerSecond.value, to: statement, index: 5)
        bind(snapshot.networkSendBytesPerSecond.value, to: statement, index: 6)
        let coverage = [
            snapshot.cpuFraction.coverage,
            snapshot.diskReadBytesPerSecond.coverage,
            snapshot.diskWriteBytesPerSecond.coverage,
            snapshot.networkReceiveBytesPerSecond.coverage,
            snapshot.networkSendBytesPerSecond.coverage,
        ].reduce(0, +) / 5
        sqlite3_bind_double(statement, 7, coverage)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
        try prune()
    }

    public func points(from start: Date, to end: Date) throws -> [HistoryPoint] {
        guard enabled else { throw HistoryStoreError.disabled }
        try openIfNeeded()
        let sql = """
        SELECT captured_at, cpu_fraction, disk_read_bps, disk_write_bps,
               network_receive_bps, network_send_bps, coverage FROM (
          SELECT captured_at, cpu_fraction, disk_read_bps, disk_write_bps,
                 network_receive_bps, network_send_bps, coverage
          FROM activity_samples
          UNION ALL
          SELECT bucket_at AS captured_at, cpu_fraction, disk_read_bps, disk_write_bps,
                 network_receive_bps, network_send_bps, coverage
          FROM activity_rollups
        ) WHERE captured_at >= ? AND captured_at <= ? ORDER BY captured_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw statementError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var result: [HistoryPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(HistoryPoint(
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                cpuFraction: optionalDouble(statement, 1),
                diskReadBytesPerSecond: optionalDouble(statement, 2),
                diskWriteBytesPerSecond: optionalDouble(statement, 3),
                networkReceiveBytesPerSecond: optionalDouble(statement, 4),
                networkSendBytesPerSecond: optionalDouble(statement, 5),
                coverage: sqlite3_column_double(statement, 6)
            ))
        }
        return result
    }

    public func exportCSV(from start: Date, to end: Date) throws -> Data {
        let points = try points(from: start, to: end)
        var lines = ["schema_version,captured_at,cpu_fraction,disk_read_bps,disk_write_bps,network_receive_bps,network_send_bps,coverage"]
        let formatter = ISO8601DateFormatter()
        for point in points {
            lines.append([
                "1", formatter.string(from: point.capturedAt), csv(point.cpuFraction), csv(point.diskReadBytesPerSecond),
                csv(point.diskWriteBytesPerSecond), csv(point.networkReceiveBytesPerSecond), csv(point.networkSendBytesPerSecond),
                String(point.coverage),
            ].joined(separator: ","))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public func stopAndDelete() throws {
        enabled = false
        if let database { sqlite3_close(database); self.database = nil }
        for url in [fileURL, URL(fileURLWithPath: fileURL.path + "-wal"), URL(fileURLWithPath: fileURL.path + "-shm")] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var opened: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else { throw HistoryStoreError.openFailed("sqlite_open") }
        database = opened
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = fileURL
            try mutableURL.setResourceValues(resourceValues)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("""
            CREATE TABLE IF NOT EXISTS activity_samples(
              captured_at REAL PRIMARY KEY,
              cpu_fraction REAL,
              disk_read_bps REAL,
              disk_write_bps REAL,
              network_receive_bps REAL,
              network_send_bps REAL,
              coverage REAL NOT NULL
            ) WITHOUT ROWID
            """)
            try execute("""
            CREATE TABLE IF NOT EXISTS activity_rollups(
              bucket_at REAL NOT NULL,
              resolution_seconds INTEGER NOT NULL,
              cpu_fraction REAL,
              disk_read_bps REAL,
              disk_write_bps REAL,
              network_receive_bps REAL,
              network_send_bps REAL,
              coverage REAL NOT NULL,
              PRIMARY KEY(bucket_at, resolution_seconds)
            ) WITHOUT ROWID
            """)
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    private func prune() throws {
        let now = clock()
        let minuteCutoff = Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970)
        let quarterHourCutoff = Int64(now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
        let retentionCutoff = Int64(now.addingTimeInterval(TimeInterval(-retentionDays * 86_400)).timeIntervalSince1970)
        try execute("""
        INSERT OR REPLACE INTO activity_rollups
        SELECT CAST(captured_at / 900 AS INTEGER) * 900, 900,
               AVG(cpu_fraction), AVG(disk_read_bps), AVG(disk_write_bps),
               AVG(network_receive_bps), AVG(network_send_bps), AVG(coverage)
        FROM activity_samples WHERE captured_at < \(minuteCutoff)
        GROUP BY CAST(captured_at / 900 AS INTEGER)
        """)
        try execute("DELETE FROM activity_samples WHERE captured_at < \(minuteCutoff)")
        try execute("""
        INSERT OR REPLACE INTO activity_rollups
        SELECT CAST(bucket_at / 3600 AS INTEGER) * 3600, 3600,
               AVG(cpu_fraction), AVG(disk_read_bps), AVG(disk_write_bps),
               AVG(network_receive_bps), AVG(network_send_bps), AVG(coverage)
        FROM activity_rollups WHERE resolution_seconds = 900 AND bucket_at < \(quarterHourCutoff)
        GROUP BY CAST(bucket_at / 3600 AS INTEGER)
        """)
        try execute("DELETE FROM activity_rollups WHERE resolution_seconds = 900 AND bucket_at < \(quarterHourCutoff)")
        try execute("DELETE FROM activity_rollups WHERE bucket_at < \(retentionCutoff)")
        try execute("PRAGMA wal_checkpoint(PASSIVE)")
        let size = databaseSize()
        if size > budgetBytes {
            try execute("DELETE FROM activity_samples WHERE captured_at IN (SELECT captured_at FROM activity_samples ORDER BY captured_at LIMIT (SELECT COUNT(*) / 2 FROM activity_samples))")
            try execute("DELETE FROM activity_rollups WHERE (bucket_at, resolution_seconds) IN (SELECT bucket_at, resolution_seconds FROM activity_rollups ORDER BY bucket_at LIMIT (SELECT COUNT(*) / 2 FROM activity_rollups))")
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try execute("VACUUM")
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw statementError() }
    }

    private func bind(_ value: Double?, to statement: OpaquePointer?, index: Int32) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    private func optionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func csv(_ value: Double?) -> String { value.map { String($0) } ?? "" }

    private func statementError() -> HistoryStoreError {
        HistoryStoreError.statementFailed(database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "sqlite")
    }

    private func databaseSize() -> UInt64 {
        [fileURL.path, fileURL.path + "-wal", fileURL.path + "-shm"].reduce(0) { result, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return result &+ ((attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }
}
