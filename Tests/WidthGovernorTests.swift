import XCTest

/// 菜单栏宽度状态机。真机上全屏、锁屏、刘海挤出都走这里，历史返工点（d04680e、d95f620、234f2ab、f5e5332），
/// 每条用例对应一次踩过的坑或一条分支。坐标按 16" 刘海屏（空位来自 MenuBarStrip）和普通屏（量不到空位）造。
final class WidthGovernorTests: XCTestCase {
    private var g = WidthGovernor()
    private var measured = 0

    private let natural: CGFloat = 400
    private let window: CGFloat = 416

    private func scan(items: Int = 5, covered: Bool = false, free: CGFloat? = nil) -> MenuBarStrip.Scan {
        MenuBarStrip.Scan(itemsOnScreen: items, covered: covered, freeLeft: free)
    }

    @discardableResult
    private func hidden(_ s: MenuBarStrip.Scan?, natural: CGFloat? = nil) -> [WidthGovernor.Change] {
        g.tick(natural: natural ?? self.natural, windowWidth: g.cap.map { $0 + 4 } ?? window, .hidden(s))
    }

    @discardableResult
    private func visible(natural: CGFloat? = nil, notch: Bool = false, free: CGFloat? = nil) -> [WidthGovernor.Change] {
        g.tick(natural: natural ?? self.natural, windowWidth: g.cap.map { $0 + 4 } ?? window,
               .visible(hasNotch: { notch }, measureFree: {
                   self.measured += 1
                   return free
               }))
    }

    /// 先拍一下让 lastNatural 对上，免得第一拍被当成「内容结构变了」。
    private func settle() { visible() }

    /// 两拍被挤到 cap，停在钉住态。
    private func squeeze(free: CGFloat) {
        hidden(scan(free: free))
        hidden(scan(free: free))
        XCTAssertEqual(g.width, .pinned(cap: free - WidthGovernor.fitMargin))
    }

    // MARK: - 全宽

    func testStartsFullAndStaysFullWhileVisible() {
        settle()
        XCTAssertEqual(g.width, .full)
        XCTAssertEqual(visible(), [])
        XCTAssertEqual(measured, 0, "全宽时不量空位，CGWindowList 不便宜")
    }

    // MARK: - 全屏 / 自动隐藏 / 锁屏：不可见但不是被挤，宽度一根手指都不动（v1.9.3）

    /// App 全屏：整条菜单栏都不在，条带上没有状态项。旧版把这当成被挤，每 2s 砍 48pt 砍到 80pt。
    func testFullscreenNeverShrinks() {
        settle()
        for _ in 0..<10 { hidden(scan(items: 0)) }
        XCTAssertEqual(g.width, .full)
    }

    func testCoveredByLockScreenWindowNeverShrinks() {
        settle()
        for _ in 0..<10 { hidden(scan(covered: true)) }
        XCTAssertEqual(g.width, .full)
    }

    func testScanUnavailableNeverShrinks() {
        settle()
        for _ in 0..<10 { hidden(nil) }
        XCTAssertEqual(g.width, .full)
    }

    /// 锁屏 / 屏保 / 息屏 / 睡眠：系统通知维护的遮蔽原因非空时，即使 CGWindowList 看着像被挤也不动。
    func testConcealedByNotificationNeverShrinks() {
        settle()
        XCTAssertTrue(g.setConcealed(["lock"]))
        for _ in 0..<10 { hidden(scan(free: 200)) }
        XCTAssertEqual(g.width, .full)
    }

    func testConcealTickResetsHiddenCount() {
        settle()
        hidden(scan(free: 200))
        XCTAssertEqual(g.hiddenTicks, 1)
        hidden(scan(items: 0))
        XCTAssertEqual(g.hiddenTicks, 0, "遮蔽这一拍打断了连续计数")
        hidden(scan(free: 200))
        XCTAssertEqual(g.width, .full, "只连续一拍，不算被挤")
    }

    /// 某个「结束」通知漏掉也不至于让 governor 永久失灵：看得见就绝不是遮蔽中。
    func testVisibleClearsLeftoverConcealReasons() {
        settle()
        g.setConcealed(["saver"])
        XCTAssertEqual(visible(), [.concealCleared])
        XCTAssertEqual(g.concealReasons, [])
    }

    func testSetConcealedReportsWhetherAnythingChanged() {
        XCTAssertTrue(g.setConcealed(["lock"]))
        XCTAssertFalse(g.setConcealed(["lock"]))
        XCTAssertTrue(g.setConcealed([]))
    }

    // MARK: - 被挤：连续 2 拍才算，滤面板开合毛刺

    func testOneHiddenTickIsNotSqueezed() {
        settle()
        hidden(scan(free: 200))
        XCTAssertEqual(g.width, .full)
        visible()
        hidden(scan(free: 200))
        XCTAssertEqual(g.width, .full, "中间看得见，计数清零")
    }

    /// 刘海屏：按实测空位一步压到刚好放下。
    func testNotchSqueezeGoesStraightToMeasuredFit() {
        settle()
        hidden(scan(free: 200))
        XCTAssertEqual(hidden(scan(free: 200)),
                       [.squeezed(from: window, to: 184, free: 200, items: 5)])
        XCTAssertEqual(g.width, .pinned(cap: 184))
        XCTAssertEqual(g.hiddenTicks, 0, "收缩后重新计数，给渲染生效留时间")
    }

    /// 普通屏量不到空位：现状是直接落到下限（空位按 0 算，比现在窄，走不到步进分支）。f5e5332 的说明写的是
    /// 「普通屏 48pt 步进」，代码从那时起就是这样，搬家不改行为；要改成真步进时这条用例跟着改。
    func testPlainScreenSqueezeDropsToMinCap() {
        settle()
        hidden(scan())
        hidden(scan())
        XCTAssertEqual(g.width, .pinned(cap: WidthGovernor.minCap))
    }

    /// 量出来不比现在窄（布局还在路上）：退回步进，不能原地不动。
    func testMeasuredWiderThanCurrentFallsBackToStep() {
        settle()
        hidden(scan(free: 900))
        hidden(scan(free: 900))
        XCTAssertEqual(g.width, .pinned(cap: window - 48))
    }

    func testSqueezeBottomsOutAtMinCap() {
        settle()
        hidden(scan(free: 0))
        hidden(scan(free: 0))
        XCTAssertEqual(g.width, .pinned(cap: WidthGovernor.minCap))
        hidden(scan(free: 0))
        XCTAssertEqual(hidden(scan(free: 0)), [], "已在下限，只能等空间回来")
        XCTAssertEqual(g.width, .pinned(cap: WidthGovernor.minCap))
    }

    // MARK: - 钉住：刚被挤过、空间没变，别去撞

    func testPinnedOnPlainScreenWaitsForCeilingToRise() {
        settle()
        hidden(scan())
        hidden(scan())
        measured = 0
        for _ in 0..<100 { visible(free: 500) }
        XCTAssertEqual(measured, 0, "普通屏量不到，钉住时绝不探")
        XCTAssertEqual(g.width, .pinned(cap: WidthGovernor.minCap))
    }

    /// 刘海屏每 30 拍无痛重量一次：量不会隐身，挤我们的东西走了就长回来。
    func testPinnedOnNotchRemeasuresEveryThirtyTicks() {
        settle()
        squeeze(free: 200)
        measured = 0
        for _ in 0..<(WidthGovernor.pinnedRemeasureTicks - 1) { visible(notch: true, free: 0) }
        XCTAssertEqual(measured, 0)
        visible(notch: true, free: 0)
        XCTAssertEqual(measured, 1)
        XCTAssertEqual(g.width, .pinned(cap: 184), "没空位：继续钉着")
        for _ in 0..<WidthGovernor.pinnedRemeasureTicks { visible(notch: true, free: 0) }
        XCTAssertEqual(measured, 2, "量完重新数 30 拍")
    }

    func testPinnedOnNotchGrowsWhenRoomAppears() {
        settle()
        squeeze(free: 200)
        for _ in 0..<(WidthGovernor.pinnedRemeasureTicks - 1) { visible(notch: true, free: 100) }
        XCTAssertEqual(visible(notch: true, free: 100), [.grew(from: 184, to: 268, free: 100)])
        XCTAssertEqual(g.width, .pinned(cap: 268), "涨到刚好就钉住，防边界震荡")
    }

    // MARK: - 夺回空间：切前台 app / 内容结构变了 / 屏幕变了

    /// 切前台 app 只抬天花板、不动 cap：清掉 cap 会让 label 回全宽、随即被挤掉，隐身两秒多（234f2ab）。
    func testRaiseCeilingKeepsCapAndMeasuresOnNextTick() {
        settle()
        squeeze(free: 200)
        g.raiseCeiling()
        XCTAssertEqual(g.width, .reclaiming(cap: 184))
        XCTAssertEqual(g.cap, 184)
        measured = 0
        XCTAssertEqual(visible(notch: true, free: 0), [])
        XCTAssertEqual(measured, 1)
        XCTAssertEqual(g.width, .pinned(cap: 184), "试过没空位，钉回去")
    }

    func testRaiseCeilingFromFullStaysFull() {
        settle()
        g.raiseCeiling()
        XCTAssertEqual(g.width, .full)
    }

    func testReclaimingGrowsOnlyAsFarAsFits() {
        settle()
        squeeze(free: 200)
        g.raiseCeiling()
        XCTAssertEqual(visible(notch: true, free: 50), [.grew(from: 184, to: 218, free: 50)])
        XCTAssertEqual(g.width, .pinned(cap: 218))
    }

    func testReclaimingReleasesWhenEverythingFits() {
        settle()
        squeeze(free: 200)
        g.raiseCeiling()
        XCTAssertEqual(visible(notch: true, free: 300), [.released(.roomFits(free: 300, natural: natural))])
        XCTAssertEqual(g.width, .full)
    }

    /// 普通屏量不到：直接回全宽，放不下会被精确压回。
    func testReclaimingOnPlainScreenProbesFullWidth() {
        settle()
        hidden(scan())
        hidden(scan())
        g.raiseCeiling()
        XCTAssertEqual(visible(free: nil), [.released(.probeFullWidth)])
        XCTAssertEqual(g.width, .full)
    }

    func testGrowthUnderOnePointIsNotWorthIt() {
        settle()
        squeeze(free: 200)
        g.raiseCeiling()
        XCTAssertEqual(visible(notch: true, free: WidthGovernor.fitMargin + 1), [])
        XCTAssertEqual(g.width, .pinned(cap: 184))
    }

    // MARK: - 内容变化

    /// 内容变短到放得下：立刻解除，不用等空间回来（「内容变短仍被旧上限截断」）。
    func testContentThatFitsReleasesTheCap() {
        settle()
        squeeze(free: 200)
        XCTAssertEqual(visible(natural: 190), [.released(.contentFits(cap: 184))])
        XCTAssertEqual(g.width, .full)
    }

    /// 宽度跳变 >30pt 算内容结构变了：允许重新扩张。不到 30 的是数字变长，别动。
    func testNaturalJumpRaisesCeilingButSmallChangeDoesNot() {
        settle()
        squeeze(free: 200)
        measured = 0
        visible(natural: natural + 30, notch: true, free: 0)
        XCTAssertEqual(measured, 0, "恰好 30 不算突变")
        visible(natural: natural + 61, notch: true, free: 0)
        XCTAssertEqual(measured, 1, "超过 30 抬起天花板，这一拍就量")
    }

    func testHiddenTickAlsoNoticesNaturalJump() {
        settle()
        squeeze(free: 200)
        hidden(scan(items: 0), natural: natural + 100)
        XCTAssertEqual(g.width, .reclaiming(cap: 184))
    }

    /// 勾选变化、屏幕变化：解除上限，按新内容全宽重估。
    func testResetDropsTheCap() {
        settle()
        squeeze(free: 200)
        g.reset()
        XCTAssertEqual(g.width, .full)
        XCTAssertNil(g.cap)
    }

    /// 钉住后再被挤：cap 接着往下压，上一段的计数不清零（只在夺回或解除时清）。
    func testSecondSqueezeKeepsPinnedCount() {
        settle()
        squeeze(free: 200)
        for _ in 0..<10 { visible(notch: true, free: 0) }
        hidden(scan(free: 100))
        hidden(scan(free: 100))
        XCTAssertEqual(g.width, .pinned(cap: 84))
        measured = 0
        for _ in 0..<(WidthGovernor.pinnedRemeasureTicks - 11) { visible(notch: true, free: 0) }
        XCTAssertEqual(measured, 0)
        visible(notch: true, free: 0)
        XCTAssertEqual(measured, 1)
    }
}
