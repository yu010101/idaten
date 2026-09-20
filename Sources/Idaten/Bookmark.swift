import Foundation

/// フォルダ階層は持たない最小実装(MVP)。Chromeのブックマークバー相当をフラットな一覧として扱う。
/// 折り畳みや並び替えは後回し — まず「Chromeから持ってきたブックマークが1つも失われない」を優先する
struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var folder: String   // 表示用の元フォルダ名(Chromeの"ブックマークバー"等)。フィルタにのみ使う
    var addedAt: Date
}

final class BookmarkStore {
    private let path: URL
    private(set) var items: [Bookmark] = []

    init(path: URL) {
        self.path = path
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: path), let list = try? dec.decode([Bookmark].self, from: data) {
            items = list
        }
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(items) { try? data.write(to: path, options: .atomic) }
    }

    func add(title: String, url: String, folder: String = "") {
        guard !items.contains(where: { $0.url == url }) else { return }   // 同じURLの重複は増やさない
        items.append(Bookmark(title: title, url: url, folder: folder, addedAt: Date()))
        save()
    }

    func remove(_ id: Bookmark.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Chromeからのインポート。既存と重複するURLはスキップして件数を返す(何件増えたか利用者に見せるため)
    @discardableResult
    func importFromChrome(_ items: [(title: String, url: String, folder: String)]) -> Int {
        var added = 0
        for i in items where !self.items.contains(where: { $0.url == i.url }) {
            self.items.append(Bookmark(title: i.title, url: i.url, folder: i.folder, addedAt: Date()))
            added += 1
        }
        if added > 0 { save() }
        return added
    }
}
