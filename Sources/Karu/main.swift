// Karu — 軽い・広告カット・タブごとにエンジンを切り替えるブラウザ。
// 既定は WKWebView(OSのWebKitを使うので本体は小さい)。拡張が要る作業だけ Chromium 系エンジンへ渡す(⌘⇧E)。
//
// プロファイル: 実測(2026-09-20)で、本人のChrome15プロファイル中12個は拡張ゼロ・アカウント分離だけが目的だった。
// Karuも「1プロファイル=1つのCookie/ログイン身元=1ウィンドウ」を複数持てるようにしている(Chromeの多重ログインと同じ形)。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        let browser = openWindow(for: startProfile)
        if let i = args.firstIndex(of: "--selftest"), args.indices.contains(i + 1) {
            browser.selfTestDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        if args.contains("--selftest-hibernate") { browser.selfTestHibernate = true }
        if let i = args.firstIndex(of: "--selftest-set-cookie"), args.indices.contains(i + 1) {
            browser.selfTestSetCookieDomain = args[i + 1]
        }
        if args.contains("--no-adblock") { browser.settings.adBlockEnabled = false }   // この起動だけ。設定ファイルは書き換えない
        browser.start(openURLs: argURLs + pendingURLs)
        pendingURLs = []
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 指定プロファイルのウィンドウを、無ければ作って、あれば前面に出す
    @discardableResult
    private func openWindow(for profile: Profile, urls: [URL] = []) -> BrowserWindowController {
        if let existing = windows[profile.id] {
            existing.window.makeKeyAndOrderFront(nil)
            urls.forEach(existing.open)
            return existing
        }
        let controller = BrowserWindowController(profile: profile)
        controller.onClosed = { [weak self] in self?.windows.removeValue(forKey: profile.id) }
        windows[profile.id] = controller
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i].lastOpenedAt = Date()
            ProfileStore.save(profiles)
        }
        controller.start(openURLs: urls)
        return controller
    }

    @objc private func newProfile() {
        let alert = NSAlert()
        alert.messageText = "新しいプロファイル"
        alert.informativeText = "用途がわかる名前を付けてください(例: radineer.com、経理、転職活動)。Cookie・履歴・拡張ルールはこのプロファイル専用になります。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "作成")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let profile = Profile.makeNew(name: name, colorHex: ProfileStore.nextColor(usedBy: profiles))
        profiles.append(profile)
        ProfileStore.save(profiles)
        rebuildProfileMenu()
        openWindow(for: profile)
    }

    @objc private func switchToProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let p = profiles.first(where: { $0.id == id }) else { return }
        openWindow(for: p)
    }

    /// 他アプリからリンクを渡されたとき(既定ブラウザにした場合)。最後に触っていたプロファイルで開く
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let browser = activeBrowser else { pendingURLs += urls; return }
        urls.forEach(browser.open)
    }

    func applicationWillTerminate(_ notification: Notification) { windows.values.forEach { $0.saveSession() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private var profileMenu: NSMenu?

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
        _ = add("Karu", [
            item("Karu について", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", []),
            .separator(),
            item("Karu を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("Karu を終了", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("ファイル", [
            item("新しいタブ", #selector(B.newTabAction), "t"),
            item("場所を開く…", #selector(B.focusURLField), "l"),
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
            item("戻る", #selector(B.goBack), "["),
            item("進む", #selector(B.goForward), "]"),
        ])
        _ = add("タブ", [
            item("次のタブ", #selector(B.nextTab), "]", [.command, .shift]),
            item("前のタブ", #selector(B.previousTab), "[", [.command, .shift]),
            .separator(),
            item("ほかのタブを休眠させる", #selector(B.hibernateOthers), "z", [.command, .option]),
            .separator(),
            item("エンジンを切り替える(Chromiumで開く)", #selector(B.switchEngine), "e", [.command, .shift]),
        ])
        profileMenu = add("プロファイル", [])
        rebuildProfileMenu()
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
