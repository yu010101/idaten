import AppKit

extension NSColor {
    /// "#RRGGBB" からの生成。プロファイルの識別色(Profile.colorHex)専用
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                 blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Karuの配色。設計DB(hub.db knowledge_base, category=design)の原則2つを適用:
///   1. primitive → semantic の2階層(id 16401/16388)。個々のUI部品は semantic 名だけを参照し、
///      実際の色(primitive)を後から差し替えても部品側は直さなくて済む
///   2. light/dark は「新しいhexを足す」のではなく semantic の参照先を差し替えるだけにする(id 16391)
/// ダークネイビーの基調色(#0A1834系)はAIBoard・POSplusで既に使っているRadineerのブランド色に合わせた(id 16201)。
/// プロファイルごとの識別色(Profile.colorHex)は、この上に乗る「アクセント」として別枠で扱う
enum Theme {
    // ---- primitive(生の色。ここだけ触ればパレット全体が変わる) ----
    private enum Primitive {
        static let navyDeep = NSColor(srgbRed: 0.039, green: 0.094, blue: 0.204, alpha: 1)   // #0A1834
        static let navyMid = NSColor(srgbRed: 0.071, green: 0.141, blue: 0.267, alpha: 1)     // #122444 前後
        static let navyLine = NSColor(srgbRed: 0.15, green: 0.22, blue: 0.34, alpha: 1)
        static let paper = NSColor(srgbRed: 0.98, green: 0.98, blue: 0.985, alpha: 1)
        static let paperLine = NSColor(srgbRed: 0.85, green: 0.85, blue: 0.87, alpha: 1)
        static let ink = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)     // ダーク面の主文字
        static let inkDim = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.74, alpha: 1)  // ダーク面の副文字
    }

    /// dynamicProvider で環境(ライト/ダーク)ごとに参照先を切り替える。呼び出し側は Theme.background 等の名前だけ見る
    private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    // ---- semantic(部品側が実際に参照するもの) ----
    static let windowBackground = adaptive(dark: Primitive.navyDeep, light: Primitive.paper)
    static let toolbarBackground = adaptive(dark: Primitive.navyMid, light: Primitive.paper)
    static let hairline = adaptive(dark: Primitive.navyLine, light: Primitive.paperLine)
    static let textPrimary = adaptive(dark: Primitive.ink, light: NSColor.labelColor)
    static let textSecondary = adaptive(dark: Primitive.inkDim, light: NSColor.secondaryLabelColor)
    static let tabSelectedFill = adaptive(dark: NSColor.white.withAlphaComponent(0.10),
                                          light: NSColor.controlAccentColor.withAlphaComponent(0.14))

    /// エンジンの種類を色ではなく形(丸の有無・色)で示す。"ビール3杯理論"(id 20564)の通り、
    /// 酔っていても・急いでいても一目でわかることを優先し、文字ラベルより先に見える位置に置く
    enum EngineDot {
        static let webkit = NSColor.tertiaryLabelColor.withAlphaComponent(0.5)   // 既定・目立たせない
        static let chromium = NSColor.systemOrange   // 「本線から降りている」ことを警告色寄りで示す
    }
}
