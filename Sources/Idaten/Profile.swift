import Foundation
import WebKit

/// Idatenの「プロファイル」= 実測した本人のChrome利用(15プロファイル中12個は拡張ゼロで、
/// 目的は複数アカウント/事業体のログイン分離だった)を再現するための単位。
/// Cookie・localStorage・履歴・セッション・Chromium側の身元を、プロファイルごとに完全に分ける。
struct Profile: Codable, Identifiable, Equatable {
    var id: String            // UUID文字列。WKWebsiteDataStore(forIdentifier:) にそのまま使う
    var name: String
    var colorHex: String       // ウィンドウ内のプロファイル表示に使う小さな色点
    var createdAt: Date
    var lastOpenedAt: Date
    /// このプロファインの既定エンジン。暗号資産ウォレット(Phantom/Solflare等)のように「初めて訪れるサイトでも
    /// 拡張の力が要る」プロファイルは既定Chromiumにする(Codexとの検討、2026-09-20)。既定はWebKit
    var defaultEngine: EngineKind = .webkit

    static func makeNew(name: String, colorHex: String, defaultEngine: EngineKind = .webkit) -> Profile {
        Profile(id: UUID().uuidString, name: name, colorHex: colorHex, createdAt: Date(), lastOpenedAt: Date(), defaultEngine: defaultEngine)
    }

    init(id: String, name: String, colorHex: String, createdAt: Date, lastOpenedAt: Date, defaultEngine: EngineKind = .webkit) {
        self.id = id; self.name = name; self.colorHex = colorHex
        self.createdAt = createdAt; self.lastOpenedAt = lastOpenedAt; self.defaultEngine = defaultEngine
    }

    /// 実機で踏んだ事故(2026-09-20): defaultEngine追加後、素のCodable合成では旧バージョンの
    /// profiles.json(このキーが無い)がデコードに失敗し、既存プロファイルが黙って迷子になった
    /// (「既定」が新しいUUIDで作り直され、旧プロファイルのブックマーク・履歴が見えなくなった)。
    /// 以後フィールドを足すときは、必ずこのように decodeIfPresent で受けること
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
        defaultEngine = try c.decodeIfPresent(EngineKind.self, forKey: .defaultEngine) ?? .webkit
    }

    /// WKWebsiteDataStore の識別子は UUID 型を要求する。id は必ず UUID文字列で作るのでここは失敗しない
    var dataStoreIdentifier: UUID { UUID(uuidString: id) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
}

enum ProfileStore {
    private static var registryPath: URL { Paths.support.appendingPathComponent("profiles.json") }
    private static let defaultColors = ["#5B8DEF", "#E2775B", "#5BC29A", "#C77DE0", "#E0B94E", "#4EC7E0"]

    /// 初回は「既定」1個を作る。旧バージョン(プロファイル概念が無かった頃)のファイルが
    /// トップレベルに残っていれば、消さずにこの「既定」プロファイルへ移す
    static func loadOrCreate() -> [Profile] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601   // save() 側が .iso8601 で書くので合わせる。ここが噛み合わないと
        // 毎回デコードに失敗し、起動のたびに新しい「既定」プロファイルを作ってしまう(実際に踏んだ不具合)
        if let data = try? Data(contentsOf: registryPath),
           let list = try? dec.decode([Profile].self, from: data), !list.isEmpty {
            return list
        }
        let def = Profile.makeNew(name: "既定", colorHex: defaultColors[0])
        migrateLegacyFilesIfPresent(into: def)
        save([def])
        return [def]
    }

    static func save(_ profiles: [Profile]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(profiles) { try? data.write(to: registryPath, options: .atomic) }
    }

    static func nextColor(usedBy profiles: [Profile]) -> String {
        let used = Set(profiles.map(\.colorHex))
        return defaultColors.first(where: { !used.contains($0) }) ?? defaultColors.randomElement()!
    }

    /// プロファイル概念が無かった版の session.json / history.sqlite / engine_rules.json / chromium-profile を
    /// 新しい既定プロファイルのディレクトリへ移す(破棄しない)
    private static func migrateLegacyFilesIfPresent(into profile: Profile) {
        let legacy: [(URL, (ProfilePaths) -> URL)] = [
            (Paths.support.appendingPathComponent("session.json"), { $0.session }),
            (Paths.support.appendingPathComponent("history.sqlite"), { $0.history }),
            (Paths.support.appendingPathComponent("engine_rules.json"), { $0.engineRules }),
        ]
        let paths = ProfilePaths(profile: profile)
        for (from, to) in legacy where FileManager.default.fileExists(atPath: from.path) {
            try? FileManager.default.moveItem(at: from, to: to(paths))
        }
        let legacyChromiumProfile = Paths.support.appendingPathComponent("chromium-profile", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyChromiumProfile.path) {
            try? FileManager.default.moveItem(at: legacyChromiumProfile, to: paths.chromiumProfile)
        }
    }
}

/// プロファイル単位で分かれるファイル群。ここに入らないもの(広告フィルタ本体・Chromium候補・
/// 起動フラグ・アプリ全体のUI設定)はプロファイル非依存で `Paths` 側の既定値を使う
struct ProfilePaths {
    let profile: Profile

    var dir: URL {
        let d = Paths.support.appendingPathComponent("Profiles/\(profile.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    var history: URL { dir.appendingPathComponent("history.sqlite") }
    var bookmarks: URL { dir.appendingPathComponent("bookmarks.json") }
    var session: URL { dir.appendingPathComponent("session.json") }
    var engineRules: URL { dir.appendingPathComponent("engine_rules.json") }
    var chromiumProfile: URL { dir.appendingPathComponent("chromium-profile", isDirectory: true) }
}
