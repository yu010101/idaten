// Idaten — 軽い・広告カット・タブごとにエンジンを切り替えるブラウザ。
// 既定は WKWebView(OSのWebKitを使うので本体は小さい)。拡張が要る作業だけ Chromium 系エンジンへ渡す(⌘⇧E)。
//
// プロファイル: 実測(2026-09-20)で、本人のChrome15プロファイル中12個は拡張ゼロ・アカウント分離だけが目的だった。
// Idatenも「1プロファイル=1つのCookie/ログイン身元=1ウィンドウ」を複数持てるようにしている(Chromeの多重ログインと同じ形)。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var profiles: [Profile] = []
    private var windows: [String: BrowserWindowController] = [:]   // profile.id -> controller
    private var pendingURLs: [URL] = []

    /// メニュー操作の転送先。基本は最前面のウィンドウの持ち主
    private var activeBrowser: BrowserWindowController? {
        (NSApp.keyWindow?.delegate as? BrowserWindowController) ?? windows.values.first
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        profiles = ProfileStore.loadOrCreate()
        buildMenu()

        let argURLs = CommandLine.arguments.dropFirst().compactMap { a -> URL? in
            guard a.hasPrefix("http://") || a.hasPrefix("https://") || a.hasPrefix("file://") else { return nil }
            return URL(string: a)
        }
        let args = CommandLine.arguments
        // 最後に開いていたプロファイルだけを起動する(Chromeの「前回の続き」と同じ)。他は「プロファイル」メニューから開ける。
        // `--profile <名前>` で明示指定もできる(自己検査・複数プロファイルの動作確認用)
        var startProfile = profiles.max(by: { $0.lastOpenedAt < $1.lastOpenedAt }) ?? profiles[0]
        if let i = args.firstIndex(of: "--profile"), args.indices.contains(i + 1),
           let p = profiles.first(where: { $0.name == args[i + 1] }) {
            startProfile = p
        }
        // autoStart:false — このあと selftest 系フラグ/adBlockEnabled を設定してから明示的に start() する。
        // (バグの実話 2026-09-20: ここを true のままにしていたら openWindow 内部で1回・直後にもう1回、
        //  同じコントローラで start()→restoreSession() が2回走り、セッションが起動のたびに倍々に膨らんだ。
        //  200件→60件[暴走ガードで打ち止め]→保存→2回目の復元で120件、という形で実機再現・特定した)
        let browser = openWindow(for: startProfile, autoStart: false)
        if let i = args.firstIndex(of: "--selftest"), args.indices.contains(i + 1) {
            browser.selfTestDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        if args.contains("--selftest-hibernate") { browser.selfTestHibernate = true }
        if let i = args.firstIndex(of: "--selftest-set-cookie"), args.indices.contains(i + 1) {
            browser.selfTestSetCookieDomain = args[i + 1]
        }
        if args.contains("--no-adblock") { browser.settings.adBlockEnabled = false }   // この起動だけ。設定ファイルは書き換えない
        // --selftest-panels <dir>: 設定・履歴の画面を描き出して見た目を確かめる(画面収録の権限が無くても見られる)
        // --selftest-handoff <dir> <url>: Chromium タブの取り込みと拡張の起動を確かめる。
        // プロファイルの置き場所を差し替えるので、利用者のデータには触らない
        if let i = args.firstIndex(of: "--selftest-handoff"), args.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            ProfilePaths.directoryOverride = dir
            let isolated = BrowserWindowController(profile: Profile.makeNew(name: "handoff", colorHex: "#888888"))
            windows["handoff"] = isolated
            isolated.selfTestDir = dir
            isolated.start(openURLs: [])
            if let url = argURLs.first { isolated.runHandoffSelfTest(url: url, dir: dir) }
            return
        }

        // --bench-isolated <dir>: 比較計測用。プロファイルの置き場所・Cookie・履歴・セッションを
        // すべてその dir の下に作る(Chrome の新品プロファイルと条件を揃えるため)。
        // 本人のデータには一切触らない
        if let i = args.firstIndex(of: "--bench-isolated"), args.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            ProfilePaths.directoryOverride = dir
            let isolated = BrowserWindowController(profile: Profile.makeNew(name: "bench", colorHex: "#888888"))
            isolated.settings.adBlockEnabled = browser.settings.adBlockEnabled
            windows["bench"] = isolated
            isolated.start(openURLs: argURLs)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // --bench <dir>: 比較計測用。利用者のセッション・履歴・ブックマークは読み書きせず、渡したURLを開いたまま待つ
        if let i = args.firstIndex(of: "--bench"), args.indices.contains(i + 1) {
            browser.selfTestDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            browser.selfTestDock = true     // 自己検査の撮影・終了処理は動かさない
            browser.start(openURLs: argURLs)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let i = args.firstIndex(of: "--selftest-panels"), args.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            browser.selfTestDir = dir
            browser.start(openURLs: [])
            settingsWindow.show()
            openHistory()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                openEngineRules()
                for (name, view) in [("settings.png", settingsWindow.contentViewForTest),
                                     ("history.png", historyWindow?.contentViewForTest),
                                     ("rules.png", rulesWindow?.contentViewForTest)] {
                    guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let i = args.firstIndex(of: "--selftest-session"), args.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            browser.selfTestDir = dir
            browser.start(openURLs: [])
            browser.runSessionSelfTest(dir: dir)
            return
        }
        if let i = args.firstIndex(of: "--selftest-tabs"), args.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            browser.selfTestDir = dir
            browser.start(openURLs: [])
            browser.runTabSelfTest(dir: dir)
            return
        }
        if let i = args.firstIndex(of: "--dock-demo"), args.indices.contains(i + 1) {
            // 利用者のセッションは読み書きしない。Chromium タブを1枚開いたまま待機する
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            browser.selfTestDir = dir
            browser.selfTestDock = true
            browser.start(openURLs: [])
            if let url = argURLs.first { browser.runDockDemo(url: url, dir: dir) }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let i = args.firstIndex(of: "--selftest-dock"), args.indices.contains(i + 1) {
            // 別の自己検査と同じく利用者のセッションは読まない/書かない(selfTestDir を立てる)
            let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            browser.selfTestDir = dir
            browser.selfTestDock = true
            browser.start(openURLs: [])
            if let url = argURLs.first { browser.runDockSelfTest(url: url, dir: dir) }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        browser.start(openURLs: argURLs + pendingURLs)
        pendingURLs = []
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 指定プロファイルのウィンドウを、無ければ作って、あれば前面に出す
    @discardableResult
    private func openWindow(for profile: Profile, urls: [URL] = [], autoStart: Bool = true) -> BrowserWindowController {
        if let existing = windows[profile.id] {
            existing.window.makeKeyAndOrderFront(nil)
            urls.forEach(existing.open)
            return existing
        }
        let controller = BrowserWindowController(profile: profile)
        controller.onClosed = { [weak self] in self?.windows.removeValue(forKey: profile.id) }
        controller.onDownloadsChanged = { [weak self] in self?.rebuildDownloadsMenu() }
        // ツールバーの色の点から、プロファイルを切り替えられるようにする
        controller.onProfileMenuRequested = { [weak self] button in
            guard let self else { return }
            let menu = NSMenu()
            for p in self.profiles.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }) {
                let i = NSMenuItem(title: p.name, action: #selector(self.switchToProfile(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = p.id
                i.state = p.id == profile.id ? .on : .off
                let dot = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                    NSColor(hex: p.colorHex).setFill()
                    NSBezierPath(ovalIn: rect).fill()
                    return true
                }
                i.image = dot
                menu.addItem(i)
            }
            menu.addItem(.separator())
            let add = NSMenuItem(title: "新しいプロファイル…", action: #selector(self.newProfile), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        windows[profile.id] = controller
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i].lastOpenedAt = Date()
            ProfileStore.save(profiles)
        }
        guard autoStart else { return controller }
        controller.start(openURLs: urls)
        return controller
    }

    @objc private func newProfile() {
        let alert = NSAlert()
        alert.messageText = "新しいプロファイル"
        alert.informativeText = "用途がわかる名前を付けてください(例: radineer.com、経理、転職活動)。Cookie・履歴・拡張ルールはこのプロファイル専用になります。"
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        // Codexとの検討(2026-09-20): crypto wallet等「初めて訪れるサイトでも拡張の力が要る」プロファイルは
        // ドメイン単位の例外では対応できない。プロファイル既定をChromiumにする選択肢をここで作れるようにする
        let chromiumDefault = NSButton(checkboxWithTitle: "このプロファイルは既定でChromiumエンジンを使う(暗号資産ウォレット等、あらゆるサイトで拡張機能が要る場合)", target: nil, action: nil)
        chromiumDefault.setContentHuggingPriority(.required, for: .horizontal)
        container.addArrangedSubview(field)
        container.addArrangedSubview(chromiumDefault)
        field.widthAnchor.constraint(equalToConstant: 380).isActive = true
        chromiumDefault.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        alert.accessoryView = container
        alert.addButton(withTitle: "作成")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let profile = Profile.makeNew(name: name, colorHex: ProfileStore.nextColor(usedBy: profiles),
                                      defaultEngine: chromiumDefault.state == .on ? .chromium : .webkit)
        profiles.append(profile)
        ProfileStore.save(profiles)
        rebuildProfileMenu()
        openWindow(for: profile)
    }

    @objc private func switchToProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let p = profiles.first(where: { $0.id == id }) else { return }
        openWindow(for: p)
    }

    /// Chromeから「すんなり移管」する。実測(2026-09-20)通り、拡張が無くログイン分離だけが目的のプロファイルも
    /// 多いので、Chromeの各プロファイルを1つずつ、対応するIdatenの新規プロファイルへブックマーク+履歴ごと持ってくる。
    /// パスワードは対象外(Keychain暗号化に依存し安全に横取りできない)。拡張は一覧だけ出す(自動では入れられない)
    @objc private func importFromChrome() {
        let chromeProfiles = ChromeImport.availableProfiles()
        guard !chromeProfiles.isEmpty else {
            let a = NSAlert(); a.messageText = "Chromeのプロファイルが見つかりませんでした"; a.runModal(); return
        }
        let picker = NSAlert()
        picker.messageText = "どのChromeプロファイルから移行しますか"
        picker.informativeText = "選んだプロファイルと同じ名前のIdatenプロファイルを新規作成し、ブックマーク・履歴を取り込みます。\nパスワードは対象外です(Keychainの暗号化に依存するため安全に取り込めません)。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        // NSPopUpButton.addItems(withTitles:) は同名タイトルを黙って除外し、以降の項目のインデックスが
        // ずれる(実機で踏んだ事故 2026-09-20: 名前が空欄で表示名が同じ"radineer.com"のプロファイルが2つあり、
        // 1件に統合されて後続が1つずつズレた結果、選んだのと違うプロファイルが取り込まれた——
        // 「カズキ」を選んだのに「wiseman.holdings」が処理された。修正・実機で再検証し正しく動作を確認)。
        // タイトル文字列でなく representedObject(dirName)で紐付け、取り出しもそこから行う
        for p in chromeProfiles {
            let title = p.email.isEmpty ? p.displayName : "\(p.displayName)(\(p.email))"
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.representedObject = p.dirName
            popup.menu?.addItem(mi)
        }
        picker.accessoryView = popup
        picker.addButton(withTitle: "取り込む")
        picker.addButton(withTitle: "キャンセル")
        guard picker.runModal() == .alertFirstButtonReturn else { return }
        guard let selectedDir = popup.selectedItem?.representedObject as? String,
              let source = chromeProfiles.first(where: { $0.dirName == selectedDir }) else { return }

        // 同名プロファイルが既にあれば増やさず、そこへ追加取り込みする
        let target: Profile
        if let existing = profiles.first(where: { $0.name == source.displayName }) {
            target = existing
        } else {
            target = Profile.makeNew(name: source.displayName, colorHex: ProfileStore.nextColor(usedBy: profiles))
            profiles.append(target)
            ProfileStore.save(profiles)
            rebuildProfileMenu()
        }
        let paths = ProfilePaths(profile: target)
        let bookmarks = BookmarkStore(path: paths.dir.appendingPathComponent("bookmarks.json"))
        let bmItems = ChromeImport.readBookmarks(profileDir: source.dirName)
        let addedBookmarks = bookmarks.importFromChrome(bmItems)
        let addedHistory = ChromeImport.importHistory(profileDir: source.dirName, into: paths.history)
        let extensions = ChromeImport.extensionNames(profileDir: source.dirName)

        let result = NSAlert()
        result.messageText = "「\(source.displayName)」から取り込みました"
        var msg = "ブックマーク \(addedBookmarks)件・履歴 \(addedHistory)件を取り込みました。"
        if !extensions.isEmpty {
            msg += "\n\nこのプロファイルには次の拡張機能が入っていました。使う場合はChromiumエンジン側(⌘⇧E)に入れ直してください:\n" + extensions.joined(separator: "、")
        }
        result.informativeText = msg
        result.runModal()
        openWindow(for: target)
    }

    /// 他アプリからリンクを渡されたとき(既定ブラウザにした場合)。最後に触っていたプロファイルで開く
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let browser = activeBrowser else { pendingURLs += urls; return }
        urls.forEach(browser.open)
    }

    func applicationWillTerminate(_ notification: Notification) {
        windows.values.forEach { $0.saveSession(); $0.dock.shutdown() }   // Helium も正常終了させる(次回は Idaten のセッションから開き直す)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private var profileMenu: NSMenu?
    private var bookmarkMenu: NSMenu?

    /// 開くたびに「今アクティブなプロファイル」のブックマークで作り直す(NSMenuDelegate、遅延構築)
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === downloadsMenu { rebuildDownloadsMenu(); return }
        guard menu === bookmarkMenu else { return }
        menu.removeAllItems()
        let addItem = NSMenuItem(title: "このページをブックマーク", action: #selector(BrowserWindowController.toggleBookmarkCurrentPage), keyEquivalent: "d")
        let barItem = NSMenuItem(title: "ブックマークバーを表示", action: #selector(BrowserWindowController.toggleBookmarkBar), keyEquivalent: "b")
        barItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(barItem)
        menu.addItem(addItem)
        menu.addItem(.separator())
        guard let list = activeBrowser?.bookmarks.items, !list.isEmpty else {
            let empty = NSMenuItem(title: "(ブックマークはまだありません)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for b in list.sorted(by: { $0.addedAt > $1.addedAt }) {
            let i = NSMenuItem(title: b.title, action: #selector(openBookmark(_:)), keyEquivalent: "")
            i.representedObject = b.url
            i.target = self
            i.toolTip = b.url
            menu.addItem(i)
        }
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let url = URL(string: urlString) else { return }
        activeBrowser?.open(url)
    }

    private func rebuildProfileMenu() {
        guard let menu = profileMenu else { return }
        menu.removeAllItems()
        for p in profiles.sorted(by: { $0.name < $1.name }) {
            let title = windows[p.id] != nil ? "● \(p.name)" : p.name
            let i = NSMenuItem(title: title, action: #selector(switchToProfile(_:)), keyEquivalent: "")
            i.representedObject = p.id
            i.target = self
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let newItem = NSMenuItem(title: "新しいプロファイル…", action: #selector(newProfile), keyEquivalent: "n")
        newItem.keyEquivalentModifierMask = [.command, .shift]
        newItem.target = self
        menu.addItem(newItem)
    }

    private var downloadsMenu: NSMenu?
    private lazy var settingsWindow: SettingsWindowController = {
        let c = SettingsWindowController()
        c.onSaved = { [weak self] s in
            // 開いている窓にも即反映する(広告遮断の入れ替えなど、次の読み込みから効く)
            self?.windows.values.forEach { $0.settings = s }
        }
        return c
    }()
    private var historyWindow: HistoryWindowController?

    @objc private func openSettings() { settingsWindow.show() }

    private var rulesWindow: EngineRulesWindowController?

    @objc private func openEngineRules() {
        guard let browser = activeBrowser else { return }
        let c = EngineRulesWindowController(rules: browser.rules, profileName: browser.profile.name)
        rulesWindow = c
        c.show()
    }

    @objc private func openHistory() {
        guard let browser = activeBrowser else { return }
        let c = HistoryWindowController(history: browser.history)
        c.onOpen = { [weak browser] url in browser?.open(url) }
        historyWindow = c
        c.show()
    }

    /// ダウンロードの一覧をメニューに反映する。項目を選ぶと Finder で場所を開く
    private func rebuildDownloadsMenu() {
        guard let menu = downloadsMenu else { return }
        menu.removeAllItems()
        let items = activeBrowser?.downloads ?? []
        if items.isEmpty {
            menu.addItem(NSMenuItem(title: "(ダウンロードはまだありません)", action: nil, keyEquivalent: ""))
            return
        }
        for d in items.prefix(15) {
            let state = d.failed != nil ? "失敗: \(d.failed!)" : (d.done ? "" : "(受信中)")
            let i = NSMenuItem(title: state.isEmpty ? d.name : "\(d.name) \(state)",
                               action: #selector(BrowserWindowController.revealDownload(_:)), keyEquivalent: "")
            i.representedObject = d.destination
            i.target = activeBrowser
            i.isEnabled = d.destination != nil
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "ダウンロードフォルダを開く", action: #selector(openDownloadsFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
    }

    @objc private func openDownloadsFolder() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        NSWorkspace.shared.open(dir)
    }

    private func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
            return m
        }
        func item(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        typealias B = BrowserWindowController
        _ = add("Idaten", [
            item("Idaten について", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", []),
            .separator(),
            { let i = item("設定…", #selector(openSettings), ","); i.target = self; return i }(),
            .separator(),
            item("Idaten を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("Idaten を終了", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let importItem = item("Chromeから移行…", #selector(importFromChrome), "")
        importItem.keyEquivalentModifierMask = []
        importItem.target = self   // AppDelegate自身のメソッドなので明示しないと呼ばれない(応答チェーン任せにしない)
        _ = add("ファイル", [
            item("新しいタブ", #selector(B.newTabAction), "t"),
            item("場所を開く…", #selector(B.focusURLField), "l"),
            .separator(),
            importItem,
            .separator(),
            item("タブを閉じる", #selector(B.closeTabAction), "w"),
        ])
        _ = add("編集", [   // これが無いとURLバーで ⌘C/⌘V/⌘A が効かない
            item("取り消す", Selector(("undo:")), "z"),
            item("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("カット", #selector(NSText.cut(_:)), "x"),
            item("コピー", #selector(NSText.copy(_:)), "c"),
            item("ペースト", #selector(NSText.paste(_:)), "v"),
            item("すべてを選択", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = add("表示", [
            item("再読み込み", #selector(B.reload), "r"),
            item("読み込みを停止", #selector(B.stopLoading), "."),
            item("戻る", #selector(B.goBack), "["),
            item("進む", #selector(B.goForward), "]"),
            .separator(),
            item("拡大", #selector(B.zoomIn), "+"),
            item("縮小", #selector(B.zoomOut), "-"),
            item("実際の大きさ", #selector(B.zoomReset), "0"),
        ])
        let historyItem = item("履歴を表示…", #selector(openHistory), "y")
        historyItem.target = self
        _ = add("履歴", [historyItem])
        downloadsMenu = add("ダウンロード", [])
        downloadsMenu?.delegate = self   // 開くたびに今の一覧で作り直す
        _ = add("検索", [
            item("ページ内を検索…", #selector(B.performFind), "f"),
            item("次を検索", #selector(B.findNext), "g"),
            item("前を検索", #selector(B.findPrevious), "g", [.command, .shift]),
        ])
        // ⌘1〜⌘8 はその番号、⌘9 は最後のタブ(Safari/Chrome と同じ慣習)
        let numbered: [NSMenuItem] = (1...9).map { n in
            let i = item(n == 9 ? "最後のタブ" : "\(n)番目のタブ", #selector(B.selectTabByNumber(_:)), "\(n)")
            i.tag = n
            return i
        }
        _ = add("タブ", [
            item("次のタブ", #selector(B.nextTab), "]", [.command, .shift]),
            item("前のタブ", #selector(B.previousTab), "[", [.command, .shift]),
            .separator(),
        ] + numbered + [
            .separator(),
            .separator(),
            item("ほかのタブを休眠させる", #selector(B.hibernateOthers), "z", [.command, .option]),
            .separator(),
            item("エンジンを切り替える(Chromiumで開く)", #selector(B.switchEngine), "e", [.command, .shift]),
            { let i = item("Chromium で開くサイトの一覧…", #selector(openEngineRules), ""); i.target = self; return i }(),
            item("Chromium の拡張を使う…", #selector(B.showExtensionMenu(_:)), "e", [.command, .option]),
            .separator(),
            item("[デバッグ] 状態をダンプ", #selector(B.debugDumpState), "d", [.command, .option]),
        ])
        profileMenu = add("プロファイル", [])
        rebuildProfileMenu()
        bookmarkMenu = add("ブックマーク", [])
        bookmarkMenu?.delegate = self   // menuNeedsUpdate で開くたびに作り直す(遅延構築)
        NSApp.mainMenu = main
    }

    /// メニューの操作を「今アクティブなプロファイルのウィンドウ」へ流す
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (activeBrowser?.responds(to: aSelector) ?? false)
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        (activeBrowser?.responds(to: aSelector) ?? false) ? activeBrowser : super.forwardingTarget(for: aSelector)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
