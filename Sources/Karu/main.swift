// Karu — 軽い・広告カット・タブごとにエンジンを切り替えるブラウザ。
// 既定は WKWebView(OSのWebKitを使うので本体は小さい)。拡張が要る作業だけ Chromium 系エンジンへ渡す(⌘⇧E)。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var browser: BrowserWindowController!
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        browser = BrowserWindowController()
        // 引数のURL(計測シナリオや `open -a Karu --args URL` 用)
        let argURLs = CommandLine.arguments.dropFirst().compactMap { a -> URL? in
            guard a.hasPrefix("http://") || a.hasPrefix("https://") || a.hasPrefix("file://") else { return nil }
            return URL(string: a)
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), args.indices.contains(i + 1) {
            browser.selfTestDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        if args.contains("--no-adblock") { browser.settings.adBlockEnabled = false }   // この起動だけ。設定ファイルは書き換えない
        browser.start(openURLs: argURLs + pendingURLs)
        pendingURLs = []
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 他アプリからリンクを渡されたとき(既定ブラウザにした場合)
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let browser else { pendingURLs += urls; return }
        urls.forEach(browser.open)
    }

    func applicationWillTerminate(_ notification: Notification) { browser?.saveSession() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
        }
        func item(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        typealias B = BrowserWindowController
        add("Karu", [
            item("Karu について", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", []),
            .separator(),
            item("Karu を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("Karu を終了", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("ファイル", [
            item("新しいタブ", #selector(B.newTabAction), "t"),
            item("場所を開く…", #selector(B.focusURLField), "l"),
            .separator(),
            item("タブを閉じる", #selector(B.closeTabAction), "w"),
        ])
        add("編集", [   // これが無いとURLバーで ⌘C/⌘V/⌘A が効かない
            item("取り消す", Selector(("undo:")), "z"),
            item("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("カット", #selector(NSText.cut(_:)), "x"),
            item("コピー", #selector(NSText.copy(_:)), "c"),
            item("ペースト", #selector(NSText.paste(_:)), "v"),
            item("すべてを選択", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("表示", [
            item("再読み込み", #selector(B.reload), "r"),
            item("戻る", #selector(B.goBack), "["),
            item("進む", #selector(B.goForward), "]"),
        ])
        add("タブ", [
            item("次のタブ", #selector(B.nextTab), "]", [.command, .shift]),
            item("前のタブ", #selector(B.previousTab), "[", [.command, .shift]),
            .separator(),
            item("ほかのタブを休眠させる", #selector(B.hibernateOthers), "z", [.command, .option]),
            .separator(),
            item("エンジンを切り替える(Chromiumで開く)", #selector(B.switchEngine), "e", [.command, .shift]),
        ])
        NSApp.mainMenu = main
    }

    /// メニューの操作をブラウザ本体へ流す(ターゲット未指定のメニュー項目はレスポンダチェーンの最後にここへ来る)
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (browser?.responds(to: aSelector) ?? false)
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        (browser?.responds(to: aSelector) ?? false) ? browser : super.forwardingTarget(for: aSelector)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
