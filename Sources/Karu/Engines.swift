import AppKit

enum EngineKind: String, Codable {
    case webkit      // 既定。軽い・広告遮断内蔵
    case chromium    // 拡張が要る作業用
}

/// 「このドメインは常にChromium」。サブドメインも含めて後方一致で判定する
final class EngineRules {
    private(set) var chromiumDomains: Set<String> = []

    init() {
        if let data = try? Data(contentsOf: Paths.engineRules),
           let obj = try? JSONDecoder().decode([String: [String]].self, from: data) {
            chromiumDomains = Set(obj["chromium"] ?? [])
        }
    }

    func engine(forHost host: String?) -> EngineKind {
        guard let host = host?.lowercased() else { return .webkit }
        for d in chromiumDomains where host == d || host.hasSuffix("." + d) { return .chromium }
        return .webkit
    }

    func setChromium(_ host: String, _ on: Bool) {
        let h = host.lowercased()
        if on { chromiumDomains.insert(h) } else { chromiumDomains.remove(h) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(["chromium": chromiumDomains.sorted()]) {
            try? data.write(to: Paths.engineRules, options: .atomic)
        }
    }
}

/// 段A: 管理下のChromium系ブラウザを専用プロファイルで起動し、URLを渡す。
/// エンジン本体は同梱しない(GPLバイナリを再配布しない)。入っているものを上から順に探す。
/// 既存の Chrome プロファイルには触れない — 必ず Karu 専用の --user-data-dir を使う。
final class ChromiumProcessEngine {
    struct Candidate: Codable { var name: String; var appPath: String }

    static let defaultCandidates = [
        Candidate(name: "Helium", appPath: "/Applications/Helium.app"),
        Candidate(name: "Brave", appPath: "/Applications/Brave Browser.app"),
        Candidate(name: "Chrome", appPath: "/Applications/Google Chrome.app"),
    ]
    /// 確実に存在する起動フラグだけ。軽量化ポリシーは Phase 1 の実測で効いたものを後から足す
    static let defaultFlags = ["--no-first-run", "--no-default-browser-check"]

    let candidates: [Candidate]
    private var running: Process?

    init() {
        if let data = try? Data(contentsOf: Paths.engineConfig),
           let c = try? JSONDecoder().decode([Candidate].self, from: data), !c.isEmpty {
            candidates = c
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
    /// (Karu 自身の make_app.sh も同じフォールバックをする)ので両方見る
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

    private func flags() -> [String] {
        let text = (try? String(contentsOf: Paths.chromiumFlags, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// 既に同じプロファイルで動いていれば、Chromium 自身が後発の起動を先発へ転送してタブを開く
    @discardableResult
    func open(_ url: URL) -> Result<String, EngineError> {
        guard let (cand, exe) = resolve() else { return .failure(.notInstalled(candidates.map(\.name))) }
        try? FileManager.default.createDirectory(at: Paths.chromiumProfile, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--user-data-dir=\(Paths.chromiumProfile.path)"] + flags() + [url.absoluteString]
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
