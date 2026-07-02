import SwiftUI

/// 配色对齐 cc-switch「Usage Trends」深色面板。
public enum Theme {
    // 五条数据线（图表用，对齐 UsageTrendChart.tsx）
    public static let hit      = Color(hex: 0xA855F7) // Cache Hit  紫  #a855f7
    public static let creation = Color(hex: 0xF97316) // Cache Creation 橙 #f97316
    public static let cost     = Color(hex: 0xF43F5E) // Cost 红(虚线) #f43f5e
    public static let input    = Color(hex: 0x3B82F6) // Input 蓝 #3b82f6
    public static let output   = Color(hex: 0x22C55E) // Output 绿 #22c55e
    // 卡片图标强调色（对齐 UsageHero MiniStat + tailwind.config 覆盖色）
    public static let amber     = Color(hex: 0xF59E0B) // Creation 图标 amber-500
    public static let emerald   = Color(hex: 0x10B981) // Hit 图标 + 命中率 + TOTAL COST(green-500 被覆盖成 #10b981)
    public static let appleBlue = Color(hex: 0x0A84FF) // Fresh Input / Activity 图标 blue-500(被覆盖)
    public static let accent    = Color(hex: 0x148AFF) // --primary(闪电)

    public static let muted     = Color(hex: 0x2C2C30) // --muted(≈药丸底 / 命中率轨道)

    // 主题变量（精确对齐 index.css .dark，用实心色而非白色透明叠加）
    public static let bg        = Color(hex: 0x1D1D20) // --background
    public static let card      = Color(hex: 0x27272B) // --card
    public static let textMain  = Color(hex: 0xFAFAFA) // --foreground
    public static let textDim   = Color(hex: 0xA1A1AA) // --muted-foreground
    public static let track     = Color(hex: 0x3A3A40) // --border
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
