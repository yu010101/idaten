import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// ページの内容から「Chrome拡張が要りそうか」を判定し、Chromiumエンジンへの切替を提案する。
///
/// 使うのはAppleの端末内モデル(Foundation Models framework)。macOS自体がSpotlight/Writing Tools等で
/// 既に読み込んでいる共有モデルを借りるだけなので、Karu専用にモデルを積む必要が無く、
/// 常駐メモリはほぼ増えない(自前でモデルファイルを同梱する方式とはここが決定的に違う)。
///
/// macOS 26未満・Apple Intelligence未有効・対象外ハードでは `isAvailable()` が false を返し、
/// 呼び出し側は機能ごと静かにスキップする(エラーにしない・普段の閲覧を止めない)。
enum AIEngineAdvisor {
    static func isAvailable() -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    /// pageText は document.body.innerText の抜粋。全文を送らない(速さと、送る情報を絞るため)
    static func suggestsChromiumEngine(pageText: String, url: String) async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else { return false }
        let instructions = """
        あなたはWebページの内容だけを見て、「このページはGoogle Chrome拡張機能の導入を前提にしている」
        「Safari/WebKit系ブラウザでは正しく動かないと利用者に伝えている」のどちらかに該当するかを判定します。
        該当すると判断したときだけ YES とだけ答え、それ以外は NO とだけ答えてください。前置きも理由も不要です。
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "URL: \(url)\n\nページの内容(抜粋):\n\(pageText)")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("YES")
        } catch {
            // 判定に失敗しても普段の閲覧は止めない。何もしないのが正しい既定値
            return false
        }
        #else
        return false
        #endif
    }
}
