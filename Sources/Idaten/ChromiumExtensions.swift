import Foundation

/// Idaten 管理下の Chromium(Helium)プロファイルに入っている拡張を、ディスクの manifest から読む。
///
/// CDP の `Extensions.getExtensions` は「展開して読み込んだ拡張」しか返さない(Web Store から入れたものは
/// 0件になる)ため、一覧はここで作る。`Extensions.triggerAction` は存在しない ID を渡すとブラウザが落ちうるので、
/// **この一覧に載っている ID しか渡さない**。
enum ChromiumExtensions {
    struct Item: Equatable {
        var id: String
        var name: String
        var version: String
        /// ツールバーのボタンを持つ拡張だけがアクションを起こせる
        var hasAction: Bool
    }

    static func installed(profileDir: URL) -> [Item] {
        let fm = FileManager.default
        let root = profileDir.appendingPathComponent("Default/Extensions", isDirectory: true)
        guard let ids = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [Item] = []
        for id in ids where !id.hasPrefix(".") && id != "Temp" {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            guard let versions = try? fm.contentsOfDirectory(atPath: dir.path),
                  let latest = versions.filter({ !$0.hasPrefix(".") }).sorted().last else { continue }
            let manifestURL = dir.appendingPathComponent(latest).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var name = (m["name"] as? String) ?? id
            if name.hasPrefix("__MSG_") {
                name = localizedName(dir: dir.appendingPathComponent(latest), key: name, fallback: id, manifest: m)
            }
            let hasAction = m["action"] != nil || m["browser_action"] != nil || m["page_action"] != nil
            out.append(Item(id: id, name: name, version: (m["version"] as? String) ?? "", hasAction: hasAction))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 拡張の名前が `__MSG_appName__` の形のときは、_locales から実際の文字を引く
    private static func localizedName(dir: URL, key: String, fallback: String, manifest: [String: Any]) -> String {
        let messageKey = key.replacingOccurrences(of: "__MSG_", with: "").replacingOccurrences(of: "__", with: "")
        let locales = [(manifest["default_locale"] as? String) ?? "en", "en", "ja"]
        for locale in locales {
            let url = dir.appendingPathComponent("_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = obj[messageKey] as? [String: Any],
                  let message = entry["message"] as? String else { continue }
            return message
        }
        return fallback
    }
}
