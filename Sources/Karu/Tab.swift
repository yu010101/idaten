import WebKit

/// 1タブ。webView が nil で url があれば「休眠中」— メモリを持たず、選ばれたときに作り直す
final class Tab: NSObject {
    let id = UUID()
    var url: URL?
    var title = "新しいタブ"
    var webView: WKWebView?
    var lastActive = Date()
    var savedScrollY = 0.0
    /// ⌘⇧E で Chromium 側へ渡したタブ。WebKit 側は休眠させて印だけ残す
    var handedToChromium = false
    var observations: [NSKeyValueObservation] = []

    var isHibernated: Bool { webView == nil && url != nil }

    var displayTitle: String {
        let base = title.isEmpty ? (url?.host ?? "新しいタブ") : title
        if handedToChromium { return "→C " + base }
        if isHibernated { return "z " + base }
        return base
    }

    func dropWebView() {
        observations.removeAll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }
}

struct SessionTab: Codable { var url: String; var title: String }
struct Session: Codable { var tabs: [SessionTab]; var selected: Int }
