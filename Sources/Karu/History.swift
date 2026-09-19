import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 閲覧履歴。URLバーの補完に使う
final class History {
    private var db: OpaquePointer?

    init() {
        guard sqlite3_open(Paths.history.path, &db) == SQLITE_OK else { db = nil; return }
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS visits(id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT, ts REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS visits_ts ON visits(ts);
            """, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    func record(url: URL, title: String?) {
        guard let db, url.scheme == "http" || url.scheme == "https" else { return }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO visits(url,title,ts) VALUES(?,?,?)", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, url.absoluteString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(st, 2, title ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(st, 3, Date().timeIntervalSince1970)
        sqlite3_step(st)
    }

    /// 入力の前方・部分一致で、訪問回数の多い順に返す
    func suggest(_ text: String, limit: Int = 6) -> [(url: String, title: String)] {
        guard let db, !text.isEmpty else { return [] }
        var st: OpaquePointer?
        let sql = "SELECT url, MAX(title), COUNT(*) c FROM visits WHERE url LIKE ? OR title LIKE ? GROUP BY url ORDER BY c DESC, MAX(ts) DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        let like = "%" + text.replacingOccurrences(of: "%", with: "") + "%"
        sqlite3_bind_text(st, 1, like, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(st, 2, like, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(st, 3, Int32(limit))
        var out: [(String, String)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let u = String(cString: sqlite3_column_text(st, 0))
            let t = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            out.append((u, t))
        }
        return out
    }
}
