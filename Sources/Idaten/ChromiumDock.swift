import AppKit
import Darwin

/// 「1ブラウザで完結」第1段(2026-09-22、本人決定: 重ね窓→フォークの二段)。
///
/// Helium(実物のChromium)を Idaten の子プロセスとして起動し、CDP で操作する。
/// - Chromium側のタブも Idaten のタブバーに並び、選ぶと Helium の窓を Idaten の内容領域へぴったり重ねる。
///   Idaten の内容領域は透明の穴にしてあるので、Idaten が前面でも真下の Helium が見え、クリックも届く。
/// - 外部アプリの窓を自分の窓の子にする公開APIは無い(Codex調査、docs/one-browser/codex_answer.md)。
///   なので「位置を合わせて重ねる」までしかできず、Helium の中をクリックするとメニューバーは Helium になる。
///   この継ぎ目は第2段(Heliumフォーク)で消す前提。
///
/// CDP の通り道は `--remote-debugging-pipe`(fd 3/4)。`--remote-debugging-port` だと、同じ Mac の
/// 他のプロセスからもログイン済みのブラウザ(Claude・1Password入り)を操作できてしまうので使わない。
final class CDPPipe {
    let pid: pid_t
    private let writeFD: Int32
    private let readFD: Int32
    private var nextId = 0
    private var callbacks: [Int: ([String: Any]?, String?) -> Void] = [:]
    private let writeQueue = DispatchQueue(label: "idaten.cdp.write")
    /// (method, params, sessionId)。メインスレッドで呼ぶ
    var onEvent: ((String, [String: Any], String?) -> Void)?
    /// パイプが閉じた(Heliumが終了した・既に同じプロファイルで動いていて転送して終わった)。メインスレッドで呼ぶ
    var onClose: (() -> Void)?

    private init(pid: pid_t, writeFD: Int32, readFD: Int32) {
        self.pid = pid; self.writeFD = writeFD; self.readFD = readFD
    }

    /// Chromium は fd 3 から命令を読み、fd 4 へ応答を書く(区切りは NUL)
    static func launch(exe: URL, args: [String], logFile: URL) -> CDPPipe? {
        var toChrome: [Int32] = [0, 0], fromChrome: [Int32] = [0, 0]
        guard pipe(&toChrome) == 0 else { return nil }
        guard pipe(&fromChrome) == 0 else { close(toChrome[0]); close(toChrome[1]); return nil }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, toChrome[0], 3)
        posix_spawn_file_actions_adddup2(&fa, fromChrome[1], 4)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, logFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // 上で dup2 した 0〜4 以外の fd を子へ漏らさない(Idaten が開いている SQLite 等を Helium に渡さない)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([exe.path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe.path, &fa, &attr, argv, environ)
        close(toChrome[0]); close(fromChrome[1])
        guard rc == 0 else { close(toChrome[1]); close(fromChrome[0]); return nil }
        // Helium が先に終わった後に書くと SIGPIPE で Idaten ごと落ちる。fd 単位で止めて EPIPE として受ける(Codexレビュー #4)
        _ = fcntl(toChrome[1], F_SETNOSIGPIPE, 1)
        let p = CDPPipe(pid: pid, writeFD: toChrome[1], readFD: fromChrome[0])
        p.startReading()
        p.reapOnExit()
        return p
    }

    private func startReading() {
        let fd = readFD
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buffer.append(chunk, count: n)
                while let z = buffer.firstIndex(of: 0) {
                    let msg = buffer[buffer.startIndex..<z]
                    buffer.removeSubrange(buffer.startIndex...z)
                    guard let obj = try? JSONSerialization.jsonObject(with: msg) as? [String: Any] else { continue }
                    DispatchQueue.main.async { self?.dispatch(obj) }
                }
            }
            close(fd)
            DispatchQueue.main.async { self?.closed() }
        }
    }

    /// 終了した子を回収する(しないとゾンビが残る。Codexレビュー #6)
    private var exitSource: DispatchSourceProcess?
    private func reapOnExit() {
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [pid] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            src.cancel()
        }
        src.resume()
        exitSource = src
    }

    private var isClosed = false
    private func closed() {
        guard !isClosed else { return }
        isClosed = true
        // 書き込み側の fd も閉じる。書き込みキューの上で閉じ、書いている最中の fd を横から閉じないようにする
        let fd = writeFD
        writeQueue.async { close(fd) }
        let pending = callbacks; callbacks = [:]
        pending.values.forEach { $0(nil, "パイプが閉じました") }
        onClose?()
    }

    private func dispatch(_ obj: [String: Any]) {
        if let id = obj["id"] as? Int, let cb = callbacks.removeValue(forKey: id) {
            let err = (obj["error"] as? [String: Any])?["message"] as? String
            cb(obj["result"] as? [String: Any], err)
        } else if let method = obj["method"] as? String {
            onEvent?(method, obj["params"] as? [String: Any] ?? [:], obj["sessionId"] as? String)
        }
    }

    /// メインスレッドから呼ぶ
    func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil,
              _ done: (([String: Any]?, String?) -> Void)? = nil) {
        guard !isClosed else { done?(nil, "パイプが閉じています"); return }
        nextId += 1
        var msg: [String: Any] = ["id": nextId, "method": method, "params": params]
        if let session { msg["sessionId"] = session }
        callbacks[nextId] = done ?? { _, err in if let err { NSLog("Idaten CDP %@: %@", method, err) } }
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0)
        let fd = writeFD
        writeQueue.async {
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return }   // EPIPE 等。切断は読み取り側が検知して closed() する
                    off += n
                }
            }
        }
    }

    /// アプリ終了の直前用: 書き込みが終わるまで待つ。非同期のままだと書く前にプロセスが終わり、
    /// Helium に Browser.close が届かない(実測 2026-09-22: chromium.log に "Could not write into pipe")
    /// Helium が固まってパイプが満杯のときに終了処理ごと止まらないよう、待つのは最大1秒(Codexレビュー #5)
    func flush(timeout: TimeInterval = 1) {
        let sem = DispatchSemaphore(value: 0)
        writeQueue.async { sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
    }
}

protocol ChromiumDockDelegate: AnyObject {
    func dockTargetCreated(_ targetId: String, url: URL?, title: String)
    func dockTargetChanged(_ targetId: String, url: URL?, title: String)
    func dockTargetDestroyed(_ targetId: String)
    func dockDisconnected()
}

/// Helium 1プロセス = Idaten の1プロファイル。窓の位置合わせとタブの対応付けを受け持つ
final class ChromiumDock {
    weak var delegate: ChromiumDockDelegate?
    private let engine: ChromiumProcessEngine
    private let profileDir: URL
    private var cdp: CDPPipe?
    private var sessions: [String: String] = [:]   // targetId -> sessionId(flatten)
    private var known: Set<String> = []
    /// Idaten が頼んだ createTarget の応答待ちの数と、その間に届いた targetCreated。
    /// 応答の targetId で要求元と対応付け、応答が全部そろってから残りを「Helium 側で開かれたタブ」として渡す。
    /// 先着順で割り当てると、応答待ちの間に拡張が開いたタブを取り違える(Codexレビュー #1)
    private var inFlight = 0
    private var stash: [(id: String, url: URL?, title: String)] = []

    var isRunning: Bool { cdp != nil }
    var pid: pid_t? { cdp?.pid }

    init(engine: ChromiumProcessEngine, profileDir: URL) {
        self.engine = engine
        self.profileDir = profileDir
    }

    /// 最初に Chromium タブが要るときだけ起動する(拡張の要らない普段使いでは Helium を立ち上げない = 軽さを保つ)
    func ensureStarted() -> Result<Void, ChromiumProcessEngine.EngineError> {
        if cdp != nil { return .success(()) }
        guard let (_, exe) = engine.resolve() else { return .failure(.notInstalled(engine.candidates.map(\.name))) }
        try? FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        // --no-startup-window: 起動時の窓(と前回セッションの自動復元)を出さない。タブは Idaten の
        // セッションが持ち主なので、Helium 側で勝手に復元されると二重になる
        let args = ["--user-data-dir=\(profileDir.path)", "--remote-debugging-pipe", "--no-startup-window"]
            + engine.flags()
        let log = profileDir.deletingLastPathComponent().appendingPathComponent("chromium.log")
        guard let p = CDPPipe.launch(exe: exe, args: args, logFile: log) else {
            return .failure(.launchFailed("posix_spawn に失敗しました"))
        }
        p.onEvent = { [weak self] m, params, s in self?.handle(m, params, session: s) }
        p.onClose = { [weak self] in
            guard let self else { return }
            self.cdp = nil; self.sessions = [:]; self.known = []; self.inFlight = 0; self.stash = []
            self.delegate?.dockDisconnected()
        }
        cdp = p
        p.send("Target.setDiscoverTargets", ["discover": true])
        return .success(())
    }

    /// 拡張のサイドパネル・ポップアップ等はタブではないのでタブバーに出さない
    private func isUserTab(_ info: [String: Any]) -> Bool {
        guard info["type"] as? String == "page" else { return false }
        let url = info["url"] as? String ?? ""
        if url.hasPrefix("devtools://") { return false }
        if url.hasPrefix("chrome-extension://") {
            let path = URL(string: url)?.path.lowercased() ?? ""
            if ["side", "panel", "popup", "offscreen"].contains(where: path.contains) { return false }
        }
        return true
    }

    private func handle(_ method: String, _ params: [String: Any], session: String?) {
        guard let info = params["targetInfo"] as? [String: Any] ?? (method == "Target.targetDestroyed" ? [:] : nil) else { return }
        switch method {
        case "Target.targetCreated":
            guard isUserTab(info), let id = info["targetId"] as? String, !known.contains(id) else { return }
            known.insert(id)
            let entry = (id: id, url: URL(string: info["url"] as? String ?? ""), title: info["title"] as? String ?? "")
            if inFlight > 0 { stash.append(entry) } else { delegate?.dockTargetCreated(entry.id, url: entry.url, title: entry.title) }
        case "Target.targetInfoChanged":
            guard let id = info["targetId"] as? String, known.contains(id) else { return }
            // 保留中の外部タブは、渡す前に最新の URL・題名へ差し替えておく(再レビュー: 古い情報で登録される)
            if let i = stash.firstIndex(where: { $0.id == id }) {
                stash[i] = (id: id, url: URL(string: info["url"] as? String ?? ""), title: info["title"] as? String ?? "")
                return
            }
            delegate?.dockTargetChanged(id, url: URL(string: info["url"] as? String ?? ""), title: info["title"] as? String ?? "")
        case "Target.targetDestroyed":
            guard let id = params["targetId"] as? String, known.remove(id) != nil else { return }
            sessions[id] = nil
            stash.removeAll { $0.id == id }
            delegate?.dockTargetDestroyed(id)
        default: break
        }
    }

    func createTarget(_ url: URL, completion: @escaping (String?) -> Void) {
        guard let cdp else { completion(nil); return }
        inFlight += 1
        cdp.send("Target.createTarget", ["url": url.absoluteString]) { [weak self] r, _ in
            let id = r?["targetId"] as? String
            guard let self else { completion(id); return }
            self.inFlight = max(0, self.inFlight - 1)
            if let id {
                self.known.insert(id)   // イベントがまだなら、後から来ても外部タブ扱いしない
                self.stash.removeAll { $0.id == id }
            }
            completion(id)
            if self.inFlight == 0 {
                let rest = self.stash; self.stash = []
                for e in rest { self.delegate?.dockTargetCreated(e.id, url: e.url, title: e.title) }
            }
        }
    }

    func closeTarget(_ id: String) { cdp?.send("Target.closeTarget", ["targetId": id]) }

    /// 窓を rect(CDPの座標系: 主画面の左上原点・ポイント)へ動かしてから、そのタブを前面へ。
    /// activateTarget は Helium を前面のアプリにする — キー入力をそのままページへ届けるため意図してそうしている
    /// `stillWanted` は前面化の直前に確かめる。位置合わせの往復中に WebKit タブへ切り替えられていたら
    /// 前面に出さない(出すと WebKit を選んでいるのに Helium が覆う。Codexレビュー #8)
    func show(_ id: String, at rect: CGRect, stillWanted: @escaping () -> Bool) {
        guard let cdp else { return }
        place(id, at: rect) { if stillWanted() { cdp.send("Target.activateTarget", ["targetId": id]) } }
    }

    /// Idaten の窓を動かした・大きさを変えたときの追従。前面には出さない
    func place(_ id: String, at rect: CGRect, then: (() -> Void)? = nil) {
        guard let cdp else { return }
        cdp.send("Browser.getWindowForTarget", ["targetId": id]) { r, _ in
            guard let wid = r?["windowId"] as? Int else { then?(); return }
            // 最小化中の窓は、いったん normal に戻してからでないと位置を受け付けない
            cdp.send("Browser.setWindowBounds", ["windowId": wid, "bounds": ["windowState": "normal"]]) { _, _ in
                cdp.send("Browser.setWindowBounds", ["windowId": wid, "bounds": [
                    "left": Int(rect.minX.rounded()), "top": Int(rect.minY.rounded()),
                    "width": Int(rect.width.rounded()), "height": Int(rect.height.rounded())]]) { _, _ in then?() }
            }
        }
    }

    /// 自己検査用: そのタブの窓の現在位置(CDPの座標系)
    func windowBounds(_ id: String, _ done: @escaping ([String: Any]?) -> Void) {
        guard let cdp else { done(nil); return }
        cdp.send("Browser.getWindowForTarget", ["targetId": id]) { r, _ in done(r?["bounds"] as? [String: Any]) }
    }

    func minimize(_ id: String) {
        guard let cdp else { return }
        cdp.send("Browser.getWindowForTarget", ["targetId": id]) { r, _ in
            guard let wid = r?["windowId"] as? Int else { return }
            cdp.send("Browser.setWindowBounds", ["windowId": wid, "bounds": ["windowState": "minimized"]])
        }
    }

    /// ページ単位の命令(Page.navigate 等)は、そのタブへ attach したセッション経由で送る
    private func withSession(_ id: String, _ body: @escaping (String) -> Void) {
        guard let cdp else { return }
        if let s = sessions[id] { body(s); return }
        cdp.send("Target.attachToTarget", ["targetId": id, "flatten": true]) { [weak self] r, _ in
            guard let s = r?["sessionId"] as? String else { return }
            self?.sessions[id] = s
            body(s)
        }
    }

    func navigate(_ id: String, to url: URL) {
        withSession(id) { [weak self] s in self?.cdp?.send("Page.navigate", ["url": url.absoluteString], session: s) }
    }
    func evaluate(_ id: String, _ js: String, _ done: @escaping (Any?) -> Void) {
        withSession(id) { [weak self] s in
            guard let cdp = self?.cdp else { done(nil); return }
            cdp.send("Runtime.evaluate", ["expression": js, "returnByValue": true], session: s) { r, _ in
                done((r?["result"] as? [String: Any])?["value"])
            }
        }
    }
    func reload(_ id: String) {
        withSession(id) { [weak self] s in self?.cdp?.send("Page.reload", [:], session: s) }
    }
    func history(_ id: String, _ delta: Int) {
        withSession(id) { [weak self] s in
            self?.cdp?.send("Runtime.evaluate", ["expression": "history.go(\(delta))"], session: s)
        }
    }

    /// Idaten の窓を閉じる/終了するとき。Helium を正常終了させる(次回は Idaten のセッションから開き直す)
    func shutdown() {
        guard let p = cdp else { return }
        p.send("Browser.close")
        p.flush()
        // 読み取りスレッドは弱参照なので、ここで手放すと EOF 後の後始末(書き込み fd を閉じる)が走らない。
        // 切断を見届けるまで保持する(再レビュー #6: プロファイル窓を1つだけ閉じた場合に fd が残る)
        let key = ObjectIdentifier(p)
        Self.retiring[key] = p
        p.onEvent = nil
        p.onClose = { Self.retiring[key] = nil }
        cdp = nil
        sessions = [:]; known = []; inFlight = 0; stash = []
    }
    private static var retiring: [ObjectIdentifier: CDPPipe] = [:]
}
