import AppKit
import WebKit

final class BrowserWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate,
    WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    let window: NSWindow
    let profile: Profile
    let paths: ProfilePaths
    var settings = Settings.load()
    let rules: EngineRules
    let chromium: ChromiumProcessEngine
    let history: History
    /// このプロファイル専用のCookie/localStorage/認証状態。他プロファイルとは完全に別の身元になる
    let dataStore: WKWebsiteDataStore

    private(set) var tabs: [Tab] = []
    private(set) var selected: Tab?
    private var ruleLists: [WKContentRuleList] = []

    private let tabStack = NSStackView()
    private let urlField = NSTextField()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let engineButton = NSButton()
    private let progress = NSProgressIndicator()
    private let container = NSView()
    private var hibernateTimer: Timer?

    init(profile: Profile) {
        self.profile = profile
        self.paths = ProfilePaths(profile: profile)
        self.rules = EngineRules(path: paths.engineRules)
        self.chromium = ChromiumProcessEngine(profileDir: paths.chromiumProfile)
        self.history = History(path: paths.history)
        self.dataStore = WKWebsiteDataStore(forIdentifier: profile.dataStoreIdentifier)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Karu — \(profile.name)"
        window.delegate = self
        window.setFrameAutosaveName("KaruWindow-\(profile.id)")
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.windowBackground   // 動的NSColorなのでライト/ダーク切替に自動追従する
        buildUI()
    }

    // MARK: - UI

    private func buildUI() {
        let root = NSView()
        window.contentView = root

        tabStack.orientation = .horizontal
        tabStack.spacing = 2
        tabStack.alignment = .centerY
        tabStack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        let tabScroll = NSScrollView()
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
        engineButton.bezelStyle = .rounded
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

        // 複数プロファイルのウィンドウを同時に開いたとき、どれがどのプロファインかを一目で(設計DBの"ビール3杯理論":
        // 文字を読まなくても色だけでわかるようにする)
        let profileDot = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        profileDot.wantsLayer = true
        profileDot.layer?.backgroundColor = NSColor(hex: profile.colorHex).cgColor
        profileDot.layer?.cornerRadius = 5
        profileDot.toolTip = "プロファイル: \(profile.name)"
        profileDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        profileDot.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let toolbar = NSStackView(views: [profileDot, backButton, forwardButton, reloadButton, urlField, engineButton, newTabButton])
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
            tabScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
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
            for e in errors { NSLog("Karu adblock: %@", e) }
            begin()
        }
    }

    private func rebuildTabBar() {
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, tab) in tabs.enumerated() {
            // エンジンの種別は文字でなく色ドットで示す(見た目の負荷が低く、離れて見てもわかる)
            let dot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = (tab.handedToChromium ? Theme.EngineDot.chromium : Theme.EngineDot.webkit).cgColor
            dot.toolTip = tab.handedToChromium ? "Chromiumエンジンで表示中" : "WebKitエンジンで表示中"
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

            let title = NSButton(title: tab.displayTitle, target: self, action: #selector(tabClicked(_:)))
            title.tag = i
            title.isBordered = false
            title.lineBreakMode = .byTruncatingTail
            title.font = .systemFont(ofSize: 12, weight: tab === selected ? .semibold : .regular)
            title.contentTintColor = tab === selected ? .labelColor : .secondaryLabelColor
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "閉じる")!,
                                 target: self, action: #selector(tabCloseClicked(_:)))
            close.tag = i
            close.isBordered = false
            close.imageScaling = .scaleProportionallyDown
            close.widthAnchor.constraint(equalToConstant: 14).isActive = true
            let cell = NSStackView(views: [dot, title, close])
            cell.orientation = .horizontal
            cell.spacing = 4
            cell.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6)
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 6
            cell.layer?.backgroundColor = (tab === selected ? NSColor.controlAccentColor.withAlphaComponent(0.18) : .clear).cgColor
            tabStack.addArrangedSubview(cell)
        }
    }

    private func updateToolbar() {
        let wv = selected?.webView
        backButton.isEnabled = wv?.canGoBack ?? false
        forwardButton.isEnabled = wv?.canGoForward ?? false
        if window.firstResponder !== urlField.currentEditor() {
            let s = selected?.url?.absoluteString ?? ""
            urlField.stringValue = s == "about:blank" ? "" : s
        }
        let always = rules.engine(forHost: selected?.url?.host) == .chromium
        engineButton.title = always ? "Chromium固定" : "WebKit"
        window.title = selected.map { $0.title.isEmpty ? "Karu" : $0.title } ?? "Karu"
    }

    // MARK: - タブ

    private func makeConfiguration() -> WKWebViewConfiguration {
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = dataStore   // このプロファイル専用のCookie/ログイン状態
        conf.applicationNameForUserAgent = settings.userAgentSuffix
        conf.preferences.isElementFullscreenEnabled = true
        for l in ruleLists { conf.userContentController.add(l) }
        return conf
    }

    private func makeWebView(_ tab: Tab, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let conf = configuration ?? makeConfiguration()
        if configuration != nil { for l in ruleLists { conf.userContentController.add(l) } }
        let wv = WKWebView(frame: .zero, configuration: conf)
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

    @discardableResult
    func newTab(url: URL?, select: Bool = true, hibernated: Bool = false, title: String? = nil,
                configuration: WKWebViewConfiguration? = nil) -> Tab {
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
            if configuration == nil, let url, url.absoluteString != "about:blank" { wv.load(URLRequest(url: url)) }
        }
        if select { self.select(tab) } else { rebuildTabBar() }
        saveSession()
        return tab
    }

    func select(_ tab: Tab) {
        selected?.lastActive = Date()
        selected?.webView?.removeFromSuperview()
        selected = tab
        tab.lastActive = Date()
        if tab.webView == nil {   // 休眠からの復帰
            let wv = makeWebView(tab)
            tab.handedToChromium = false
            if let state = tab.interactionState {
                wv.interactionState = state   // 代入すると現在の項目を自分で読み込む
                tab.interactionState = nil
            } else if let url = tab.url, url.absoluteString != "about:blank" {
                wv.load(URLRequest(url: url))
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
    func hibernate(_ tab: Tab, force: Bool) {
        guard let wv = tab.webView, tab !== selected || force else { return }
        let js = """
        (function(){
          var playing = Array.prototype.some.call(document.querySelectorAll('video,audio'), function(m){ return !m.paused && !m.ended; });
          var a = document.activeElement;
          var editing = !!a && (a.isContentEditable || ((a.tagName === 'TEXTAREA' || a.tagName === 'INPUT') && (a.value || '').length > 0));
          return { playing: playing, editing: editing, y: window.scrollY };
        })()
        """
        wv.evaluateJavaScript(js) { [weak self, weak tab] result, _ in
            guard let self, let tab, tab.webView === wv else { return }
            let info = result as? [String: Any] ?? [:]
            let busy = (info["playing"] as? Bool ?? false) || (info["editing"] as? Bool ?? false)
            if busy && !force { tab.lastActive = Date(); return }
            tab.interactionState = wv.interactionState
            // interactionState が取れなかったときだけ、URL再読込+スクロール位置で代用する
            tab.savedScrollY = tab.interactionState == nil ? (info["y"] as? Double ?? 0) : 0
            tab.dropWebView()
            self.rebuildTabBar()
        }
    }

    // MARK: - エンジン切替(段A)

    @objc func switchEngine() {
        guard let tab = selected, let url = tab.url, let host = url.host else { return }
        let already = rules.engine(forHost: host) == .chromium
        let alert = NSAlert()
        alert.messageText = "このページを Chromium エンジンで開きます"
        alert.informativeText = "Chromium 側は別エンジンのため、Cookie・ログイン状態は共有されません(初回はログインし直しになります)。拡張機能は Chromium 側に入れたものが使えます。"
        alert.addButton(withTitle: "Chromiumで開く")
        alert.addButton(withTitle: "キャンセル")
        let check = NSButton(checkboxWithTitle: "\(host) は常に Chromium で開く", target: nil, action: nil)
        check.state = already ? .on : .off
        alert.accessoryView = check
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rules.setChromium(host, check.state == .on)
        if handOff(url) {
            tab.handedToChromium = true
            if tabs.count > 1 { hibernate(tab, force: true) }
        }
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
        rules.setChromium(host, check.state == .on)
        if handOff(tab.url!) {
            tab.handedToChromium = true
            if tabs.count > 1 { hibernate(tab, force: true) }
        }
        updateToolbar()
    }

    @discardableResult
    private func handOff(_ url: URL) -> Bool {
        switch chromium.open(url) {
        case .success: return true
        case .failure(let err):
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
            return false
        }
    }

    // MARK: - 操作

    @objc func newTabAction() { newTab(url: URL(string: "about:blank")); focusURLField() }
    @objc func closeTabAction() { if let t = selected { close(t) } }
    @objc func focusURLField() { window.makeFirstResponder(urlField); urlField.selectText(nil) }
    @objc func goBack() { selected?.webView?.goBack() }
    @objc func goForward() { selected?.webView?.goForward() }
    @objc func reload() { selected?.webView?.reload() }
    @objc func nextTab() { step(+1) }
    @objc func previousTab() { step(-1) }
    @objc func hibernateOthers() { for t in tabs where t !== selected { hibernate(t, force: true) } }

    private func step(_ d: Int) {
        guard let s = selected, let i = tabs.firstIndex(where: { $0 === s }), tabs.count > 1 else { return }
        select(tabs[(i + d + tabs.count) % tabs.count])
    }

    @objc private func tabClicked(_ sender: NSButton) { if tabs.indices.contains(sender.tag) { select(tabs[sender.tag]) } }
    @objc private func tabCloseClicked(_ sender: NSButton) { if tabs.indices.contains(sender.tag) { close(tabs[sender.tag]) } }

    @objc private func urlEntered() {
        guard let url = resolveInput(urlField.stringValue, searchURL: settings.searchURL) else { return }
        if rules.engine(forHost: url.host) == .chromium { handOff(url); return }
        if selected == nil { newTab(url: url); return }
        selected?.url = url
        selected?.webView?.load(URLRequest(url: url))
        if let wv = selected?.webView { window.makeFirstResponder(wv) }
    }

    func open(_ url: URL) {
        if rules.engine(forHost: url.host) == .chromium { handOff(url); return }
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

    private func runSelfTest(_ wv: WKWebView, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
            return SessionTab(url: u.absoluteString, title: t.title)
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
        for t in s.tabs {
            guard let u = URL(string: t.url) else { continue }
            newTab(url: u, select: false, hibernated: true, title: t.title)
        }
        if !tabs.isEmpty { select(tabs[min(max(0, s.selected), tabs.count - 1)]) }
    }

    /// プロファイルウィンドウが1つ閉じても、他のプロファイルのウィンドウが残っていればアプリは終了しない。
    /// 終了判定自体は AppKit の `applicationShouldTerminateAfterLastWindowClosed`(main.swift)に任せる
    var onClosed: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        saveSession()
        onClosed?()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url,
           rules.engine(forHost: url.host) == .chromium {
            decisionHandler(.cancel)
            handOff(url)
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
        if let url = webView.url { history.record(url: url, title: webView.title) }
        if tab.savedScrollY > 0 {
            webView.evaluateJavaScript("window.scrollTo(0, \(tab.savedScrollY))", completionHandler: nil)
            tab.savedScrollY = 0
        }
        if tab === selected { progress.isHidden = true }
        saveSession()
        if let dir = selfTestDir, selfTestHibernate {
            advanceHibernateTest(tab, webView, dir: dir)
        } else if let dir = selfTestDir, !selfTestFired, tab === selected {
            selfTestFired = true
            // 遅延読み込みの広告・計測が出そろうのを待つ
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.runSelfTest(webView, dir: dir) }
        } else if selfTestDir == nil {
            checkIfNeedsChromium(webView, tab: tab)
        }
    }

    /// ホストごとに1回だけ、AI(端末内モデル)に「拡張機能が要りそうか」を判定させる。
    /// 通信は発生しない(Appleの共有モデルのみ)。判定できない環境では即座に何もしない
    private var aiCheckedHosts: Set<String> = []
    private func checkIfNeedsChromium(_ webView: WKWebView, tab: Tab) {
        guard settings.aiEngineSuggestEnabled, AIEngineAdvisor.isAvailable(),
              let url = webView.url, let host = url.host,
              url.scheme == "http" || url.scheme == "https",
              rules.engine(forHost: host) != .chromium,
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
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSSound(named: "Glass")?.play()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
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
