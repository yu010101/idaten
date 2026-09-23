import AppKit
import WebKit

/// 1タブ。webView が nil で url があれば「休眠中」— メモリを持たず、選ばれたときに作り直す
final class Tab: NSObject {
    let id = UUID()
    var url: URL?
    var title = "新しいタブ"
    var webView: WKWebView?
    var lastActive = Date()
    var savedScrollY = 0.0
    /// 休眠時に退避した WKWebView.interactionState(戻る/進むの履歴・スクロール位置・フォーム状態)。
    /// Kestrel(MIT)と DuckDuckGo(Apache-2.0)が同じ方式。URL だけ覚えて読み直すより復元が忠実
    var interactionState: Any?
    /// Chromium(Helium)で表示するタブ。webView は持たず、中身は ChromiumDock が重ねる Helium の窓にある。
    /// chromiumTargetId が nil なら「まだ Helium 側に作っていない」(セッション復元直後・Helium 終了後)
    var isChromium = false
    var chromiumTargetId: String?
    /// Helium 側へ作成を頼んで応答待ちの間だけ非 nil。閉じる/WebKit へ戻すと nil に戻して要求を無効にする
    /// (遅れて来た応答は、この値が一致しなければそのページを閉じて捨てる)
    var pendingCreate: UUID?
    /// 作成を頼んだ後に URL バーで別の URL を入れたとき、作成が終わってから移動し直すための控え
    var urlAtCreate: URL?
    /// ⌘⇧E で WebKit へ戻したタブ。ドメイン例外やプロファイル既定が Chromium でも、このタブは WebKit のまま
    var forceWebKit = false
    /// 重ね窓を使わない既定の経路で、別窓の Chromium へ渡したタブ(印だけ残す)
    var handedOffExternally = false
    /// タブに出すファビコン(ホスト単位で使い回す)
    var favicon: NSImage?
    var observations: [NSKeyValueObservation] = []
    /// 休眠判定(evaluateJavaScript)が既に飛んでいるかどうか。無いと、メモリ逼迫のたびに同じタブへ
    /// 判定を重ねて発行してしまい、判定が返ってこないタブ(読み込み中など)で要求が積み上がっていく。
    /// 実機でIdaten本体が4.9GBまで膨張してクラッシュした事故の原因と推測(2026-09-20)
    var hibernationCheckInFlight = false

    var isHibernated: Bool { webView == nil && url != nil && !isChromium }

    /// エンジンは色ドット(BrowserWindowController.rebuildTabBar)で示すのでここには含めない。
    /// 休眠だけは文字で残す("z" は他の絵文字よりフォント依存が少なく、幅が安定する)
    var displayTitle: String {
        let base = title.isEmpty ? (url?.host ?? "新しいタブ") : title
        return isHibernated ? "z " + base : base
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

/// engine は後から足した項目。古いセッションファイル(項目なし)は WebKit として読む
struct SessionTab: Codable { var url: String; var title: String; var engine: EngineKind? }
struct Session: Codable { var tabs: [SessionTab]; var selected: Int }
