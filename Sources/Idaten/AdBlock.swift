import WebKit

/// 広告遮断。WKContentRuleList は WebKit のネットワーク層で動くので、拡張型より軽い。
///
/// 2層:
///   1. 種リスト(下の seedDomains) — 変換器なしで今日から効く最小限。広告配信・計測の大手ドメインを第三者読み込みに限って遮断
///   2. `~/Library/Application Support/Idaten/rules/*.json` — EasyList 等を変換したもの(変換器は別途。1ファイル15万ルール以内)
///
/// 注意: WKContentRuleList は何件遮断したかを通知しない。効果の検証は遮断ON/OFFでリソース数を比べて行う。
final class AdBlock {
    static let seedIdentifier = "karu-seed-v1"

    /// 種リスト。網羅を主張しない — 本番のフィルタは rules/ に置く
    static let seedDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "criteo.com", "criteo.net",
        "taboola.com", "outbrain.com", "pubmatic.com", "rubiconproject.com", "openx.net",
        "casalemedia.com", "smartadserver.com", "scorecardresearch.com", "moatads.com",
        "adform.net", "yieldmo.com", "sharethrough.com", "teads.tv", "media.net",
        "i-mobile.co.jp", "microad.jp", "microad.net", "fout.jp", "socdm.com", "impact-ad.jp",
        "logly.co.jp", "popin.cc", "yads.c.yimg.jp", "ad-stir.com", "gsspat.jp", "gssprt.jp",
    ]

    static func seedJSON() -> String {
        let rules = seedDomains.map { d -> [String: Any] in
            let esc = d.replacingOccurrences(of: ".", with: "\\.")
            return ["trigger": ["url-filter": "^https?://([^/:]+\\.)?\(esc)[/:]", "load-type": ["third-party"]],
                    "action": ["type": "block"]]
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(data: data, encoding: .utf8)!
    }

    /// アプリに同梱したフィルタ(rules/*.json、adblock-rustでビルド時に変換済み)を
    /// 利用者のrulesディレクトリへ配る。バンドル側が更新されていれば上書きする(サイズが違えば更新とみなす —
    /// 利用者がrules/に自分の購読フィルタを置いていても、同名でなければ触らない)
    private static func seedBundledRules() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("rules") else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) else { return }
        for src in files where src.pathExtension == "json" {
            let dst = Paths.rulesDir.appendingPathComponent(src.lastPathComponent)
            let srcSize = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let dstSize = (try? dst.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard srcSize != dstSize else { continue }   // 同じサイズなら更新不要とみなす(粗いが十分)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }

    /// 種リスト + rules/*.json をコンパイルして返す。コンパイル済みは WebKit 側にキャッシュされる
    static func load(completion: @escaping ([WKContentRuleList], [String]) -> Void) {
        seedBundledRules()
        guard let store = WKContentRuleListStore.default() else { completion([], ["rule list store が使えない"]); return }
        var sources: [(String, String)] = [(seedIdentifier, seedJSON())]
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.rulesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "json" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            // 中身が変わったら識別子も変わるようにする(古いコンパイル結果を使い続けない)
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            sources.append(("karu-\(f.deletingPathExtension().lastPathComponent)-\(Int(mtime))", text))
        }
        var lists: [WKContentRuleList] = []
        var errors: [String] = []
        let group = DispatchGroup()
        for (id, json) in sources {
            group.enter()
            store.lookUpContentRuleList(forIdentifier: id) { cached, _ in
                if let cached { lists.append(cached); group.leave(); return }
                store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                    if let list { lists.append(list) } else { errors.append("\(id): \(error?.localizedDescription ?? "不明なエラー")") }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(lists, errors) }
    }
}
