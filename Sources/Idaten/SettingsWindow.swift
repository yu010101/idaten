import AppKit

/// 設定の画面。これまで設定は `settings.json` を手で書き換えるしかなかった。
/// 触れるのは「本人が変えたくなる項目」だけに絞る(細かい調整は今まで通りファイルで)
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var settings = Settings.load()
    /// 保存したら開いている窓へ知らせる(次に開くタブから効く項目もある)
    var onSaved: ((Settings) -> Void)?

    private let searchField = NSTextField()
    private let homeField = NSTextField()
    private let hibernateField = NSTextField()
    private let adBlock = NSButton(checkboxWithTitle: "広告を遮断する", target: nil, action: nil)
    private let aiSuggest = NSButton(checkboxWithTitle: "拡張が要りそうなページで Chromium を提案する(端末内のAI判定)", target: nil, action: nil)
    private let dockWindow = NSButton(checkboxWithTitle: "Chromium のタブを Idaten の窓に重ねて表示する(試験中)", target: nil, action: nil)
    private let inspector = NSButton(checkboxWithTitle: "Safari の Web インスペクタで検査できるようにする(開発者向け)", target: nil, action: nil)

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "設定"
        window.delegate = self
        window.center()
        build()
    }

    func show() {
        settings = Settings.load()
        fill()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        return l
    }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func build() {
        searchField.placeholderString = "https://www.google.com/search?q=%@"
        homeField.placeholderString = "about:blank"
        hibernateField.placeholderString = "10"
        for f in [searchField, homeField, hibernateField] { f.bezelStyle = .roundedBezel }
        hibernateField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let save = NSButton(title: "保存", target: self, action: #selector(saveAndClose))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(closeWindow))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let hibernateRow = NSStackView(views: [hibernateField, hint("分。0 にすると時間では休眠しません")])
        hibernateRow.orientation = .horizontal
        hibernateRow.spacing = 8

        let stack = NSStackView(views: [
            label("検索に使うURL"), searchField, hint("%@ が入力語に置き換わります"),
            label("ホームページ"), homeField,
            label("使っていないタブを休眠させるまで"), hibernateRow,
            label("その他"), adBlock, aiSuggest, dockWindow, inspector,
            hint("重ねて表示は試験中です。窓の追従が遅れる・他アプリの上に残るなどの粗さがあります"),
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(16, after: searchField)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // 背景を明示する。付けないと、暗い外観のときに文字色だけが切り替わって読めなくなる
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 500),
            homeField.widthAnchor.constraint(equalToConstant: 500),
            buttons.widthAnchor.constraint(equalToConstant: 500),
        ])
        window.contentView = content
    }

    private func fill() {
        searchField.stringValue = settings.searchURL
        homeField.stringValue = settings.homepage
        hibernateField.stringValue = String(settings.hibernateMinutes)
        adBlock.state = settings.adBlockEnabled ? .on : .off
        aiSuggest.state = settings.aiEngineSuggestEnabled ? .on : .off
        dockWindow.state = settings.dockChromiumWindow ? .on : .off
        inspector.state = settings.webInspectorEnabled ? .on : .off
    }

    @objc private func saveAndClose() {
        var s = settings
        let search = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        // %@ が無い検索URLを入れると検索が動かなくなるので、そのときは元の値を残す
        if search.contains("%@") { s.searchURL = search }
        let home = homeField.stringValue.trimmingCharacters(in: .whitespaces)
        s.homepage = home.isEmpty ? "about:blank" : home
        s.hibernateMinutes = max(0, Int(hibernateField.stringValue) ?? settings.hibernateMinutes)
        s.adBlockEnabled = adBlock.state == .on
        s.aiEngineSuggestEnabled = aiSuggest.state == .on
        s.dockChromiumWindow = dockWindow.state == .on
        s.webInspectorEnabled = inspector.state == .on
        s.save()
        settings = s
        onSaved?(s)
        closeWindow()
    }

    @objc private func closeWindow() { window.orderOut(nil) }
    /// 自己検査で見た目を描き出すための入口
    var contentViewForTest: NSView? { window.contentView }

}
