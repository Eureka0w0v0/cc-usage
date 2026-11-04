import XCTest
import SwiftUI

// 趋势图离屏渲染：边界数据（空、单桶、命中率全空、全 0）不能崩，柱子与曲线要真的画到该画的位置。
@MainActor
final class TrendChartRenderTests: XCTestCase {
    private let size = CGSize(width: 300, height: 100)

    private func hourly(_ values: [Int64]) -> [TrendBucket] {
        values.enumerated().map { i, v in
            TrendBucket(startTs: 1_793_545_200 + Int64(i) * 3600, requestCount: v > 0 ? 1 : 0, input: v / 10,
                        output: v / 10, creation: v / 10, hit: v - 3 * (v / 10), cost: Double(v) / 1_000_000)
        }
    }

    private func render(_ chart: TrendChart) -> CGImage? {
        let renderer = ImageRenderer(content: chart.frame(width: size.width, height: size.height))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// sRGB 下 (x, y) 处像素的 RGBA（y 从上往下数）。
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]), Int(data[3]))
    }

    // 负责杀的变异体：空数组 / 单桶 / 全 nil 时下标越界、除零或构造倒置区间（0...-1）崩溃。
    func testEdgeCasesRenderWithoutCrashing() {
        let cases: [(String, [TrendBucket], TrendMetric)] = [
            ("empty", [], .tokens),
            ("single", hourly([5_000]), .tokens),
            ("all zero", hourly([0, 0, 0]), .cost),
            ("hit rate all nil", hourly([0, 0]), .hitRate),
            ("hit rate gaps", hourly([0, 900, 0, 1_200, 0]), .hitRate),
            ("spike", hourly(Array(repeating: 0, count: 14) + [123_456]), .requests),
        ]
        for (name, buckets, metric) in cases {
            for style in [TrendChartStyle.bar, .area] {
                for axes in [true, false] {
                    let image = render(TrendChart(buckets: buckets, metric: metric, style: style,
                                                  showAxes: axes, interactive: true))
                    XCTAssertNotNil(image, "\(name) \(style) axes=\(axes)")
                }
            }
        }
    }

    // 不带坐标轴时绘图区铺满：15 个小时只有最后一格有量，柱子在最后一格、贴着底边，前面的格子空着。
    // 负责杀的变异体：柱子画到第一格 / 0 值也画出颜色 / 颜色不是主窗口的 #38BDF8。
    func testSpikeBarIsDrawnInTheLastBand() throws {
        let image = try XCTUnwrap(render(TrendChart(buckets: hourly(Array(repeating: 0, count: 14) + [123_456]),
                                                    metric: .tokens, style: .bar, showAxes: false)))
        let band = size.width / 15
        let lastX = Int(size.width - band / 2), bottomY = Int(size.height) - 4
        let bar = pixel(image, x: lastX, y: bottomY)
        XCTAssertEqual(bar.a, 255, "最后一格应有柱子")
        XCTAssertEqual(bar.r, 0x38, accuracy: 6)
        XCTAssertEqual(bar.g, 0xBD, accuracy: 6)
        XCTAssertEqual(bar.b, 0xF8, accuracy: 6)
        XCTAssertEqual(pixel(image, x: Int(band / 2), y: bottomY).a, 0, "第一格是 0，不该有颜色")
    }
}
