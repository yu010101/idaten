import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 閲覧履歴。URLバーの補完に使う。プロファイルごとに別ファイル
final class History {
    private var db: OpaquePointer?

    init(path: URL) {
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { db = nil; return }
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

    /// 新しいタブに出す「よく見るサイト」。同じサイトは1つにまとめ、訪問回数の多い順
    func topSites(limit: Int = 8) -> [(url: String, title: String, count: Int)] {
        guard let db else { return [] }
        var st: OpaquePointer?
        // ホストごとにまとめ、そのホストで一番よく開いたページを代表にする
        let sql = """
            SELECT url, MAX(title), COUNT(*) c FROM visits
            WHERE url LIKE 'http%'
            GROUP BY url ORDER BY c DESC, MAX(ts) DESC LIMIT ?
            """
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int(st, 1, Int32(limit * 3))
        var seenHost = Set<String>()
        var out: [(String, String, Int)] = []
        while sqlite3_step(st) == SQLITE_ROW, out.count < limit {
            let u = String(cString: sqlite3_column_text(st, 0))
            let t = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            let c = Int(sqlite3_column_int(st, 2))
            guard let host = URL(string: u)?.host, seenHost.insert(host).inserted else { continue }
            out.append((u, t.isEmpty ? host : t, c))
        }
        return out
    }

    /// 履歴の一覧(新しい順)。検索語があれば URL か題名に含むものだけ
    func recent(matching text: String = "", limit: Int = 300) -> [(url: String, title: String, at: Date)] {
        guard let db else { return [] }
        var st: OpaquePointer?
        let sql = text.isEmpty
            ? "SELECT url, title, ts FROM visits ORDER BY ts DESC LIMIT ?"
            : "SELECT url, title, ts FROM visits WHERE url LIKE ? OR title LIKE ? ORDER BY ts DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var bind: Int32 = 1
        if !text.isEmpty {
            let like = "%" + text.replacingOccurrences(of: "%", with: "") + "%"
            sqlite3_bind_text(st, 1, like, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(st, 2, like, -1, SQLITE_TRANSIENT)
            bind = 3
        }
        sqlite3_bind_int(st, bind, Int32(limit))
        var out: [(String, String, Date)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let u = String(cString: sqlite3_column_text(st, 0))
            let t = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            out.append((u, t, Date(timeIntervalSince1970: sqlite3_column_double(st, 2))))
        }
        return out
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
