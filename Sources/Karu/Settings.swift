import Foundation

/// 個人パスを埋め込まない。利用者ごとのデータは全部ここの下に置く(配布に耐える構造)
enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Karu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var engineRules: URL { support.appendingPathComponent("engine_rules.json") }
    static var engineConfig: URL { support.appendingPathComponent("engine.json") }
    static var chromiumFlags: URL { support.appendingPathComponent("chromium_flags.txt") }
    static var chromiumProfile: URL { support.appendingPathComponent("chromium-profile", isDirectory: true) }
    static var history: URL { support.appendingPathComponent("history.sqlite") }
    static var session: URL { support.appendingPathComponent("session.json") }
    static var rulesDir: URL {
        let d = support.appendingPathComponent("rules", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

struct Settings: Codable {
    var searchURL = "https://www.google.com/search?q=%@"
    var homepage = "about:blank"
    /// 非アクティブがこの分数を超えたタブは WKWebView を破棄する。0 で休眠しない
    var hibernateMinutes = 10
    /// WKWebView 既定のUAには Version/Safari が無く、一部サイトが簡易版を返す
    var userAgentSuffix = "Version/26.0 Safari/605.1.15"
    var adBlockEnabled = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        searchURL = try c.decodeIfPresent(String.self, forKey: .searchURL) ?? d.searchURL
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage) ?? d.homepage
        hibernateMinutes = try c.decodeIfPresent(Int.self, forKey: .hibernateMinutes) ?? d.hibernateMinutes
        userAgentSuffix = try c.decodeIfPresent(String.self, forKey: .userAgentSuffix) ?? d.userAgentSuffix
        adBlockEnabled = try c.decodeIfPresent(Bool.self, forKey: .adBlockEnabled) ?? d.adBlockEnabled
    }

    static func load() -> Settings {
        if let data = try? Data(contentsOf: Paths.settings),
           let s = try? JSONDecoder().decode(Settings.self, from: data) { return s }
        let s = Settings()
        s.save()   // 初回は既定値を書き出し、手で編集できるようにする
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(self) { try? data.write(to: Paths.settings, options: .atomic) }
    }
}

/// 入力文字列を URL か検索に振り分ける
func resolveInput(_ raw: String, searchURL: String) -> URL? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    if let u = URL(string: s), let scheme = u.scheme, ["http", "https", "file", "about"].contains(scheme) { return u }
    let looksLikeHost = !s.contains(" ") && (s.contains(".") || s.hasPrefix("localhost"))
    if looksLikeHost, let u = URL(string: "https://" + s) { return u }
    let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? s
    return URL(string: searchURL.replacingOccurrences(of: "%@", with: q))
}
