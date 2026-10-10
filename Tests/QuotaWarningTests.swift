import XCTest

// 额度告警线对齐 cc-switch v4.0.6（0be33a84）：WARN_BELOW_PERCENT 10 → 20，
// 剩余**不到** 20% 告警；上游用例 `toneForLeft(20) == "normal"`，即剩余恰好 20%（用量 80%）不告警。
final class QuotaWarningTests: XCTestCase {
    /// 杀变异体：阈值仍是改前的 90 / 写成 75 之类的别的数。
    func testWarnsOncePastEightyPercentUsed() {
        XCTAssertTrue(QuotaWarning.isLow(usedPercent: 85))
        XCTAssertTrue(QuotaWarning.isLow(usedPercent: 100))
        XCTAssertFalse(QuotaWarning.isLow(usedPercent: 75))
        XCTAssertFalse(QuotaWarning.isLow(usedPercent: 0))
    }

    /// 杀变异体：边界写成 `>=`（剩余恰好 20% 也告警，与上游 toneForLeft(20) == normal 不一致）。
    func testExactlyTwentyPercentLeftIsStillNormal() {
        XCTAssertFalse(QuotaWarning.isLow(usedPercent: 80))
        XCTAssertTrue(QuotaWarning.isLow(usedPercent: 80.5))
    }
}
