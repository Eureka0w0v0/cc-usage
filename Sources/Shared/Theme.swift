import SwiftUI

/// 配色对齐 cc-switch「Usage Trends」深色面板。
public enum Theme {
    // 用量分项配色（菜单栏统计卡、Widget 分项条用；取自 v3 UsageTrendChart.tsx 的五条线）
    public static let hit      = Color(hex: 0xA855F7) // Cache Hit  紫  #a855f7
    public static let creation = Color(hex: 0xF97316) // Cache Creation 橙 #f97316
    public static let input    = Color(hex: 0x3B82F6) // Input 蓝 #3b82f6
    public static let output   = Color(hex: 0x22C55E) // Output 绿 #22c55e
    public static let accent    = Color(hex: 0x148AFF) // --primary(闪电)

    // 趋势图（对齐主窗口 v4 index.css 的 .dark 设计 token）
    public static let chartUsage  = Color(hex: 0x38BDF8) // --chart-usage（= --chart-1）
    public static let chartGrid   = Color(hex: 0x2C2C31) // --chart-grid
    public static let chartAxis   = Color(hex: 0x9A9AA2) // --text-3：坐标轴文字、面积图悬停竖线
    public static let chartCursor = Color(hex: 0x26262A) // --bg-subtle：柱形图悬停时整格的底色
    public static let tooltipBg   = Color(hex: 0x2E2E33) // --bg-card（bg-surface）
    public static let tooltipText = Color(hex: 0xE4E4E7) // --text-1
    public static let tooltipDim  = Color(hex: 0xABABB3) // --text-2

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
