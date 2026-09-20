import Foundation
import SQLite3

/// Chromeから「すんなり移管」するための一式。読むだけで、Chrome側のファイルは一切変更しない。
/// パスワードは対象外(macOS Keychainの暗号化に依存し、安全に横取りする手段が無い。
/// Karu側で必要ならOS標準のパスワード管理・Keychainをそのまま使う運用にする)。
enum ChromeImport {
    struct ChromeProfile { var dirName: String; var displayName: String; var email: String }

    private static var chromeRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Google/Chrome", isDirectory: true)
    }

    /// Local State の profile.info_cache から、実際に使われているプロファイルの一覧を得る。
    /// 拡張ゼロ・アカウント分離だけのプロファイルも移行対象に含める(実測でそれが過半数を占めていたため)
    static func availableProfiles() -> [ChromeProfile] {
        guard let data = try? Data(contentsOf: chromeRoot.appendingPathComponent("Local State")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = obj["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        return cache.compactMap { dir, v -> ChromeProfile? in
            guard let info = v as? [String: Any] else { return nil }
            let name = (info["name"] as? String) ?? dir
            let email = (info["user_name"] as? String) ?? ""
            return ChromeProfile(dirName: dir, displayName: name, email: email)
        }.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - ブックマーク

    /// Chromeの Bookmarks はJSONで、bookmark_bar/other/synced の3ルート配下に folder/url ノードが木構造で入る
    static func readBookmarks(profileDir: String) -> [(title: String, url: String, folder: String)] {
        let path = chromeRoot.appendingPathComponent(profileDir).appendingPathComponent("Bookmarks")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = obj["roots"] as? [String: Any] else { return [] }
        var out: [(String, String, String)] = []
        func walk(_ node: [String: Any], folder: String) {
            let type = node["type"] as? String
            if type == "url", let url = node["url"] as? String {
                out.append((node["name"] as? String ?? url, url, folder))
            } else if type == "folder", let children = node["children"] as? [[String: Any]] {
                let name = node["name"] as? String ?? folder
                for c in children { walk(c, folder: name) }
            }
        }
        for (rootName, root) in roots {
            guard let node = root as? [String: Any] else { continue }
            walk(node, folder: rootName)
        }
        return out
    }

    // MARK: - 履歴

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Chromeのタイムスタンプは 1601-01-01 からのマイクロ秒。Unix epoch(1970-01-01)との差は11644473600秒
    private static func chromeTimeToUnix(_ v: Int64) -> Double { Double(v) / 1_000_000 - 11_644_473_600 }

    /// Chromeは起動中 History をロックするので、一旦コピーしてから読む(Chrome側には一切触れない)
    @discardableResult
    static func importHistory(profileDir: String, into historyPath: URL) -> Int {
        let src = chromeRoot.appendingPathComponent(profileDir).appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: src.path) else { return 0 }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil else { return 0 }
        defer { try? FileManager.default.removeItem(at: tmp) }

        var srcDB: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &srcDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(srcDB) }

        var dstDB: OpaquePointer?
        guard sqlite3_open(historyPath.path, &dstDB) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(dstDB) }
        sqlite3_exec(dstDB, "CREATE TABLE IF NOT EXISTS visits(id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT, ts REAL NOT NULL);", nil, nil, nil)

        var stmt: OpaquePointer?
        // visit_count を回数として展開せず、代表1件+回数を反映した重み(URLバー補完のCOUNT(*)集計と相性が良い)にする
        guard sqlite3_prepare_v2(srcDB, "SELECT url, title, last_visit_time, visit_count FROM urls", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        var insert: OpaquePointer?
        sqlite3_prepare_v2(dstDB, "INSERT INTO visits(url,title,ts) VALUES(?,?,?)", -1, &insert, nil)
        defer { sqlite3_finalize(insert) }

        var imported = 0
        sqlite3_exec(dstDB, "BEGIN", nil, nil, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlC = sqlite3_column_text(stmt, 0) else { continue }
            let url = String(cString: urlC)
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }   // chrome-extension:// 等は除外
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let ts = chromeTimeToUnix(sqlite3_column_int64(stmt, 2))
            let visitCount = max(1, Int(sqlite3_column_int(stmt, 3)))
            sqlite3_reset(insert)
            sqlite3_bind_text(insert, 1, url, -1, sqliteTransient)
            sqlite3_bind_text(insert, 2, title, -1, sqliteTransient)
            sqlite3_bind_double(insert, 3, ts)
            if sqlite3_step(insert) == SQLITE_DONE { imported += 1 }
            _ = visitCount   // URLバー補完の並びは訪問回数でなく最終アクセス日時を主に使う設計のため、複製はしない
        }
        sqlite3_exec(dstDB, "COMMIT", nil, nil, nil)
        return imported
    }

    // MARK: - 拡張機能チェックリスト(Chromiumタブへ渡した後、自分で入れ直す必要があるものの一覧)

    static func extensionNames(profileDir: String) -> [String] {
        let extDir = chromeRoot.appendingPathComponent(profileDir).appendingPathComponent("Extensions")
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: extDir.path) else { return [] }
        var names: [String] = []
        for id in ids {
            let idDir = extDir.appendingPathComponent(id)
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: idDir.path) else { continue }
            for v in versions {
                let manifest = idDir.appendingPathComponent(v).appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifest),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      var name = obj["name"] as? String else { continue }
                if name.hasPrefix("__MSG_") { name = resolveLocalizedName(name, extensionDir: idDir.appendingPathComponent(v)) ?? id }
                if !name.hasPrefix("__MSG_") && !names.contains(name) { names.append(name) }
                break   // バージョンディレクトリは1つ見れば十分
            }
        }
        return names.sorted()
    }

    private static func resolveLocalizedName(_ msgName: String, extensionDir: URL) -> String? {
        let key = String(msgName.dropFirst(6).dropLast(2))   // "__MSG_xxx__" -> "xxx"
        for loc in ["en", "en_US", "ja"] {
            let f = extensionDir.appendingPathComponent("_locales/\(loc)/messages.json")
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = obj[key] as? [String: Any], let message = entry["message"] as? String else { continue }
            return message
        }
        return nil
    }
}
