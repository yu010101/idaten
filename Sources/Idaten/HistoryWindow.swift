import AppKit

/// 履歴の一覧。SQLite には貯めていたのに、見る手段が URL バーの補完しか無かった。
/// 検索して、選んだ行をタブで開く
final class HistoryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let window: NSWindow
    private let table = NSTableView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private var rows: [(url: String, title: String, at: Date)] = []
    private let history: History
    /// 選ばれた URL を開く先(呼び出し側のウィンドウ)
    var onOpen: ((URL) -> Void)?

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    init(history: History) {
        self.history = history
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "履歴"
        window.delegate = self
        window.center()
        build()
    }

    func show() {
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(search)
    }

    private func build() {
        search.placeholderString = "履歴を検索"
        search.delegate = self

        for (id, title, width) in [("title", "題名", CGFloat(300)), ("url", "URL", 300), ("at", "日時", 120)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(openSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let open = NSButton(title: "開く", target: self, action: #selector(openSelected))
        open.keyEquivalent = "\r"
        let bottom = NSStackView(views: [status, NSView(), open])
        bottom.orientation = .horizontal

        let stack = NSStackView(views: [search, scroll, bottom])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // 背景を明示する。付けないと、暗い外観のときに文字色だけが切り替わって読めなくなる
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
    }

    private func reload() {
        rows = history.recent(matching: search.stringValue.trimmingCharacters(in: .whitespaces))
        table.reloadData()
        status.stringValue = rows.isEmpty ? "該当なし" : "\(rows.count) 件"
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    @objc private func openSelected() {
        let i = table.selectedRow
        guard rows.indices.contains(i), let url = URL(string: rows[i].url) else { return }
        onOpen?(url)
        window.orderOut(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    /// 自己検査で見た目を描き出すための入口
    var contentViewForTest: NSView? { window.contentView }


    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
        let r = rows[row]
        let text: String
        switch id {
        case "title": text = r.title.isEmpty ? (URL(string: r.url)?.host ?? r.url) : r.title
        case "url": text = r.url
        default: text = formatter.string(from: r.at)
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 12)
        if id != "title" { field.textColor = .secondaryLabelColor }
        return field
    }
}
