import AppKit

enum EngineKind: String, Codable {
    case webkit      // 既定。軽い・広告遮断内蔵
    case chromium    // 拡張が要る作業用
}

/// ドメインごとのエンジン指定。既定は「継承」(=プロファイルの既定値に従う)。
/// Codexとの検討(2026-09-20)で決めた優先順位:
///   タブの明示指定(⌘⇧E) > ドメイン例外(この辞書) > プロファイル既定値(Profile.defaultEngine) > アプリ既定(WebKit)
/// 「常にChromiumを解除」は「WebKit固定」にはせず「継承」に戻す(暗号資産ウォレット用プロファイル等、
/// プロファイル既定がChromiumのときにWebKit固定の例外が残ってしまう事故を避けるため)
final class EngineRules {
    private(set) var domainOverrides: [String: EngineKind] = [:]
    private let path: URL

    init(path: URL) {
        self.path = path
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONDecoder().decode([String: String].self, from: data) {
            domainOverrides = obj.compactMapValues { EngineKind(rawValue: $0) }
        }
    }

    /// `profileDefault` はこのプロファイルの既定エンジン(Profile.defaultEngine)。ドメイン例外が無ければこれを使う
    func engine(forHost host: String?, profileDefault: EngineKind) -> EngineKind {
        guard let host = host?.lowercased() else { return profileDefault }
        for (d, kind) in domainOverrides where host == d || host.hasSuffix("." + d) { return kind }
        return profileDefault
    }

    /// kind が nil なら例外を消して「継承」に戻す
    func setOverride(_ host: String, _ kind: EngineKind?) {
        let h = host.lowercased()
        domainOverrides[h] = kind
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(domainOverrides.mapValues { $0.rawValue }) {
            try? data.write(to: path, options: .atomic)
        }
    }
}

/// 段A: 管理下のChromium系ブラウザを専用プロファイルで起動し、URLを渡す。
/// エンジン本体は同梱しない(GPLバイナリを再配布しない)。入っているものを上から順に探す。
/// 既存の Chrome プロファイルには触れない — 必ず Idaten 専用の --user-data-dir を使う。
///
/// **IdatenのプロファイルごとにChromium側の --user-data-dir も別**にする。実測(2026-09-20)で判明した通り、
/// 本人のChrome複数プロファイルの過半数は「拡張ゼロ・アカウント分離が目的」で、
/// crypto walletなど一部拡張(Phantom/Solflare)はプロファイル固有の前提を持つため、
/// Idaten側の身元(個人用/仕事用等)とChromium側の身元を1対1に対応させないと、
/// 渡した先でログインし直しが要る問題が余計に増える。
final class ChromiumProcessEngine {
    struct Candidate: Codable { var name: String; var appPath: String }

    /// フォーク版(yu010101/helium-macos の idaten ブランチ)。名前・メニューバー・アイコンが Idaten になる。
    /// Swift 版 Idaten.app と同じ表示名なので、置き場所のフォルダ名だけ「Idaten Engine.app」にする
    static let forkCandidate = Candidate(name: "Idaten Engine", appPath: "/Applications/Idaten Engine.app")
    /// フォーク版のバンドルID。キーチェーンの鍵(Idaten Storage Key)が Helium と別なので、
    /// 同じ --user-data-dir を開くとログイン(Cookie)が読めない → プロファイルを分ける(ProfilePaths.chromiumProfile)
    static let forkBundleID = "dev.idaten.chromium"

    static let defaultCandidates = [
        forkCandidate,
        Candidate(name: "Helium", appPath: "/Applications/Helium.app"),
        Candidate(name: "Brave", appPath: "/Applications/Brave Browser.app"),
        Candidate(name: "Chrome", appPath: "/Applications/Google Chrome.app"),
    ]
    /// 確実に存在する起動フラグだけ。軽量化ポリシーは Phase 1 の実測で効いたものを後から足す
    static let defaultFlags = ["--no-first-run", "--no-default-browser-check"]

    let candidates: [Candidate]
    private let profileDir: URL
    private var running: Process?

    init(profileDir: URL) {
        self.profileDir = profileDir
        if let data = try? Data(contentsOf: Paths.engineConfig),
           let c = try? JSONDecoder().decode([Candidate].self, from: data), !c.isEmpty {
            // フォーク版より前に書かれた engine.json には候補が無い。1回だけ先頭に足す(本人が消したら戻さない印を残す)
            if !c.contains(where: { $0.name == Self.forkCandidate.name }) && !UserDefaults.standard.bool(forKey: "forkCandidateMigrated") {
                candidates = [Self.forkCandidate] + c
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                if let data = try? enc.encode(candidates) { try? data.write(to: Paths.engineConfig, options: .atomic) }
            } else {
                candidates = c
            }
            UserDefaults.standard.set(true, forKey: "forkCandidateMigrated")
        } else {
            candidates = Self.defaultCandidates
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            if let data = try? enc.encode(candidates) { try? data.write(to: Paths.engineConfig, options: .atomic) }
        }
        if !FileManager.default.fileExists(atPath: Paths.chromiumFlags.path) {
            try? (Self.defaultFlags.joined(separator: "\n") + "\n").write(to: Paths.chromiumFlags, atomically: true, encoding: .utf8)
        }
    }

    /// 入っている最初の候補と、その実行ファイル(Info.plist の CFBundleExecutable から引く。名前を決め打ちしない)。
    /// appPath が /Applications/... でも、書き込み権限が無い環境では ~/Applications/... に入っていることがある
    /// (Idaten 自身の make_app.sh も同じフォールバックをする)ので両方見る
    func resolve() -> (Candidate, URL)? {
        for c in candidates {
            for path in [c.appPath, c.appPath.replacingOccurrences(of: "/Applications/", with: NSHomeDirectory() + "/Applications/")] {
                if let exe = Bundle(path: path)?.executableURL, FileManager.default.isExecutableFile(atPath: exe.path) {
                    return (c, exe)
                }
            }
        }
        return nil
    }

    /// 今起動するのがフォーク版か(= Idaten のキーチェーンを使うか)。engine.json と実在するアプリから決める
    static func activeIsFork() -> Bool {
        var list = defaultCandidates
        if let data = try? Data(contentsOf: Paths.engineConfig),
           let c = try? JSONDecoder().decode([Candidate].self, from: data), !c.isEmpty { list = c }
        for c in list {
            for path in [c.appPath, c.appPath.replacingOccurrences(of: "/Applications/", with: NSHomeDirectory() + "/Applications/")] {
                if let b = Bundle(path: path), let exe = b.executableURL, FileManager.default.isExecutableFile(atPath: exe.path) {
                    return b.bundleIdentifier == forkBundleID
                }
            }
        }
        return false
    }

    func flags() -> [String] {
        let text = (try? String(contentsOf: Paths.chromiumFlags, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// 既に同じプロファイルで動いていれば、Chromium 自身が後発の起動を先発へ転送してタブを開く
    @discardableResult
    func open(_ url: URL) -> Result<String, EngineError> {
        guard let (cand, exe) = resolve() else { return .failure(.notInstalled(candidates.map(\.name))) }
        try? FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--user-data-dir=\(profileDir.path)"] + flags() + [url.absoluteString]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(.launchFailed(String(describing: error))) }
        if running == nil || running?.isRunning == false { running = p }
        return .success(cand.name)
    }

    enum EngineError: Error {
        case notInstalled([String])
        case launchFailed(String)
    }
}
