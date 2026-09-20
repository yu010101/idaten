import Foundation

/// 個人パスを埋め込まない。利用者ごとのデータは全部ここの下に置く(配布に耐える構造)。
/// ここにあるのは**プロファイル非依存**のもの(広告フィルタ本体・Chromium候補設定・起動フラグ・アプリ全体設定・
/// プロファイル一覧そのもの)だけ。Cookie・履歴・セッション・エンジンルールはプロファイルごとに分かれるので
/// `ProfilePaths`(Profile.swift)を使う
enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Idaten", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var engineConfig: URL { support.appendingPathComponent("engine.json") }
    static var chromiumFlags: URL { support.appendingPathComponent("chromium_flags.txt") }
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
    /// ページ内容から「Chrome拡張が要りそうか」をAppleの端末内モデルで判定し、Chromiumへの切替を提案する。
    ///
    /// **実機検証(2026-09-20)で既定OFFにした。** 2つの重大な問題を確認:
    /// ① 誤検知: 完全に無関係なexample.comのテキストに対し「Google Chrome拡張機能の導入を前提にしている」
    ///    という**捏造した理由**まで付けてYES(要切替)と判定した。無関係な3ページ(Wikipedia風/ニュース風/
    ///    レシピ風テキスト)でも試みたが、いずれもモデル自体が使用不能になり判定できず。
    /// ② 可用性: `SystemLanguageModel.default.isAvailable` が起動直後はtrueだったが、
    ///    数回の推論呼び出し後(数分以内)に `unavailable(appleIntelligenceNotEnabled)` へ変化し、
    ///    Apple Intelligenceの設定自体は変えていないのに使えなくなった。原因未確認(推測: 端末内モデルの
    ///    利用に何らかのクールダウン/上限がある)。
    /// 機構自体(FoundationModels連携・ダイアログ・呼び出し配線)は動作するが、判定精度と可用性が
    /// 実用水準に達していないため、コードは残しつつ既定を無効化する。有効化はSettings編集で可能
    var aiEngineSuggestEnabled = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        searchURL = try c.decodeIfPresent(String.self, forKey: .searchURL) ?? d.searchURL
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage) ?? d.homepage
        hibernateMinutes = try c.decodeIfPresent(Int.self, forKey: .hibernateMinutes) ?? d.hibernateMinutes
        userAgentSuffix = try c.decodeIfPresent(String.self, forKey: .userAgentSuffix) ?? d.userAgentSuffix
        adBlockEnabled = try c.decodeIfPresent(Bool.self, forKey: .adBlockEnabled) ?? d.adBlockEnabled
        aiEngineSuggestEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiEngineSuggestEnabled) ?? d.aiEngineSuggestEnabled
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
