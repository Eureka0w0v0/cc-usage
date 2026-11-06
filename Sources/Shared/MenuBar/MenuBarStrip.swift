import CoreGraphics

// MARK: - 菜单栏条带窗口快照分析（纯函数，便于单测）
//
// 给 App 侧的宽度 governor 用：从 CGWindowList 的一批记录里判断
//   ① 整条菜单栏是不是根本不在屏幕上（App 全屏 / 菜单栏自动隐藏）；
//   ② 我们的状态项是不是被更高层的不透明窗口盖住（锁屏罩 / 屏保）；
//   ③ 刘海屏上、刘海右侧区域里最左状态项左边还剩多少空位。
// 坐标一律用 CG 坐标（原点主屏左上、y 向下）。
enum MenuBarStrip {
    /// 一条 CGWindowList 记录里我们关心的字段。
    /// 注意 macOS 26 上所有 app 的状态项窗口在 CGWindowList 里一律归属 Control Center（托管渲染），
    /// 按 pid 分不出「我们的」和「别人的」，所以这里不记 pid、按条带上的状态项总数判断。
    struct Record {
        let layer: Int
        let alpha: Double
        let bounds: CGRect
    }

    struct Scan: Equatable {
        /// 本屏条带上在屏幕上的状态项个数（含我们自己）。0 = 整条菜单栏都不在（全屏 / 自动隐藏）；
        /// 我们不可见而这里 > 0 = 菜单栏在、唯独我们不在 = 真被挤。
        let itemsOnScreen: Int
        /// 我们窗口的中心被更高层的不透明窗口盖住（锁屏罩 / 屏保 …）。
        let covered: Bool
        /// 刘海右侧区域里、最左状态项左边的空位（≥ 0）。无刘海屏 = nil：左界是前台 app 菜单末端，量不到。
        let freeLeft: CGFloat?
    }

    /// kCGStatusWindowLevel：所有 app 的状态项窗口都在这一层。
    static let statusLayer = 25
    /// 刘海右侧第一个状态项并不贴着 auxiliaryTopRightArea.minX，macOS 留了一段空白
    /// （macOS 26.6 / 16" 实测第一项起点 1168~1180，即 1138 + 30~42）。取下限 30：估少了只是
    /// 少涨几 pt，估多了会把贴着刘海的可见项漏算、空位算成整个区域（踩过）。
    static let notchGap: CGFloat = 30

    /// - strip: 目标屏幕菜单栏条带（minY = 该屏顶端的 CG y，x 范围 = 该屏）
    /// - boundary: 刘海右侧可放状态项的起点（含 notchGap）；无刘海传 nil
    /// - myCenter: 我们状态项窗口的中心点（CG 坐标）
    static func scan(_ records: [Record], strip: CGRect,
                     boundary: CGFloat?, myCenter: CGPoint) -> Scan {
        var items = 0
        var covered = false
        var leftmost = strip.maxX
        for r in records {
            if r.layer == statusLayer {
                // 只认本屏条带上的状态项：顶边对齐条带顶、左边在本屏 x 范围内
                guard abs(r.bounds.minY - strip.minY) < 2,
                      r.bounds.minX >= strip.minX, r.bounds.minX < strip.maxX else { continue }
                items += 1
                // 伸进刘海右侧区域的才是可见项（起点可能略早于估算的边界）；停在刘海左侧的不算
                if let b = boundary, r.bounds.maxX > b { leftmost = min(leftmost, r.bounds.minX) }
            } else if r.layer > statusLayer, r.alpha > 0, r.bounds.contains(myCenter) {
                covered = true
            }
        }
        return Scan(itemsOnScreen: items, covered: covered, freeLeft: boundary.map { max(0, leftmost - $0) })
    }
}
