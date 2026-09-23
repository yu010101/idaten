import Foundation

/// ⌘⇧E で Chromium へ渡すとき、そのサイトのログイン状態も持っていくための最小の仕組み。
///
/// 全部の Cookie を自動で移すことはしない。理由(調査 2026-09-23):
///  - `Storage.setCookies` は1件でも変換に失敗すると**全件入らず**、しかも保存が拒否されても成功が返る
///  - パーティション情報(CHIPS)は WebKit の公開APIから読めないので、正しく移せない
///  - 別エンジンから同じセッションを使うと、**元の WebKit 側のログインまで失効させる**サイトがありうる
/// なので Edge の IE モードと同じ形にする: **名前で指定した分だけ・一方向・既定は空**。
///
/// 変換規則は実測と一次資料で確かめたものだけを使う:
///  - `domain` はそのまま渡す(先頭ドットの有無が host-only かどうかを決める。触ると意味が変わる)
///  - `expires` は**秒**。`0` は「1970年に期限切れ」= 入れた瞬間に消えるので絶対に渡さない。
///    セッション Cookie はキーごと省略する
///  - `sameSite` は Lax / Strict のときだけ渡す。未指定(nil)は省略する
///    (実測 2026-09-23: WebKit は未指定を nil のまま返す。"none" には化けなかった)
///  - `partitionKey` / `priority` / `sourceScheme` / `sourcePort` / `url` は渡さない
struct CookieShare {
    /// 「このホストのこの名前の Cookie を持っていく」という指定。ワイルドカードは無い
    struct Rule: Codable, Equatable {
        /// host-only の Cookie 用(先頭ドット無し)。domain と排他
        var host: String?
        /// サブドメインにも送られる Cookie 用(先頭ドット付き)。host と排他
        var domain: String?
        var name: String
        var path: String?
    }

    /// 触らないサイト。金融・パスワード管理・Google は最初から外す
    /// (Google は端末に紐づく鍵でセッションを縛る仕組みがあり、移しても効かない上に元が失効しうる)
    static let excludedSuffixes = [
        "1password.com", "accounts.google.com", "google.com", "apple.com",
        "paypal.com", "stripe.com", "bank", "mufg.jp", "smbc.co.jp", "rakuten-bank.co.jp",
    ]

    static func isExcluded(host: String) -> Bool {
        let h = host.lowercased()
        return excludedSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    private(set) var rules: [Rule] = []
    private let path: URL

    init(path: URL) {
        self.path = path
        if let data = try? Data(contentsOf: path), let r = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = r
        }
    }

    func matches(host: String) -> [Rule] {
        let h = host.lowercased()
        return rules.filter { rule in
            if let host = rule.host { return h == host.lowercased() }
            if let domain = rule.domain {
                let d = domain.lowercased().hasPrefix(".") ? String(domain.dropFirst()).lowercased() : domain.lowercased()
                return h == d || h.hasSuffix("." + d)
            }
            return false
        }
    }

    /// そのホストの今ある Cookie を「名前で」登録する。値は保存しない(名前とドメインだけ)
    mutating func allow(host: String, cookies: [HTTPCookie]) {
        guard !Self.isExcluded(host: host) else { return }
        for c in cookies where c.domain.contains(host) || host.hasSuffix(c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain) {
            let rule = c.domain.hasPrefix(".")
                ? Rule(host: nil, domain: c.domain, name: c.name, path: c.path)
                : Rule(host: c.domain, domain: nil, name: c.name, path: c.path)
            if !rules.contains(rule) { rules.append(rule) }
        }
        save()
    }

    mutating func removeAll(host: String) {
        rules.removeAll { rule in
            let target = rule.host ?? rule.domain ?? ""
            let t = target.hasPrefix(".") ? String(target.dropFirst()) : target
            return host.lowercased() == t.lowercased() || host.lowercased().hasSuffix("." + t.lowercased())
        }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(rules) { try? data.write(to: path, options: .atomic) }
    }

    /// CDP の `Storage.setCookies` に渡す形へ変換する。変換できないものは黙って捨てず nil を返す
    static func toCDP(_ cookie: HTTPCookie) -> [String: Any]? {
        guard !cookie.name.isEmpty else { return nil }
        // __Host- は domain 属性を持てない。先頭ドット付きで渡すと保存が拒否される
        if cookie.name.hasPrefix("__Host-") && (cookie.domain.hasPrefix(".") || cookie.path != "/") { return nil }
        if cookie.name.hasPrefix("__Secure-") && !cookie.isSecure { return nil }
        var param: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,      // 先頭ドットの有無をそのまま活かす
            "path": cookie.path.isEmpty ? "/" : cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
        ]
        // 秒。0 を渡すと即座に期限切れになるので、無期限(セッション)はキーごと省略する
        if let expires = cookie.expiresDate, !cookie.isSessionOnly {
            let seconds = expires.timeIntervalSince1970
            if seconds > Date().timeIntervalSince1970 { param["expires"] = seconds }
        }
        // Lax / Strict のときだけ。未指定は省略(Chromium 側で Lax 相当の既定になる)。
        // "none" を機械的に転記すると、非 Secure では保存が拒否され、Secure では防御を勝手に緩める
        switch cookie.sameSitePolicy {
        case .some(.sameSiteLax): param["sameSite"] = "Lax"
        case .some(.sameSiteStrict): param["sameSite"] = "Strict"
        default: break
        }
        return param
    }
}
