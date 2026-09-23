import AppKit

/// ドメインごとの「このサイトは Chromium で開く」規則の一覧。
///
/// これまで規則を消す手段は「そのサイトを Idaten で開いて ⌘⇧E のチェックを外す」しか無かった。
/// ところが規則があるサイトは Chromium で開かれるので、Idaten で開く導線自体が無い＝片道切符だった。
/// 規則はプロファイルごとなので、この画面も「呼び出したウィンドウの持ち物」として作る。
final class EngineRulesWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let window: NSWindow
    private let table = NSTableView()
    private let input = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let rules: EngineRules
    private let profileName: String
    private var hosts: [String] = []

    init(rules: EngineRules, profileName: String) {
        self.rules = rules
        self.profileName = profileName
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Chromium で開くサイト — \(profileName)"
        window.delegate = self
        window.center()
        build()
    }

    func show() {
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        input.placeholderString = "ドメインを追加(例: docs.google.com)"
        input.bezelStyle = .roundedBezel
        input.target = self
        input.action = #selector(addRule)

        let add = NSButton(title: "追加", target: self, action: #selector(addRule))
        let remove = NSButton(title: "選択を削除", target: self, action: #selector(removeSelected))
        let top = NSStackView(views: [input, add])
        top.orientation = .horizontal
        top.spacing = 8

        let column = NSTableColumn(identifier: .init("host"))
        column.title = "ドメイン(サブドメインも含む)"
        column.width = 460
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let bottom = NSStackView(views: [status, NSView(), remove])
        bottom.orientation = .horizontal

        let stack = NSStackView(views: [top, scroll, bottom])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            input.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
        window.contentView = content
    }

    private func reload() {
        hosts = rules.domainOverrides.filter { $0.value == .chromium }.keys.sorted()
        table.reloadData()
        status.stringValue = hosts.isEmpty ? "まだ規則はありません" : "\(hosts.count) 件"
    }

    @objc private func addRule() {
        let host = input.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return }
        // "https://example.com/path" を貼られても拾えるようにする
        let cleaned = URL(string: host)?.host ?? host.replacingOccurrences(of: "/", with: "")
        rules.setOverride(cleaned, .chromium)
        input.stringValue = ""
        reload()
    }

    @objc private func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        for i in rows where hosts.indices.contains(i) { rules.setOverride(hosts[i], nil) }
        reload()
    }

    /// 自己検査で見た目を描き出すための入口
    var contentViewForTest: NSView? { window.contentView }

    func numberOfRows(in tableView: NSTableView) -> Int { hosts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard hosts.indices.contains(row) else { return nil }
        let field = NSTextField(labelWithString: hosts[row])
        field.font = .systemFont(ofSize: 12)
        return field
    }
}
