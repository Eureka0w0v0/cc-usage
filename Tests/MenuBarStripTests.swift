import XCTest

/// MenuBarStrip.scan 的纯函数用例：坐标按 16" 刘海屏（2056×1329，刘海右侧区域 1138 起）实测值造。
final class MenuBarStripTests: XCTestCase {
    private let strip = CGRect(x: 0, y: 0, width: 2056, height: 39)
    private let boundary: CGFloat = 1138 + MenuBarStrip.notchGap
    private let center = CGPoint(x: 1800, y: 19)

    private func item(x: CGFloat, w: CGFloat, y: CGFloat = 0) -> MenuBarStrip.Record {
        .init(layer: MenuBarStrip.statusLayer, alpha: 1, bounds: CGRect(x: x, y: y, width: w, height: 39))
    }

    /// App 全屏：条带上只有菜单栏底（L24）与全屏 app 的透明覆盖层（L26, alpha 0），没有任何状态项。
    func testFullscreenHasNoStatusItemsAndIsNotCovered() {
        let records: [MenuBarStrip.Record] = [
            .init(layer: 24, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 2056, height: 39)),
            .init(layer: 26, alpha: 0, bounds: CGRect(x: 0, y: 0, width: 2056, height: 39)),
            .init(layer: 0,  alpha: 1, bounds: CGRect(x: 0, y: 39, width: 2056, height: 1290)),
        ]
        let s = MenuBarStrip.scan(records, strip: strip, boundary: boundary, myCenter: center)
        XCTAssertEqual(s.itemsOnScreen, 0)
        XCTAssertFalse(s.covered)
    }

    /// 真被挤：别的状态项都在、我们不在；空位 = 最左可见项 − 刘海右侧起点。
    func testSqueezedMeasuresFreeSpaceLeftOfLeftmostItem() {
        let records = [item(x: 1696, w: 120), item(x: 1816, w: 240), item(x: 500, w: 60, y: 1329)]
        let s = MenuBarStrip.scan(records, strip: strip, boundary: boundary, myCenter: center)
        XCTAssertEqual(s.itemsOnScreen, 2)           // 另一块屏（y=1329）的不算
        XCTAssertEqual(s.freeLeft, 1696 - boundary)
    }

    /// 我们可见且是最左项：空位从我们自己算起；停在刘海左侧的项（maxX 未伸进右侧区域）不参与空位计算。
    func testVisibleSelfCountsTowardLeftmostAndParkedItemsIgnored() {
        let records = [item(x: 1180, w: 516), item(x: 1696, w: 360), item(x: 700, w: 130)]
        let s = MenuBarStrip.scan(records, strip: strip, boundary: boundary, myCenter: center)
        XCTAssertEqual(s.itemsOnScreen, 3)
        XCTAssertEqual(s.freeLeft, 1180 - boundary)  // 12pt：贴着刘海空白，没得涨
    }

    /// 起点略早于估算边界（实测 1168 < 1138+30）的可见项也要算进去，空位钳到 0 而不是把整块区域当空位。
    func testItemStartingBeforeEstimatedBoundaryStillCounts() {
        let records = [item(x: 1168, w: 716), item(x: 1884, w: 42)]
        let s = MenuBarStrip.scan(records, strip: strip, boundary: boundary, myCenter: center)
        XCTAssertEqual(s.freeLeft, 0)
    }

    /// 锁屏罩 / 屏保：更高层、不透明、盖住我们中心 → covered；透明覆盖层不算。
    func testOpaqueHigherWindowOverCenterIsCovered() {
        let shield = MenuBarStrip.Record(layer: 2000, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 2056, height: 1329))
        let s = MenuBarStrip.scan([item(x: 1696, w: 360), shield], strip: strip, boundary: boundary, myCenter: center)
        XCTAssertTrue(s.covered)
        XCTAssertEqual(s.itemsOnScreen, 1)
    }

    /// 无刘海屏：左界是前台 app 菜单末端，量不到 → freeLeft 为 nil，其余照常。
    func testNoNotchGivesNoFreeSpaceMeasurement() {
        let s = MenuBarStrip.scan([item(x: 1500, w: 100)], strip: strip, boundary: nil, myCenter: center)
        XCTAssertNil(s.freeLeft)
        XCTAssertEqual(s.itemsOnScreen, 1)
    }
}
