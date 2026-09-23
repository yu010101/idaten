import AppKit
import WebKit

/// 右クリックのメニューに項目を足すために被せる。WKWebView の既定メニューは willOpenMenu で触れる
final class IdatenWebView: WKWebView {
    weak var owner: BrowserWindowController?
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        owner?.augmentContextMenu(menu)
        super.willOpenMenu(menu, with: event)
    }
}

/// タブ1枚分の器。ボタンでは拾えない操作(横へのドラッグで並べ替え・中クリックで閉じる)を受け持つ
final class TabCellView: NSStackView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// ドラッグ中に「いまどこへ落とそうとしているか」を伝える。戻り値は並べ替え後の自分の位置
    var onDrag: ((CGFloat) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        // 数ピクセル動いたら並べ替えとみなす(ただの選択と区別する)
        var dragging = false
        let start = event.locationInWindow
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: 10, mode: .eventTracking) { e, stop in
            guard let e else { stop.pointee = true; return }
            switch e.type {
            case .leftMouseDragged:
                let dx = e.locationInWindow.x - start.x
                if dragging || abs(dx) > 4 { dragging = true; self.onDrag?(e.locationInWindow.x) }
            default:
                stop.pointee = true
            }
        }
    }

    /// 中ボタン(ホイール押し込み)で閉じる — ブラウザ共通の操作
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } else { super.otherMouseDown(with: event) }
    }
}

/// 窓の背景を自前で塗る。Chromium タブを表示中は内容領域だけ塗らずに透明の穴にし、
/// 真下に重ねた Helium の窓を見せる(透明な画素へのクリックは macOS が下の窓へ通す)
final class HoledRootView: NSView {
    var hole: NSRect? {
        didSet {
            guard hole != oldValue else { return }
            needsDisplay = true
            window?.invalidateShadow()
            hole == nil ? stopPassThrough() : startPassThrough()
        }
    }

    /// タイトルバー付きの窓で、透明の画素へのクリックが下の別アプリの窓へ抜ける保証は Apple の資料に無い
    /// (Codexレビュー、2026-09-22)。合成クリックでの実測は、画面を全面で覆う別アプリの窓が前にあって
    /// クリックがそちらへ落ちたため無効 — 未検証のまま。NSWindow には「一部だけマウスを素通し」する API が無いので、
    /// 念のため、マウスが穴の上にある間だけ窓ごと素通しにする。
    /// 窓の縁 4pt は除く(下端・左右の縁でのサイズ変更を残すため)
    ///
    /// 切り替えはマウス移動のイベントで即座に行う(タイマーだけだと、穴からツールバーへ動かして次の刻みの前に押すと
    /// 窓が素通しのままでクリックが下へ落ちる。再レビュー指摘)。素通し中の移動は Helium 宛てなので
    /// グローバルモニタで、そうでない間はローカルモニタで拾う。タイマーは取りこぼしの保険
    private var passThroughTimer: Timer?
    private var monitors: [Any] = []
    private func startPassThrough() {
        guard passThroughTimer == nil else { return }
        window?.acceptsMouseMovedEvents = true
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp, .scrollWheel]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.updatePassThrough() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in self?.updatePassThrough(); return e }) { monitors.append(l) }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updatePassThrough() }
        RunLoop.main.add(t, forMode: .common)
        passThroughTimer = t
    }
    private func stopPassThrough() {
        passThroughTimer?.invalidate()
        passThroughTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        window?.ignoresMouseEvents = false
    }
    private func updatePassThrough() {
        guard let window, let hole else { return }
        // ボタンを押したまま(ドラッグ中)は切り替えない。タブバーから始めたドラッグが途中で途切れないように
        if NSEvent.pressedMouseButtons != 0 { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inView = convert(inWindow, from: nil)
        let inside = hole.insetBy(dx: 4, dy: 4).contains(inView)
        if window.ignoresMouseEvents != inside { window.ignoresMouseEvents = inside }
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBackground.setFill()
        bounds.fill()
        if let hole { NSColor.clear.setFill(); hole.fill(using: .copy) }
    }
}

final class BrowserWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate,
    WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, ChromiumDockDelegate {

    let window: NSWindow
    let profile: Profile
    let paths: ProfilePaths
    /// 設定画面から保存されたら差し替わる(次の読み込み・次のタブから効く)
    var settings = Settings.load() { didSet { scheduleHibernation() } }
    let rules: EngineRules
    let chromium: ChromiumProcessEngine
    /// 第1段の「1ブラウザ」: Chromium タブを Idaten のタブバーに並べ、Helium の窓を内容領域へ重ねる
    let dock: ChromiumDock
    private let root = HoledRootView()
    let history: History
    let bookmarks: BookmarkStore
    /// このプロファイル専用のCookie/localStorage/認証状態。他プロファイルとは完全に別の身元になる
    let dataStore: WKWebsiteDataStore

    private(set) var tabs: [Tab] = []
    private(set) var selected: Tab?
    private var ruleLists: [WKContentRuleList] = []

    private let tabStack = NSStackView()
    private let tabScroll = NSScrollView()
    private let urlField = NSTextField()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let engineButton = NSButton()
    private let bookmarkButton = NSButton()
    private let progress = NSProgressIndicator()
    private let container = NSView()
    private var hibernateTimer: Timer?

    init(profile: Profile) {
        self.profile = profile
        self.paths = ProfilePaths(profile: profile)
        self.rules = EngineRules(path: paths.engineRules)
        self.chromium = ChromiumProcessEngine(profileDir: paths.chromiumProfile)
        self.dock = ChromiumDock(engine: chromium, profileDir: paths.chromiumProfile)
        self.history = History(path: paths.history)
        self.bookmarks = BookmarkStore(path: paths.bookmarks)
        self.dataStore = WKWebsiteDataStore(forIdentifier: profile.dataStoreIdentifier)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Idaten — \(profile.name)"
        window.delegate = self
        window.setFrameAutosaveName("IdatenWindow-\(profile.id)")
        window.isReleasedWhenClosed = false
        // 背景は HoledRootView が塗る(Theme の動的NSColorなのでライト/ダーク切替に追従)。窓自体は透明にしておかないと
        // Chromium タブ表示中の「穴」が開かない。タイトルバーも内容の上に重ねて自前の背景で塗る
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        buildUI()
        dock.delegate = self
    }

    // MARK: - UI

    private func buildUI() {
        window.contentView = root

        tabStack.orientation = .horizontal
        tabStack.spacing = 2
        tabStack.alignment = .centerY
        tabStack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        // rebuildTabBar で幅の計算に使うので、作ったものを保持しておく
        let tabScroll = self.tabScroll
        tabScroll.documentView = tabStack
        tabScroll.hasHorizontalScroller = false
        tabScroll.drawsBackground = false
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        func style(_ b: NSButton, _ symbol: String, _ tip: String, _ action: Selector) {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.bezelStyle = .texturedRounded
            b.isBordered = false
            b.toolTip = tip
            b.target = self
            b.action = action
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        style(backButton, "chevron.left", "戻る (⌘[)", #selector(goBack))
        style(forwardButton, "chevron.right", "進む (⌘])", #selector(goForward))
        style(reloadButton, "arrow.clockwise", "再読み込み (⌘R)", #selector(reload))
        engineButton.title = "WebKit"
        engineButton.bezelStyle = .inline   // 主張しすぎない見た目にする(押せることは分かる程度)
        engineButton.font = .systemFont(ofSize: 11)
        engineButton.contentTintColor = .secondaryLabelColor
        engineButton.toolTip = "エンジンを切り替える (⌘⇧E) — Chromium側とはCookie・ログインを共有しません"
        engineButton.target = self
        engineButton.action = #selector(switchEngine)
        engineButton.setContentHuggingPriority(.required, for: .horizontal)

        urlField.placeholderString = "URL または検索"
        urlField.delegate = self
        urlField.target = self
        urlField.action = #selector(urlEntered)
        urlField.bezelStyle = .roundedBezel
        urlField.lineBreakMode = .byTruncatingTail
        urlField.cell?.sendsActionOnEndEditing = false

        let newTabButton = NSButton()
        style(newTabButton, "plus", "新しいタブ (⌘T)", #selector(newTabAction))
        style(bookmarkButton, "star", "ブックマークに追加/削除 (⌘D)", #selector(toggleBookmarkCurrentPage))

        // 複数プロファイルのウィンドウを同時に開いたとき、どれがどのプロファインかを一目で(設計DBの"ビール3杯理論":
        // 文字を読まなくても色だけでわかるようにする)
        let profileDot = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        profileDot.wantsLayer = true
        profileDot.layer?.backgroundColor = NSColor(hex: profile.colorHex).cgColor
        profileDot.layer?.cornerRadius = 5
        profileDot.toolTip = "プロファイル: \(profile.name)"
        profileDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        profileDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let toolbar = NSStackView(views: [profileDot, backButton, forwardButton, reloadButton, urlField, bookmarkButton, engineButton, newTabButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.isHidden = true

        for v in [tabScroll, toolbar, progress, container] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            // fullSizeContentView なので、タイトルバー(信号機ボタン)の下から並べる
            tabScroll.topAnchor.constraint(equalTo: (window.contentLayoutGuide as! NSLayoutGuide).topAnchor, constant: 4),
            tabScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabScroll.heightAnchor.constraint(equalToConstant: 28),
            tabStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScroll.contentView.bottomAnchor),
            tabStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabStack.heightAnchor.constraint(equalToConstant: 28),

            toolbar.topAnchor.constraint(equalTo: tabScroll.bottomAnchor, constant: 2),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),

            progress.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 3),

            container.topAnchor.constraint(equalTo: progress.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    /// 広告遮断のルールを読み終えてからタブを開く(最初のページが素通しにならないように)
    func start(openURLs: [URL]) {
        let begin: () -> Void = { [self] in
            if let domain = selfTestSetCookieDomain {
                let cookie = HTTPCookie(properties: [.domain: domain, .path: "/", .name: "karu_isolation_probe",
                                                     .value: profile.id, .expires: Date().addingTimeInterval(3600)])!
                dataStore.httpCookieStore.setCookie(cookie, completionHandler: nil)
            }
            restoreSession()
            for u in openURLs { newTab(url: u) }
            if tabs.isEmpty { newTab(url: URL(string: settings.homepage)) }
            window.makeKeyAndOrderFront(nil)
            if selected?.url == nil || selected?.url?.absoluteString == "about:blank" { focusURLField() }
            scheduleHibernation()
        }
        guard settings.adBlockEnabled else { begin(); return }
        AdBlock.load { [self] lists, errors in
            ruleLists = lists
            for e in errors { NSLog("Idaten adblock: %@", e) }
            begin()
        }
    }

    private func rebuildTabBar() {
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, tab) in tabs.enumerated() {
            // エンジンの種別は文字でなく色ドットで示す(見た目の負荷が低く、離れて見てもわかる)
            // ファビコンがあれば出す。無い/Chromium へ渡したタブは、エンジンの色ドットのまま
            let mark: NSView
            let chromiumTab = tab.isChromium || tab.handedOffExternally
            if let icon = tab.favicon, !chromiumTab {
                let iv = NSImageView(image: icon)
                iv.imageScaling = .scaleProportionallyDown
                iv.widthAnchor.constraint(equalToConstant: 14).isActive = true
                iv.heightAnchor.constraint(equalToConstant: 14).isActive = true
                mark = iv
            } else {
                let dot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 3
                dot.layer?.backgroundColor = (chromiumTab ? Theme.EngineDot.chromium : Theme.EngineDot.webkit).cgColor
                dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
                mark = dot
            }
            mark.toolTip = chromiumTab ? "Chromiumエンジンで表示中" : "WebKitエンジンで表示中"

            // 題名はラベルにする(ボタンだとドラッグでの並べ替えを器が拾えない)
            let title = NSTextField(labelWithString: tab.displayTitle)
            title.lineBreakMode = .byTruncatingTail
            title.font = .systemFont(ofSize: 12, weight: tab === selected ? .semibold : .regular)
            title.textColor = tab === selected ? .labelColor : .secondaryLabelColor
            // 枚数が増えたら幅を詰める。詰まりきったら横スクロールに任せる
            let available = tabScroll.bounds.width > 0 ? tabScroll.bounds.width : window.frame.width
            let perTab = max(64, min(170, available / CGFloat(max(1, tabs.count)) - 46))
            title.widthAnchor.constraint(lessThanOrEqualToConstant: perTab).isActive = true
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "閉じる")!,
                                 target: self, action: #selector(tabCloseClicked(_:)))
            close.tag = i
            close.isBordered = false
            close.imageScaling = .scaleProportionallyDown
            close.widthAnchor.constraint(equalToConstant: 14).isActive = true
            close.isHidden = perTab < 80 && tab !== selected   // 細いときは選択中のタブだけに出す
            let cell = TabCellView(views: [mark, title, close])
            cell.onSelect = { [weak self, weak tab] in if let self, let tab { self.select(tab) } }
            cell.onClose = { [weak self, weak tab] in if let self, let tab { self.close(tab) } }
            cell.onDrag = { [weak self, weak tab] x in if let self, let tab { self.dragTab(tab, toWindowX: x) } }
            cell.toolTip = tab.url?.absoluteString
            cell.orientation = .horizontal
            cell.spacing = 4
            cell.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6)
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 6
            cell.layer?.backgroundColor = (tab === selected ? NSColor.controlAccentColor.withAlphaComponent(0.18) : .clear).cgColor
            tabStack.addArrangedSubview(cell)
        }
    }

    /// 「%E9%9F%8B…」のままだと読めないので、表示は復号して https:// と末尾の / を落とす。
    /// 編集を始めたときは本物の文字列に戻す(コピーや手直しができるように)
    static func prettyURL(_ url: URL) -> String {
        let s = url.absoluteString
        if s == "about:blank" { return "" }
        var t = s.removingPercentEncoding ?? s
        if t.hasPrefix("https://") { t.removeFirst(8) }
        if t.hasSuffix("/"), (url.path == "/" || url.path.isEmpty), url.query == nil { t.removeLast() }
        return t
    }

    private func updateToolbar() {
        let wv = selected?.webView
        // Chromium タブの戻れる/進めるは CDP から取らない(毎回問い合わせる割に得るものが少ない)。常に押せるようにしておく
        let chromiumTab = selected?.isChromium == true
        backButton.isEnabled = chromiumTab || (wv?.canGoBack ?? false)
        forwardButton.isEnabled = chromiumTab || (wv?.canGoForward ?? false)
        if window.firstResponder !== urlField.currentEditor() {
            urlField.stringValue = selected?.url.map(Self.prettyURL) ?? ""
        }
        let always = rules.engine(forHost: selected?.url?.host, profileDefault: profile.defaultEngine) == .chromium
        engineButton.title = selected?.isChromium == true ? (always ? "Chromium固定" : "Chromium") : "WebKit"
        window.title = selected.map { $0.title.isEmpty ? "Idaten" : $0.title } ?? "Idaten"
        let isBookmarked = selected?.url.map { u in bookmarks.items.contains(where: { $0.url == u.absoluteString }) } ?? false
        bookmarkButton.image = NSImage(systemSymbolName: isBookmarked ? "star.fill" : "star", accessibilityDescription: nil)
        bookmarkButton.contentTintColor = isBookmarked ? .systemYellow : nil
    }

    // MARK: - タブ

    private func makeConfiguration() -> WKWebViewConfiguration {
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = dataStore   // このプロファイル専用のCookie/ログイン状態
        installContextMenuBridge(conf)
        conf.applicationNameForUserAgent = settings.userAgentSuffix
        conf.preferences.isElementFullscreenEnabled = true
        for l in ruleLists { conf.userContentController.add(l) }
        return conf
    }

    /// 右クリックした場所のリンクを知るための橋渡し。WebKit の既定メニューは「どのリンクか」を教えてくれないので、
    /// contextmenu のときに一番近い <a href> をページ側から送ってもらう
    private func installContextMenuBridge(_ conf: WKWebViewConfiguration) {
        let ucc = conf.userContentController
        ucc.removeScriptMessageHandler(forName: "idatenContext")   // window.open 由来の使い回しで二重登録になるのを防ぐ
        ucc.add(self, name: "idatenContext")
        let js = """
        document.addEventListener('contextmenu', function (e) {
          var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
          window.webkit.messageHandlers.idatenContext.postMessage(a ? a.href : '');
        }, true);
        """
        ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    private var lastContextLink: URL?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "idatenContext" else { return }
        lastContextLink = (message.body as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    /// 右クリックメニューの先頭に、ブラウザとして当たり前の項目を足す
    func augmentContextMenu(_ menu: NSMenu) {
        guard let url = lastContextLink else { return }
        let inTab = NSMenuItem(title: "リンクを新しいタブで開く", action: #selector(openContextLinkInTab), keyEquivalent: "")
        let inChromium = NSMenuItem(title: "リンクを Chromium で開く", action: #selector(openContextLinkInChromium), keyEquivalent: "")
        let copy = NSMenuItem(title: "リンクをコピー", action: #selector(copyContextLink), keyEquivalent: "")
        for (i, item) in [inTab, inChromium, copy].enumerated() {
            item.target = self
            item.representedObject = url
            menu.insertItem(item, at: i)
        }
        menu.insertItem(.separator(), at: 3)
    }

    @objc private func openContextLinkInTab() {
        guard let url = lastContextLink else { return }
        newTab(url: url, select: false)
    }

    @objc private func openContextLinkInChromium() {
        guard let url = lastContextLink else { return }
        handOff(url)
    }

    @objc private func copyContextLink() {
        guard let url = lastContextLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func makeWebView(_ tab: Tab, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let conf = configuration ?? makeConfiguration()
        if configuration != nil {
            for l in ruleLists { conf.userContentController.add(l) }
            installContextMenuBridge(conf)
        }
        let wv = IdatenWebView(frame: .zero, configuration: conf)
        wv.owner = self
        wv.navigationDelegate = self
        wv.uiDelegate = self   // 無いと confirm()/alert() が黙って「いいえ」を返す
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        tab.webView = wv
        tab.observations = [
            wv.observe(\.title) { [weak self, weak tab] w, _ in
                guard let self, let tab else { return }
                tab.title = w.title ?? ""
                self.rebuildTabBar(); if tab === self.selected { self.updateToolbar() }
            },
            wv.observe(\.url) { [weak self, weak tab] w, _ in
                guard let self, let tab else { return }
                if let u = w.url { tab.url = u }
                if tab === self.selected { self.updateToolbar() }
            },
            wv.observe(\.estimatedProgress) { [weak self, weak tab] w, _ in
                guard let self, let tab, tab === self.selected else { return }
                self.progress.doubleValue = w.estimatedProgress
                self.progress.isHidden = w.estimatedProgress >= 1.0
            },
            wv.observe(\.canGoBack) { [weak self] _, _ in self?.updateToolbar() },
            wv.observe(\.canGoForward) { [weak self] _, _ in self?.updateToolbar() },
        ]
        return wv
    }

    /// 実機で踏んだ事故(2026-09-20): セッション復元でタブがN件あるとき、1件ごとに rebuildTabBar()(現在の
    /// タブ数に比例)と saveSession()(同じく比例)を呼んでいたため、復元全体がO(N²)になっていた。
    /// テスト中にセッションへ180件溜まり、メインスレッドが数秒〜張り付いてAppleEventにも応答しなくなった
    /// (Idaten本体が数GBまで膨張して見えたのはこの間に多数のNSButton/SwiftUIビューグラフが作られたため)。
    /// `skipUIRebuild` は restoreSession() 専用: 全件追加し終えてから1回だけ rebuildTabBar()/saveSession() する
    @discardableResult
    func newTab(url: URL?, select: Bool = true, hibernated: Bool = false, title: String? = nil,
                configuration: WKWebViewConfiguration? = nil, skipUIRebuild: Bool = false) -> Tab {
        let tab = Tab()
        tab.url = url
        if let title { tab.title = title }
        if let sel = selected, let i = tabs.firstIndex(where: { $0 === sel }), configuration != nil {
            tabs.insert(tab, at: i + 1)   // リンクから開いたタブは隣に
        } else {
            tabs.append(tab)
        }
        if !hibernated {
            let wv = makeWebView(tab, configuration: configuration)
            // configuration つき = window.open 由来。読み込みは WebKit 自身が行うので load しない
            if configuration == nil {
                if let url, url.absoluteString != "about:blank" {
                    wv.load(URLRequest(url: url))
                } else {
                    wv.loadHTMLString(newTabHTML(), baseURL: nil)   // 真っ白ではなく、よく見るサイトとブックマークを出す
                }
            }
        }
        guard !skipUIRebuild else { return tab }
        if select { self.select(tab) } else { rebuildTabBar() }
        saveSession()
        return tab
    }

    /// 新しいタブの中身。よく見るサイト(履歴)とブックマークを並べる。
    /// 端末内で作る静的なHTMLで、外部への通信はしない
    private func newTabHTML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func card(_ url: String, _ title: String, _ sub: String) -> String {
            let host = URL(string: url)?.host ?? url
            let initial = String(host.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased()
            return """
            <a class="card" href="\(esc(url))" title="\(esc(url))">
              <span class="badge">\(esc(initial))</span>
              <span class="t">\(esc(title.isEmpty ? host : title))</span>
              <span class="s">\(esc(sub))</span>
            </a>
            """
        }
        let top = history.topSites(limit: 8).map { card($0.url, $0.title, "\($0.count) 回") }
        let marks = bookmarks.items.sorted { $0.addedAt > $1.addedAt }.prefix(8).map { card($0.url, $0.title, URL(string: $0.url)?.host ?? "") }
        func section(_ name: String, _ cards: [String], _ empty: String) -> String {
            "<h2>\(name)</h2>" + (cards.isEmpty ? "<p class=\"empty\">\(empty)</p>" : "<div class=\"grid\">" + cards.joined() + "</div>")
        }
        return """
        <!doctype html><meta charset="utf-8"><title>新しいタブ</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 14px -apple-system, system-ui, sans-serif; margin: 0; padding: 48px 32px;
                 background: Canvas; color: CanvasText; }
          .wrap { max-width: 760px; margin: 0 auto; }
          h1 { font-size: 20px; font-weight: 600; margin: 0 0 28px; }
          h2 { font-size: 12px; font-weight: 600; color: GrayText; letter-spacing: .04em; margin: 28px 0 10px; }
          .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(168px, 1fr)); gap: 10px; }
          .card { display: flex; flex-direction: column; gap: 2px; padding: 12px; border-radius: 10px;
                  border: 1px solid color-mix(in srgb, CanvasText 12%, transparent); text-decoration: none; color: inherit; }
          .card:hover { background: color-mix(in srgb, CanvasText 6%, transparent); }
          .badge { width: 26px; height: 26px; border-radius: 7px; display: grid; place-items: center; margin-bottom: 6px;
                   background: color-mix(in srgb, AccentColor 22%, transparent); font-weight: 600; font-size: 13px; }
          .t { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .s { color: GrayText; font-size: 12px; }
          .empty { color: GrayText; }
        </style>
        <div class="wrap">
          <h1>韋駄天</h1>
          \(section("よく見るサイト", top, "まだ履歴がありません。上のURL欄に入力して始めてください。"))
          \(section("ブックマーク", Array(marks), "⌘D でこのページをブックマークできます。"))
        </div>
        """
    }

    func select(_ tab: Tab) {
        selected?.lastActive = Date()
        selected?.webView?.removeFromSuperview()
        selected = tab
        tab.lastActive = Date()
        if tab.isChromium {
            showChromium(tab)
            rebuildTabBar()
            updateToolbar()
            return
        }
        root.hole = nil
        if window.level != .normal { window.level = .normal }
        if tab.webView == nil {   // 休眠からの復帰
            let wv = makeWebView(tab)
            if let state = tab.interactionState {
                wv.interactionState = state   // 代入すると現在の項目を自分で読み込む
                tab.interactionState = nil
            } else if let url = tab.url, url.absoluteString != "about:blank" {
                wv.load(URLRequest(url: url))
            } else {
                wv.loadHTMLString(newTabHTML(), baseURL: nil)
            }
        }
        if let wv = tab.webView {
            wv.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: container.topAnchor),
                wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            progress.isHidden = wv.estimatedProgress >= 1.0 || !wv.isLoading
            window.makeFirstResponder(wv)
        }
        rebuildTabBar()
        updateToolbar()
        // 60秒の定期チェックを待たず、タブを切り替える/増やすその瞬間に予算を適用する。
        // 大量タブを一気に開いた直後も遅れずに効かせるため(Codexとの検討で優先度最高と一致)
        enforceAwakeBudget()
    }

    func close(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.dropWebView()
        tab.pendingCreate = nil   // 応答待ちなら、届いたページは completion 側で閉じる
        if let id = tab.chromiumTargetId {
            if dockedTargetId == id { dockedTargetId = nil }
            tab.chromiumTargetId = nil
            dock.closeTarget(id)
        }
        tabs.remove(at: i)
        if tabs.isEmpty { window.performClose(nil); return }
        if tab === selected {
            selected = nil
            select(tabs[min(i, tabs.count - 1)])
        } else {
            rebuildTabBar()
        }
        saveSession()
    }

    // MARK: - 休眠

    private func scheduleHibernation() {
        hibernateTimer?.invalidate()
        guard settings.hibernateMinutes > 0 else { return }
        hibernateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.hibernateIdleTabs() }
        // メモリが逼迫したら、時間を待たずに選択中以外を眠らせる(DuckDuckGo の TabSuspensionService と同じ契機)。
        // 再生中・入力中のタブは force しないので残る
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            for tab in self.tabs where tab !== self.selected && tab.webView != nil
                && Date().timeIntervalSince(tab.lastActive) > 60 {
                self.hibernate(tab, force: false)
            }
        }
        source.resume()
        memoryPressure = source
    }
    private var memoryPressure: DispatchSourceMemoryPressure?

    private func hibernateIdleTabs() {
        let limit = TimeInterval(settings.hibernateMinutes * 60)
        for tab in tabs where tab !== selected && tab.webView != nil && Date().timeIntervalSince(tab.lastActive) > limit {
            hibernate(tab, force: false)
        }
        enforceAwakeBudget()
    }

    /// 「大量タブ」対策の本命(Codexとの独立検討でも一致): アイドル時間を待たず、
    /// 起きている背景タブの数そのものに上限を設ける。DuckDuckGoのTabLazyLoaderと同じ発想。
    /// 超えた分は最終アクティブが古い順に休眠対象へ回す(force:false なので再生中・入力中のタブは
    /// 予算を超えても残る — 動画・会議のタブを枠の都合で強制終了しない)
    private let maxAwakeBackgroundTabs = 6
    private func enforceAwakeBudget() {
        let awake = tabs.filter { $0 !== selected && $0.webView != nil }.sorted { $0.lastActive < $1.lastActive }
        let overflow = awake.count - maxAwakeBackgroundTabs
        guard overflow > 0 else { return }
        for tab in awake.prefix(overflow) { hibernate(tab, force: false) }
    }

    /// 再生中のメディアや入力途中のフォームがあるタブは眠らせない(force のときは眠らせる)
    /// 実機で踏んだ事故(2026-09-20、Codexとの調査): 大量タブを一気に開き、判定(evaluateJavaScript)の
    /// 返事が来ないタブ(読み込み中など)に対して、メモリ逼迫のたびに何度も判定要求を重ねて発行し続けた結果、
    /// 未完了の要求(と、それぞれが強参照する WKWebView)が積み上がり、Idaten本体が4.9GBまで膨張してクラッシュした。
    /// 対策は2つ: ①force(強制休眠)はJSの返事を待たず即座に破棄する ②通常経路は「既に判定中のタブへは
    /// 重ねて要求しない」+「一定時間で返事が無ければ諦めて休眠を進める」
    func hibernate(_ tab: Tab, force: Bool) {
        guard let wv = tab.webView, tab !== selected || force else { return }
        if force {
            tab.interactionState = wv.interactionState
            tab.savedScrollY = 0
            tab.hibernationCheckInFlight = false
            tab.dropWebView()
            rebuildTabBar()
            return
        }
        guard !tab.hibernationCheckInFlight else { return }
        tab.hibernationCheckInFlight = true
        let js = """
        (function(){
          var playing = Array.prototype.some.call(document.querySelectorAll('video,audio'), function(m){ return !m.paused && !m.ended; });
          var a = document.activeElement;
          var editing = !!a && (a.isContentEditable || ((a.tagName === 'TEXTAREA' || a.tagName === 'INPUT') && (a.value || '').length > 0));
          return { playing: playing, editing: editing, y: window.scrollY };
        })()
        """
        var finished = false
        let finish: (Bool, Bool, Double) -> Void = { [weak self, weak tab] playing, editing, y in
            guard !finished else { return }   // タイムアウトとJS完了の両方が発火した場合、先着だけを使う
            finished = true
            guard let self, let tab, tab.webView === wv else { return }
            tab.hibernationCheckInFlight = false
            if playing || editing { tab.lastActive = Date(); return }
            tab.interactionState = wv.interactionState
            tab.savedScrollY = tab.interactionState == nil ? y : 0
            tab.dropWebView()
            self.rebuildTabBar()
        }
        wv.evaluateJavaScript(js) { result, _ in
            let info = result as? [String: Any] ?? [:]
            finish(info["playing"] as? Bool ?? false, info["editing"] as? Bool ?? false, info["y"] as? Double ?? 0)
        }
        // 3秒返事が無ければ「読み込み中で判定できない」とみなし、busy扱いで一旦諦める(強制はしない)。
        // 次の巡回で再挑戦できるよう lastActive は更新せず、in-flight フラグだけ下ろす
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak tab] in
            guard !finished else { return }
            finished = true
            tab?.hibernationCheckInFlight = false
        }
    }

    /// デバッグ専用: 「Swift側の帳簿(webView!=nilの数)」と「OS側のWebContentプロセス数」が一致しているかを
    /// 実機で突き合わせるためのダンプ(Codexとの調査、2026-09-20)。⌘⌥D。要らなくなったら消す
    @objc func debugDumpState() {
        let awake = tabs.filter { $0.webView != nil }
        let lines = ["awakeWebViews=\(awake.count) selected=\(selected.map { ObjectIdentifier($0) }?.debugDescription ?? "nil")"]
            + awake.map { "  tab=\(ObjectIdentifier($0)) url=\($0.url?.absoluteString ?? "nil") selected=\($0 === selected)" }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: Paths.support.appendingPathComponent("debug_dump.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - エンジン切替(段A)

    @objc func switchEngine() {
        guard let tab = selected, let url = tab.url, let host = url.host else { return }
        if tab.isChromium { moveBackToWebKit(tab); return }
        let already = rules.engine(forHost: host, profileDefault: profile.defaultEngine) == .chromium
        let alert = NSAlert()
        alert.messageText = "このページを Chromium エンジンで開きます"
        alert.informativeText = "Chromium 側は別エンジンのため、Cookie・ログイン状態は共有されません(初回はログインし直しになります)。拡張機能は Chromium 側に入れたものが使えます。"
        alert.addButton(withTitle: "Chromiumで開く")
        alert.addButton(withTitle: "キャンセル")
        let check = NSButton(checkboxWithTitle: "\(host) は常に Chromium で開く", target: nil, action: nil)
        check.state = already ? .on : .off
        alert.accessoryView = check
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rules.setOverride(host, check.state == .on ? .chromium : nil)
        tab.forceWebKit = false   // 明示の切替は「WebKit のまま」の指定より優先する
        handOff(url, in: tab)
        updateToolbar()
    }

    /// AI(端末内モデル)が「拡張機能が要りそう」と判定したドメインに、確認の上で切替を提案する。
    /// switchEngine() と違い利用者からの明示操作ではないので、常に確認ダイアログを挟み、既定は「このまま」側にする
    private func offerAIEngineSwitch(host: String, tab: Tab) {
        guard tab === selected, tab.url?.host == host else { return }   // 判定が終わる頃には別タブに移っているかもしれない
        let alert = NSAlert()
        alert.messageText = "このサイトは拡張機能が必要かもしれません"
        alert.informativeText = "\(host) の内容を端末内のAIが見て、Chrome拡張機能を前提にしている可能性が高いと判定しました。"
            + "Chromiumエンジンで開き直しますか?(Cookie・ログイン状態は引き継がれません)"
        alert.addButton(withTitle: "Chromiumで開く")
        alert.addButton(withTitle: "このまま")
        let check = NSButton(checkboxWithTitle: "\(host) は常に Chromium で開く", target: nil, action: nil)
        alert.accessoryView = check
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rules.setOverride(host, check.state == .on ? .chromium : nil)
        handOff(tab.url!, in: tab)
        updateToolbar()
    }

    /// url を Chromium で開く。`tab` を渡せばそのタブ自体を Chromium タブへ置き換え、無ければ新しいタブにする。
    /// Idaten のタブバーに並び、Helium の窓は内容領域へ重なる(別ブラウザとして立ち上がった形にはしない)
    /// `tab` が背景のタブなら選択は奪わない(⌘クリックで裏に開いたページのリダイレクト等。Codexレビュー #11)
    @discardableResult
    private func handOff(_ url: URL, in tab: Tab? = nil, activate: Bool = true) -> Bool {
        if let tab, tab.forceWebKit { return false }
        // 既定は従来どおり「別窓で開く」。重ね窓は設定で選んだときだけ(Settings.dockChromiumWindow を参照)
        guard settings.dockChromiumWindow else {
            switch chromium.open(url) {
            case .success:
                tab?.handedOffExternally = true
                rebuildTabBar()
                return true
            case .failure(let err): showEngineError(err); return false
            }
        }
        switch dock.ensureStarted() {
        case .success:
            let t = tab ?? newTab(url: url, select: false, hibernated: true)
            // 失敗したら WebKit へ戻せるよう、戻る/進むの履歴は捨てずに退避しておく(Codexレビュー #7)
            if let wv = t.webView { t.interactionState = wv.interactionState }
            t.dropWebView()
            t.isChromium = true
            t.chromiumTargetId = nil
            t.url = url
            if (tab == nil && activate) || (tab != nil && tab === selected) { select(t) } else { requestChromiumTarget(t); rebuildTabBar() }
            saveSession()
            return true
        case .failure(let err):
            showEngineError(err)
            return false
        }
    }

    private func showEngineError(_ err: ChromiumProcessEngine.EngineError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch err {
        case .notInstalled(let names):
            alert.messageText = "Chromium系エンジンが見つかりません"
            alert.informativeText = "次のいずれかを入れてください: \(names.joined(separator: " / "))\n候補は \(Paths.engineConfig.path) で変えられます。"
        case .launchFailed(let why):
            alert.messageText = "Chromium系エンジンを起動できませんでした"
            alert.informativeText = why
        }
        alert.runModal()
    }

    // MARK: - Chromium タブ(ChromiumDock)

    /// 最後に重ねた Chromium タブ。WebKit タブへ切り替えた後も、Idaten の窓を動かしたら一緒に動かす
    /// (置いていくと Idaten の窓の外に Helium の窓がはみ出して見える)
    private var dockedTargetId: String?

    /// 内容領域の位置を CDP の座標系(主画面の左上が原点)で返す
    private func dockRect() -> CGRect {
        root.layoutSubtreeIfNeeded()
        let r = window.convertToScreen(container.convert(container.bounds, to: nil))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Chromium タブを見ている間、Idaten の枠(タブバー・URLバー)を Helium より上の階層に置く。
    /// そうしないと、ページをクリックして Helium が前面に来た瞬間に Helium 自身のタブバーが顔を出し、
    /// 「ブラウザが上下に2つ」に見える(本人の指摘 2026-09-23)。
    /// ただし他のアプリへ移ったときまで浮いていると邪魔なので、Idaten か Helium が最前面のアプリのときだけ上げる
    private var appActivationWatcher: Any?
    /// front には「いま前面になったアプリ」の pid を渡す。NSWorkspace.frontmostApplication は
    /// 切り替わりの通知を受けた時点でまだ古い値を返すことがあり、それで階層が上がらなかった(実測 2026-09-23)
    private func updateWindowLevel(front: pid_t? = nil) {
        let frontPid = front ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let wantFloat = selected?.isChromium == true &&
            (frontPid == ProcessInfo.processInfo.processIdentifier || (dock.pid != nil && frontPid == dock.pid))
        let level: NSWindow.Level = wantFloat ? .floating : .normal
        if window.level != level { window.level = level }
    }

    private func watchAppActivation() {
        guard appActivationWatcher == nil else { return }
        appActivationWatcher = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateWindowLevel(front: app?.processIdentifier)
        }
    }

    private func showChromium(_ tab: Tab) {
        root.layoutSubtreeIfNeeded()
        root.hole = container.frame
        watchAppActivation()
        updateWindowLevel()
        progress.isHidden = true
        window.makeFirstResponder(nil)
        if case .failure = dock.ensureStarted() {
            // Helium が無い等。従来どおり別アプリとして渡す経路へ落とす
            if let url = tab.url { _ = chromium.open(url) }
            return
        }
        if let id = tab.chromiumTargetId {
            dockedTargetId = id
            dock.show(id, at: dockRect(), stillWanted: { [weak self, weak tab] in tab != nil && self?.selected === tab })
            return
        }
        requestChromiumTarget(tab)
    }

    /// Helium にこのタブのページを作ってもらう。応答が来た時点でタブが閉じられていたり WebKit へ戻されていたら、
    /// 作られたページは閉じて捨てる(Codexレビュー #2)
    private func requestChromiumTarget(_ tab: Tab) {
        guard tab.pendingCreate == nil, tab.chromiumTargetId == nil, let url = tab.url else { return }
        let token = UUID()
        tab.pendingCreate = token
        tab.urlAtCreate = url
        dock.createTarget(url) { [weak self, weak tab] id in
            guard let self else { return }
            guard let tab, tab.pendingCreate == token, tab.isChromium,
                  self.tabs.contains(where: { $0 === tab }) else {
                if let id { self.dock.closeTarget(id) }
                return
            }
            tab.pendingCreate = nil
            guard let id else {
                // 作れなかった(Helium が起動直後に終わった=同じプロファイルの Helium が既に動いていて転送した等、
                // または createTarget 自体の失敗)。穴の開いたまま放置せず WebKit に戻し、URL は従来どおり外の Helium へ渡す
                // (再レビュー: 切断時は先にこの失敗が届いてから dockDisconnected が来るので、ここで戻す)
                tab.isChromium = false
                _ = self.chromium.open(tab.url ?? url)
                if tab === self.selected { self.select(tab) } else { self.rebuildTabBar() }
                self.saveSession()
                return
            }
            tab.chromiumTargetId = id
            // 応答待ちの間に URL バーで別の URL を入れていたら、そちらへ移動し直す(Codexレビュー #10)
            if let now = tab.url, now != tab.urlAtCreate { self.dock.navigate(id, to: now) }
            tab.urlAtCreate = nil
            if tab === self.selected {
                self.dockedTargetId = id
                self.dock.show(id, at: self.dockRect(), stillWanted: { [weak self, weak tab] in tab != nil && self?.selected === tab })
            }
        }
    }

    /// ⌘⇧E を Chromium タブで押したとき: WebKit へ戻す
    private func moveBackToWebKit(_ tab: Tab) {
        if let id = tab.chromiumTargetId { dock.closeTarget(id) }
        if dockedTargetId == tab.chromiumTargetId { dockedTargetId = nil }
        tab.chromiumTargetId = nil
        tab.pendingCreate = nil
        tab.isChromium = false
        // ドメイン例外(親ドメイン指定も)やプロファイル既定が Chromium でも、このタブは WebKit のままにする。
        // 完全一致の例外だけ消しても、読み込んだ瞬間にまた Chromium へ戻される(Codexレビュー #9)
        tab.forceWebKit = true
        tab.interactionState = nil   // Chromium へ移す前の WebKit の状態が残っていると、今の URL でなく古いページが戻る
        select(tab)
        saveSession()
    }

    private func heliumIsActive() -> Bool {
        guard let pid = dock.pid else { return false }
        return NSRunningApplication(processIdentifier: pid)?.isActive ?? false
    }

    func dockTargetCreated(_ targetId: String, url: URL?, title: String) {
        if tabs.contains(where: { $0.chromiumTargetId == targetId }) { return }
        // Helium 側で開かれたタブ(⌘T・拡張・リンクの別タブ)。Idaten のタブバーにも並べる
        let tab = Tab()
        tab.isChromium = true
        tab.chromiumTargetId = targetId
        tab.url = url
        tab.title = title
        if let sel = selected, let i = tabs.firstIndex(where: { $0 === sel }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        // いま Helium を操作している最中に開いたタブなら、利用者はそれを見たいはず
        if heliumIsActive() { select(tab) } else { rebuildTabBar() }
        saveSession()
    }

    func dockTargetChanged(_ targetId: String, url: URL?, title: String) {
        guard let tab = tabs.first(where: { $0.chromiumTargetId == targetId }) else { return }
        if let url, url.absoluteString != "about:blank" {
            if tab.url != url, selfTestDir == nil, let scheme = url.scheme, scheme == "http" || scheme == "https" {
                history.record(url: url, title: title)
            }
            tab.url = url
        }
        if !title.isEmpty { tab.title = title }
        rebuildTabBar()
        if tab === selected { updateToolbar() }
        saveSession()
    }

    /// Helium 側でタブが閉じられた。利用者が Helium の中でそのタブを閉じたのか、Helium ごと ⌘Q で終わる途中なのかは
    /// この時点では区別できない(待ち時間で区別しようとすると両方向に外れる。再レビュー #3)。
    /// なので一旦タブバーから外して控えておき、10秒以内に Helium ごと切断されたら元の位置へ戻す(迷ったら残す側)。
    /// 外れるのは「タブを閉じてから10秒以内に Helium を終了した」場合だけで、そのときは閉じたタブが戻ってくる(失うよりまし)
    private var closedInHelium: [(tab: Tab, index: Int, at: Date)] = []
    func dockTargetDestroyed(_ targetId: String) {
        guard let tab = tabs.first(where: { $0.chromiumTargetId == targetId }),
              let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        if dockedTargetId == targetId { dockedTargetId = nil }
        tab.chromiumTargetId = nil
        let now = Date()
        closedInHelium.removeAll { now.timeIntervalSince($0.at) > 10 }
        // 最後の1枚なら窓ごと閉じてしまうので外さない(切断後に戻せなくなる)。選ばれたら Helium で開き直す
        guard tabs.count > 1 else { rebuildTabBar(); return }
        closedInHelium.append((tab, i, now))
        close(tab)
    }

    func dockDisconnected() {
        let now = Date()
        for c in closedInHelium.sorted(by: { $0.index < $1.index }) where now.timeIntervalSince(c.at) <= 10 {
            tabs.insert(c.tab, at: min(c.index, tabs.count))
        }
        closedInHelium.removeAll()
        // タブは残し、選ばれたときに Helium を起動し直して開き直す
        for t in tabs where t.isChromium { t.chromiumTargetId = nil }
        dockedTargetId = nil
        rebuildTabBar()
        saveSession()
    }

    private func followWindow() {
        if selected?.isChromium == true { root.layoutSubtreeIfNeeded(); root.hole = container.frame }
        guard let id = dockedTargetId else { return }
        dock.place(id, at: dockRect())
    }
    /// Idaten だけが前面に出ると、Helium の窓は元の順のままなので、間に別アプリの窓が入り込む
    /// (実測 2026-09-23: Idaten を前面にした直後、穴の下が iTerm2 になった)。
    /// Chromium タブを見ている間に Idaten が前面へ来たら、Helium を上げ直してから自分を戻し、2枚を隣り合わせに保つ
    private var lastRaise = Date.distantPast
    func windowDidBecomeKey(_ notification: Notification) {
        guard selected?.isChromium == true, let pid = dock.pid,
              let helium = NSRunningApplication(processIdentifier: pid),
              Date().timeIntervalSince(lastRaise) > 1 else { return }   // 自分を戻すと再び呼ばれるので間隔で止める
        lastRaise = Date()
        helium.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.selected?.isChromium == true else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
        }
    }

    func windowDidMove(_ notification: Notification) { followWindow() }
    func windowDidResize(_ notification: Notification) { followWindow() }
    func windowDidEndLiveResize(_ notification: Notification) { followWindow() }
    func windowDidMiniaturize(_ notification: Notification) { if let id = dockedTargetId { dock.minimize(id) } }
    func windowDidDeminiaturize(_ notification: Notification) {
        if let t = selected, t.isChromium, let id = t.chromiumTargetId {
            dock.show(id, at: dockRect(), stillWanted: { [weak self, weak t] in t != nil && self?.selected === t })
        } else { followWindow() }
    }

    // MARK: - 操作

    @objc func newTabAction() { newTab(url: URL(string: "about:blank")); focusURLField() }
    @objc func closeTabAction() { if let t = selected { close(t) } }

    // MARK: - ブックマーク

    @objc func toggleBookmarkCurrentPage() {
        guard let url = selected?.url?.absoluteString, url != "about:blank" else { return }
        if let existing = bookmarks.items.first(where: { $0.url == url }) {
            bookmarks.remove(existing.id)
        } else {
            bookmarks.add(title: selected?.title.isEmpty == false ? selected!.title : url, url: url)
        }
        onBookmarksChanged?()
        updateToolbar()
    }

    /// メニュー(main.swift)がブックマーク一覧を再構築する際のフック。追加/削除のたびに呼ぶ
    var onBookmarksChanged: (() -> Void)?
    @objc func focusURLField() { window.makeFirstResponder(urlField); urlField.selectText(nil) }

    /// 編集を始めたら、表示用に整えた文字列でなく本物のURLを入れる(コピー・手直しのため)
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === urlField,
              let url = selected?.url, url.absoluteString != "about:blank" else { return }
        let full = url.absoluteString
        if field.stringValue != full {
            field.stringValue = full
            field.currentEditor()?.selectAll(nil)
        }
    }

    // MARK: - ページ内検索(⌘F)

    private var findBar: NSView?
    private let findField = NSTextField()
    private let findCount = NSTextField(labelWithString: "")

    @objc func performFind() {
        guard selected?.webView != nil else { return }
        if findBar == nil { buildFindBar() }
        findBar?.isHidden = false
        window.makeFirstResponder(findField)
        findField.selectText(nil)
    }

    @objc func findNext() { runFind(forward: true) }
    @objc func findPrevious() { runFind(forward: false) }
    @objc func closeFindBar() {
        findBar?.isHidden = true
        selected?.webView.map { window.makeFirstResponder($0) }
    }

    private func runFind(forward: Bool) {
        guard let wv = selected?.webView, !findField.stringValue.isEmpty else { return }
        let conf = WKFindConfiguration()
        conf.backwards = !forward
        conf.caseSensitive = false
        conf.wraps = true
        wv.find(findField.stringValue, configuration: conf) { [weak self] result in
            self?.findCount.stringValue = result.matchFound ? "" : "見つかりません"
        }
    }

    private func buildFindBar() {
        findField.placeholderString = "ページ内を検索"
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findNext)
        findField.bezelStyle = .roundedBezel
        findField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        findCount.textColor = .secondaryLabelColor
        findCount.font = .systemFont(ofSize: 11)
        func button(_ symbol: String, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: sel)
            b.isBordered = false
            b.toolTip = tip
            return b
        }
        let bar = NSStackView(views: [findField, findCount,
                                      button("chevron.up", "前へ (⇧⌘G)", #selector(findPrevious)),
                                      button("chevron.down", "次へ (⌘G)", #selector(findNext)),
                                      button("xmark", "閉じる (esc)", #selector(closeFindBar))])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        // ページの上に浮かべる板。角丸と縁と影を付けて、ページの一部に見えないようにする(Safari の検索バーと同じ形)
        let panel = NSVisualEffectView()
        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 8
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.shadow = NSShadow()
        panel.layer?.shadowOpacity = 0.18
        panel.layer?.shadowRadius = 6
        panel.layer?.shadowOffset = CGSize(width: 0, height: -2)
        panel.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(bar)
        root.addSubview(panel)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: panel.topAnchor),
            bar.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
        ])
        findBar = panel
    }

    // MARK: - URLバーの候補(履歴・ブックマーク)

    /// 入力のたびに候補を出す。日本語入力の変換中(marked text)は邪魔になるので出さない
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === urlField,
              let editor = field.currentEditor() as? NSTextView,
              !editor.hasMarkedText(), field.stringValue.count >= 2 else { return }
        editor.complete(nil)
    }

    /// 履歴(訪問回数の多い順)とブックマークから候補を作る。記録はしていたのに出口が無かった部分
    func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                 forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        guard control === urlField else { return words }
        let text = textView.string
        guard text.count >= 2 else { return [] }
        let fromHistory = history.suggest(text, limit: 6).map(\.url)
        let lower = text.lowercased()
        let fromBookmarks = bookmarks.items
            .filter { $0.url.lowercased().contains(lower) || $0.title.lowercased().contains(lower) }
            .prefix(3).map(\.url)
        var seen = Set<String>()
        return (fromHistory + fromBookmarks).filter { seen.insert($0).inserted }
    }

    /// 検索欄で esc を押したら閉じる
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === findField, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        closeFindBar()
        return true
    }

    // MARK: - 拡大縮小・停止・番号でタブ切替

    @objc func zoomIn() { selected?.webView.map { $0.pageZoom = min($0.pageZoom * 1.1, 5) } }
    @objc func zoomOut() { selected?.webView.map { $0.pageZoom = max($0.pageZoom / 1.1, 0.25) } }
    @objc func zoomReset() { selected?.webView?.pageZoom = 1 }
    @objc func stopLoading() { selected?.webView?.stopLoading(); progress.isHidden = true }

    /// ⌘1〜⌘8 はその番号のタブ、⌘9 は最後のタブ(ブラウザの慣習に合わせる)
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard !tabs.isEmpty else { return }
        let n = sender.tag
        select(n == 9 ? tabs[tabs.count - 1] : (tabs.indices.contains(n - 1) ? tabs[n - 1] : tabs[tabs.count - 1]))
    }
    @objc func goBack() {
        if let id = selected?.chromiumTargetId { dock.history(id, -1) } else { selected?.webView?.goBack() }
    }
    @objc func goForward() {
        if let id = selected?.chromiumTargetId { dock.history(id, 1) } else { selected?.webView?.goForward() }
    }
    @objc func reload() {
        if let id = selected?.chromiumTargetId { dock.reload(id) } else { selected?.webView?.reload() }
    }
    @objc func nextTab() { step(+1) }
    @objc func previousTab() { step(-1) }
    @objc func hibernateOthers() { for t in tabs where t !== selected { hibernate(t, force: true) } }

    private func step(_ d: Int) {
        guard let s = selected, let i = tabs.firstIndex(where: { $0 === s }), tabs.count > 1 else { return }
        select(tabs[(i + d + tabs.count) % tabs.count])
    }

    /// ドラッグ中の x 座標から「何番目の位置か」を求めて、その場で並べ替える。
    /// タブの幅は内容で変わるので、各タブの中心と比べて挿入位置を決める
    func dragTab(_ tab: Tab, toWindowX x: CGFloat) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        let centers = tabStack.arrangedSubviews.map { v -> CGFloat in
            let r = v.convert(v.bounds, to: nil)
            return r.midX
        }
        var to = centers.firstIndex(where: { x < $0 }) ?? tabs.count - 1
        to = min(max(0, to), tabs.count - 1)
        guard to != from else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: to)
        rebuildTabBar()
        saveSession()
    }

    @objc private func tabClicked(_ sender: NSButton) { if tabs.indices.contains(sender.tag) { select(tabs[sender.tag]) } }
    @objc private func tabCloseClicked(_ sender: NSButton) { if tabs.indices.contains(sender.tag) { close(tabs[sender.tag]) } }

    @objc private func urlEntered() {
        guard let url = resolveInput(urlField.stringValue, searchURL: settings.searchURL) else { return }
        if let tab = selected, tab.isChromium {   // Chromium タブの中での移動は Chromium のまま
            tab.url = url
            if let id = tab.chromiumTargetId { dock.navigate(id, to: url) } else if tab.pendingCreate == nil { showChromium(tab) }
            return
        }
        if selected?.forceWebKit != true, rules.engine(forHost: url.host, profileDefault: profile.defaultEngine) == .chromium {
            handOff(url, in: selected?.webView?.url == nil ? selected : nil); return
        }
        if selected == nil { newTab(url: url); return }
        selected?.url = url
        selected?.webView?.load(URLRequest(url: url))
        if let wv = selected?.webView { window.makeFirstResponder(wv) }
    }

    func open(_ url: URL) {
        if rules.engine(forHost: url.host, profileDefault: profile.defaultEngine) == .chromium { handOff(url); return }
        newTab(url: url)
    }

    // MARK: - 自己検査(--selftest <dir>)

    /// 画面収録の権限なしで「本当に描画されたか」を確かめる。最初の読み込み完了の数秒後に
    /// web.png(ページ)/ ui.png(タブバーとツールバー)/ report.json(題名・URL・読み込んだリソースのホスト別件数)を書いて終了する。
    /// 広告遮断の効果は、adBlockEnabled を変えて report.json の resourceHosts を比べて測る(WKContentRuleList は遮断件数を通知しない)。
    var selfTestDir: URL?
    private var selfTestFired = false
    /// --selftest-set-cookie <domain>: 自己検査の前に、このプロファイルのデータストアへ検証用Cookieを1個仕込む。
    /// 別プロファイルで同じドメインを検査したとき見えなければ、プロファイル間でCookieが分離できている証拠になる
    var selfTestSetCookieDomain: String?

    /// --selftest-hibernate: タブAを1500pxスクロール → タブBを開く → Aを強制休眠 → Aへ戻る → URLとスクロール位置が戻ったかを
    /// hibernate.json に書いて終了する
    var selfTestHibernate = false
    private var hibStep = 0
    private weak var hibTabA: Tab?
    private var hibURLBefore = ""

    private func advanceHibernateTest(_ tab: Tab, _ wv: WKWebView, dir: URL) {
        switch hibStep {
        case 0:   // A の読み込み完了
            hibStep = 1; hibTabA = tab
            wv.evaluateJavaScript("window.scrollTo(0, 1500); location.href") { [self] r, _ in
                hibURLBefore = r as? String ?? ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    newTab(url: URL(string: "https://example.com/"))
                }
            }
        case 1:   // B の読み込み完了 → A を眠らせて、戻る
            guard tab !== hibTabA, let a = hibTabA else { return }
            hibStep = 2
            hibernate(a, force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                let wasHibernated = a.isHibernated
                let hadState = a.interactionState != nil
                hibStep = wasHibernated ? 3 : 99
                hibReport = ["hibernated": wasHibernated, "hadInteractionState": hadState]
                select(a)
            }
        case 3:   // A の復帰完了
            guard tab === hibTabA else { return }
            hibStep = 4
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                wv.evaluateJavaScript("({ y: window.scrollY, url: location.href })") { [self] r, _ in
                    let info = r as? [String: Any] ?? [:]
                    hibReport["urlBefore"] = hibURLBefore
                    hibReport["urlAfter"] = info["url"] as? String ?? ""
                    hibReport["scrollYAfter"] = info["y"] as? Double ?? -1
                    hibReport["scrollYExpected"] = 1500
                    if let data = try? JSONSerialization.data(withJSONObject: hibReport, options: [.prettyPrinted, .sortedKeys]) {
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try? data.write(to: dir.appendingPathComponent("hibernate.json"))
                    }
                    NSApp.terminate(nil)
                }
            }
        default: break
        }
    }
    private var hibReport: [String: Any] = [:]

    /// --selftest-dock <dir>: 「1ブラウザ」第1段の機械検査。画面収録の権限なしで、CDP が返す Helium の窓の位置と
    /// Idaten の内容領域を突き合わせる。①Chromiumで開く ②窓を動かして追従 ③WebKitタブへ切替→戻す ④結果を dock.json へ
    var selfTestDock = false

    /// --selftest-tabs <dir>: タブの並べ替え(ドラッグ相当)と中クリックで閉じる経路を機械的に確かめる
    func runTabSelfTest(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...3 { newTab(url: URL(string: "https://example.com/?t=\(i)"), select: false, hibernated: true, title: "タブ\(i)") }
        rebuildTabBar()
        window.layoutIfNeeded()
        var report: [String: Any] = ["before": tabs.map(\.title)]
        // 1枚目を一番右へ運ぶ(器の中心より右の座標を渡す)
        if let first = tabs.first, let lastView = tabStack.arrangedSubviews.last {
            let x = lastView.convert(lastView.bounds, to: nil).maxX + 20
            dragTab(first, toWindowX: x)
        }
        report["afterDragFirstToEnd"] = tabs.map(\.title)
        // 中クリックで閉じる経路(TabCellView.onClose と同じ)
        if let second = tabs.first(where: { $0.title == "タブ2" }) { close(second) }
        report["afterMiddleClickClose"] = tabs.map(\.title)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("tabs.json"))
        }
        NSApp.terminate(nil)
    }

    /// --dock-demo <url>: Chromium タブを開いたまま待機する(終了しない)。
    /// 画面収録の権限が無くても、外から次の2つを機械的に確かめられるようにするためのモード:
    ///   ①穴の位置に、Idaten と Helium の窓がこの順で重なっているか(CGWindowList は権限不要)
    ///   ②穴の中心へのクリックが Helium のページに届くか(下の counts が増える)
    func runDockDemo(url: URL, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        handOff(url, in: selected)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in
            guard let id = selected?.chromiumTargetId else { return }
            dock.evaluate(id, "window.__idatenClicks = 0; addEventListener('mousedown', () => window.__idatenClicks++, true); 'ok'") { [self] _ in
                Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [self] _ in
                    guard let id = selected?.chromiumTargetId else { return }
                    let r = dockRect()
                    dock.evaluate(id, "({clicks: window.__idatenClicks, title: document.title, y: Math.round(window.scrollY)})") { [self] v in
                        var info: [String: Any] = ["hole": ["left": Int(r.minX), "top": Int(r.minY), "width": Int(r.width), "height": Int(r.height)],
                                                   "heliumPid": dock.pid.map { Int($0) } ?? -1,
                                                   "idatenPid": ProcessInfo.processInfo.processIdentifier,
                                                   "page": (v as? [String: Any]) ?? [:]]
                        info["idatenActive"] = NSApp.isActive
                        if let d = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
                            try? d.write(to: dir.appendingPathComponent("demo.json"), options: .atomic)
                        }
                    }
                }
            }
        }
    }

    /// 穴越しのクリックが Helium に届くかの実測。Idaten を前面(キー窓)に戻してから、穴の中心の座標を
    /// clickpoint.json に書いて外(シェル)からの合成クリックを待ち、Helium のページが受けた回数を読む。
    /// 画面の見た目は測れない(画面収録の権限が無い)が、クリックの行き先は機械的に確かめられる
    private func clickThroughTest(_ done: @escaping () -> Void) {
        guard let dir = selfTestDir, let id = selected?.chromiumTargetId else { done(); return }
        dock.evaluate(id, "window.__idatenClicks = 0; addEventListener('mousedown', () => window.__idatenClicks++, true); 'ok'") { [self] _ in
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                let r = dockRect()
                let point = ["x": Int(r.midX), "y": Int(r.midY), "idatenIsActive": NSApp.isActive ? 1 : 0]
                if let data = try? JSONSerialization.data(withJSONObject: point) {
                    try? data.write(to: dir.appendingPathComponent("clickpoint.json"))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in
                    dock.evaluate(id, "window.__idatenClicks") { [self] v in
                        var rep = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("dock.partial.json")))) as? [String: Any] ?? [:]
                        rep["clicksReceivedByHelium"] = v ?? "nil"
                        rep["idatenActiveBeforeClick"] = point["idatenIsActive"]
                        rep["heliumActiveAfterClick"] = dock.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.isActive } ?? false
                        if let d = try? JSONSerialization.data(withJSONObject: rep) { try? d.write(to: dir.appendingPathComponent("dock.partial.json")) }
                        done()
                    }
                }
            }
        }
    }
    func runDockSelfTest(url: URL, dir: URL) {
        var report: [String: Any] = [:]
        func rect(_ r: CGRect) -> [String: Int] {
            ["left": Int(r.minX.rounded()), "top": Int(r.minY.rounded()), "width": Int(r.width.rounded()), "height": Int(r.height.rounded())]
        }
        func finish() {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let extra = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("dock.partial.json")))) as? [String: Any] {
                report.merge(extra) { a, _ in a }
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("dock.json"))
            }
            NSApp.terminate(nil)
        }
        func measure(_ key: String, then: @escaping () -> Void) {
            guard let t = selected, let id = t.chromiumTargetId else {
                report[key] = ["error": "Chromiumタブが選ばれていない/targetId無し", "selectedIsChromium": selected?.isChromium ?? false]
                then(); return
            }
            dock.windowBounds(id) { [self] b in
                report[key] = ["expected": rect(dockRect()), "actual": b ?? [:], "hole": root.hole.map { rect($0) } ?? [:],
                               "tabs": tabs.count, "title": t.title, "url": t.url?.absoluteString ?? ""]
                then()
            }
        }
        let wait = { (sec: Double, f: @escaping () -> Void) in DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: f) }
        report["heliumPidBefore"] = dock.pid.map { Int($0) } ?? -1
        handOff(url, in: selected)
        wait(6) { [self] in
            report["heliumPid"] = dock.pid.map { Int($0) } ?? -1
            measure("1_opened") { [self] in
                var f = window.frame; f.origin.x += 120; f.origin.y -= 60; f.size.width -= 80
                window.setFrame(f, display: true)
                wait(2) { [self] in
                    measure("2_after_move_resize") { [self] in
                        let chromeTab = selected
                        newTab(url: URL(string: "https://example.com/"))
                        wait(3) { [self] in
                            report["3_webkit_selected"] = ["isChromium": selected?.isChromium ?? false, "hole": root.hole == nil ? "none" : "open",
                                                           "webViewAttached": selected?.webView?.superview != nil]
                            if let c = chromeTab { select(c) }
                            wait(2) { [self] in
                                measure("4_back_to_chromium") { [self] in
                                    report["tabEngines"] = tabs.map { $0.isChromium ? "chromium" : "webkit" }
                                    clickThroughTest { finish() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func runSelfTest(_ wv: WKWebView, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 検索バーの見た目も自己検査で撮れるようにしておく(画面収録の権限が無くても確認できる)
        if ProcessInfo.processInfo.environment["IDATEN_SELFTEST_FIND"] == "1" {
            performFind()
            findField.stringValue = "韋駄天"
            runFind(forward: true)
        }
        func png(_ image: NSImage) -> Data? {
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
        if let root = window.contentView, let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("ui.png"))
        }
        let js = """
        (function(){
          var hosts = {};
          performance.getEntriesByType('resource').forEach(function(e){
            try { var h = new URL(e.name).host; hosts[h] = (hosts[h] || 0) + 1; } catch (err) {}
          });
          return { title: document.title, url: location.href, resources: performance.getEntriesByType('resource').length,
                   resourceHosts: hosts, textLength: (document.body ? document.body.innerText.length : 0),
                   userAgent: navigator.userAgent };
        })()
        """
        wv.evaluateJavaScript(js) { [self] result, error in
            var report = result as? [String: Any] ?? ["error": String(describing: error)]
            report["tabs"] = tabs.count
            // Codexとの検討: 「起きているWKWebViewの数」と「OS上のWebContentプロセス数」は別物かもしれない仮説を検証する
            report["awakeWebViews"] = tabs.filter { $0.webView != nil }.count
            report["ruleLists"] = ruleLists.count
            report["adBlockEnabled"] = settings.adBlockEnabled
            // HttpOnly(JS から見えない)ログイン用Cookieも含めて、実際にディスクへ持続しているストアの中身を数える。
            // 値そのものは書き出さない(ドメインと件数だけ) — 認証情報をログに残さないため
            wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                var perDomain: [String: Int] = [:]
                for c in cookies { perDomain[c.domain, default: 0] += 1 }
                report["cookieDomains"] = perDomain
                report["cookieTotal"] = cookies.count
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: dir.appendingPathComponent("report.json"))
                }
                wv.takeSnapshot(with: nil) { image, _ in
                    if let image, let data = png(image) { try? data.write(to: dir.appendingPathComponent("web.png")) }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - セッション

    func saveSession() {
        if selfTestDir != nil { return }   // 自己検査は利用者のセッションを上書きしない
        let st = tabs.compactMap { t -> SessionTab? in
            guard let u = t.url, u.absoluteString != "about:blank" else { return nil }
            return SessionTab(url: u.absoluteString, title: t.title, engine: t.isChromium ? .chromium : nil)
        }
        let idx = selected.flatMap { s in tabs.firstIndex(where: { $0 === s }) } ?? 0
        if let data = try? JSONEncoder().encode(Session(tabs: st, selected: idx)) {
            try? data.write(to: paths.session, options: .atomic)
        }
    }

    /// 復元したタブは選択中の1枚以外すべて休眠のまま — 起動直後のメモリを抑える
    private func restoreSession() {
        if selfTestDir != nil { return }
        guard let data = try? Data(contentsOf: paths.session),
              let s = try? JSONDecoder().decode(Session.self, from: data), !s.tabs.isEmpty else { return }
        // 暴走ガード: 万一セッションが壊れて/事故で肥大化していても、数百タブをそのまま復元して固まらないようにする。
        // 超えた分は静かに捨てず、本人が気づけるようログへ残す
        let cap = 60
        let toRestore = s.tabs.count > cap ? Array(s.tabs.suffix(cap)) : s.tabs
        if s.tabs.count > cap {
            NSLog("Idaten: セッションに%d件あり、直近%d件だけ復元しました(残りは破棄)", s.tabs.count, cap)
        }
        for t in toRestore {
            guard let u = URL(string: t.url) else { continue }
            let tab = newTab(url: u, select: false, hibernated: true, title: t.title, skipUIRebuild: true)
            tab.isChromium = t.engine == .chromium   // Helium 側には選ばれた時に作る
        }
        rebuildTabBar()
        if !tabs.isEmpty { select(tabs[min(max(0, s.selected), tabs.count - 1)]) }
        saveSession()
    }

    /// プロファイルウィンドウが1つ閉じても、他のプロファイルのウィンドウが残っていればアプリは終了しない。
    /// 終了判定自体は AppKit の `applicationShouldTerminateAfterLastWindowClosed`(main.swift)に任せる
    var onClosed: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        saveSession()
        dock.delegate = nil
        dock.shutdown()
        onClosed?()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url,
           tabs.first(where: { $0.webView === webView })?.forceWebKit != true,
           rules.engine(forHost: url.host, profileDefault: profile.defaultEngine) == .chromium {
            decisionHandler(.cancel)
            // まだ何も表示していないタブ(新規タブ・window.open 直後)なら、そのタブごと Chromium にする
            let tab = tabs.first(where: { $0.webView === webView })
            // 背景のタブから来た移動なら、新しく作る Chromium タブも背景のまま(再レビュー #11)
            handOff(url, in: webView.url == nil ? tab : nil, activate: tab == nil || tab === selected)
            return
        }
        // ⌘クリックは裏のタブで開く
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            decisionHandler(.cancel)
            newTab(url: url, select: false)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        if selfTestDir == nil, let url = webView.url { history.record(url: url, title: webView.title) }   // 自己検査は利用者の履歴に書かない
        if tab.savedScrollY > 0 {
            webView.evaluateJavaScript("window.scrollTo(0, \(tab.savedScrollY))", completionHandler: nil)
            tab.savedScrollY = 0
        }
        if tab === selected { progress.isHidden = true }
        fetchFavicon(for: tab, webView)
        saveSession()
        if let dir = selfTestDir, selfTestHibernate {
            advanceHibernateTest(tab, webView, dir: dir)
        } else if let dir = selfTestDir, !selfTestDock, !selfTestFired, tab === selected {
            selfTestFired = true
            // 遅延読み込みの広告・計測が出そろうのを待つ
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.runSelfTest(webView, dir: dir) }
        } else if selfTestDir == nil {
            checkIfNeedsChromium(webView, tab: tab)
        }
    }

    /// ファビコンはホスト単位で1回だけ取り、以後は使い回す。
    /// 取得は WKWebView のデータストア越しではなく素の URLSession(Cookie を送らない)
    private static var faviconCache: [String: NSImage] = [:]
    private func fetchFavicon(for tab: Tab, _ webView: WKWebView) {
        guard let host = webView.url?.host else { return }
        if let cached = Self.faviconCache[host] {
            if tab.favicon == nil { tab.favicon = cached; rebuildTabBar() }
            return
        }
        let js = "(document.querySelector(\"link[rel~='icon']\") || {}).href || ''"
        webView.evaluateJavaScript(js) { [weak self, weak tab] result, _ in
            let href = (result as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            guard let url = href ?? webView.url.flatMap({ URL(string: "/favicon.ico", relativeTo: $0)?.absoluteURL }) else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = NSImage(data: data), image.size.width > 0 else { return }
                DispatchQueue.main.async {
                    Self.faviconCache[host] = image
                    guard let self, let tab, tab.favicon == nil else { return }
                    tab.favicon = image
                    self.rebuildTabBar()
                }
            }.resume()
        }
    }

    /// ホストごとに1回だけ、AI(端末内モデル)に「拡張機能が要りそうか」を判定させる。
    /// 通信は発生しない(Appleの共有モデルのみ)。判定できない環境では即座に何もしない
    private var aiCheckedHosts: Set<String> = []
    private func checkIfNeedsChromium(_ webView: WKWebView, tab: Tab) {
        guard settings.aiEngineSuggestEnabled, AIEngineAdvisor.isAvailable(),
              let url = webView.url, let host = url.host,
              url.scheme == "http" || url.scheme == "https",
              rules.engine(forHost: host, profileDefault: profile.defaultEngine) != .chromium,
              !aiCheckedHosts.contains(host) else { return }
        aiCheckedHosts.insert(host)
        webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 600) : ''") { [weak self, weak webView] result, _ in
            guard let self, let webView, let text = result as? String, !text.isEmpty else { return }
            Task { @MainActor in
                let suggest = await AIEngineAdvisor.suggestsChromiumEngine(pageText: text, url: url.absoluteString)
                guard suggest, webView.url?.host == host,
                      let tab = self.tabs.first(where: { $0.webView === webView }) else { return }
                self.offerAIEngineSwitch(host: host, tab: tab)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled || e.code == 102 { return }   // 102 = ポリシーで止めた(ダウンロード・エンジン切替)
        let msg = e.localizedDescription.replacingOccurrences(of: "<", with: "&lt;")
        let failing = (e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? "").replacingOccurrences(of: "<", with: "&lt;")
        webView.loadHTMLString("""
            <meta charset="utf-8"><body style="font: 15px -apple-system; margin: 15vh auto; max-width: 520px; color: #555">
            <h2 style="font-weight:600">ページを開けませんでした</h2><p>\(msg)</p><p style="word-break:break-all;color:#999">\(failing)</p></body>
            """, baseURL: nil)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    // MARK: - WKDownloadDelegate

    // MARK: - ダウンロード一覧
    /// 何がどこへ落ちたかを覚えておく(これまでは完了音だけで、保存先が分からなかった)。
    /// 一覧はメニューから開く。中身はこの起動中だけ持つ
    struct DownloadRecord { var name: String; var destination: URL?; var done: Bool; var failed: String? }
    private(set) var downloads: [DownloadRecord] = []
    private var downloadIndex: [ObjectIdentifier: Int] = [:]
    var onDownloadsChanged: (() -> Void)?

    @objc func revealDownload(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = dir.appendingPathComponent(suggestedFilename)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {   // 既存ファイルは上書きしない
            n += 1
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        downloads.insert(DownloadRecord(name: dest.lastPathComponent, destination: dest, done: false, failed: nil), at: 0)
        downloadIndex[ObjectIdentifier(download)] = 0
        for (k, v) in downloadIndex where k != ObjectIdentifier(download) { downloadIndex[k] = v + 1 }
        onDownloadsChanged?()
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let i = downloadIndex[ObjectIdentifier(download)], downloads.indices.contains(i) {
            downloads[i].done = true
            onDownloadsChanged?()
        }
        NSSound(named: "Glass")?.play()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let i = downloadIndex[ObjectIdentifier(download)], downloads.indices.contains(i) {
            downloads[i].failed = error.localizedDescription
            onDownloadsChanged?()
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ダウンロードに失敗しました"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - WKUIDelegate

    /// window.open / target=_blank。渡された configuration で作らないと opener との関係が切れ、OAuthのポップアップが壊れる
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let tab = newTab(url: navigationAction.request.url, configuration: configuration)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tabs.first(where: { $0.webView === webView }) { close(tab) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "キャンセル")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "キャンセル")
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}
