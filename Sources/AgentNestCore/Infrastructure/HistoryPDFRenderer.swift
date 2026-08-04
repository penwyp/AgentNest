import CoreGraphics
import CoreText
import Foundation

public struct HistoryPDFRenderer: Sendable {
    public init() {}

    public func render(
        points: [HistoryPoint],
        generatedAt: Date = Date(),
        locale: Locale = .current
    ) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw HistoryStoreError.statementFailed("pdf_consumer")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw HistoryStoreError.statementFailed("pdf_context")
        }
        let chinese = locale.language.languageCode?.identifier == "zh"
        let rowsPerPage = 32
        let pageCount = max(1, Int(ceil(Double(points.count) / Double(rowsPerPage))))
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let averageCoverage = points.isEmpty ? 0 : points.reduce(0) { $0 + $1.coverage } / Double(points.count)

        for page in 0..<pageCount {
            context.beginPDFPage(nil)
            draw(chinese ? "AgentNest 历史报告" : "AgentNest History Report", x: 42, y: 798, size: 20, context: context)
            draw(
                chinese ? "生成：\(dateFormatter.string(from: generatedAt))" : "Generated: \(dateFormatter.string(from: generatedAt))",
                x: 42, y: 770, size: 9, context: context
            )
            let range: String
            if let first = points.first, let last = points.last {
                range = "\(dateFormatter.string(from: first.capturedAt)) — \(dateFormatter.string(from: last.capturedAt))"
            } else {
                range = chinese ? "无样本" : "No samples"
            }
            draw((chinese ? "范围：" : "Range: ") + range, x: 42, y: 754, size: 9, context: context)
            draw(
                String(format: chinese ? "平均覆盖率：%.1f%%；缺失值保持为空，不按 0 计算。" : "Average coverage: %.1f%%; missing values remain blank and are not treated as zero.", averageCoverage * 100),
                x: 42, y: 738, size: 9, context: context
            )
            draw(chinese ? "时间" : "Time", x: 42, y: 710, size: 8, context: context)
            draw("CPU", x: 172, y: 710, size: 8, context: context)
            draw(chinese ? "磁盘读/写" : "Disk R/W", x: 220, y: 710, size: 8, context: context)
            draw(chinese ? "网络收/发" : "Network R/S", x: 340, y: 710, size: 8, context: context)
            draw(chinese ? "覆盖" : "Coverage", x: 486, y: 710, size: 8, context: context)
            context.move(to: CGPoint(x: 42, y: 703))
            context.addLine(to: CGPoint(x: 553, y: 703))
            context.setStrokeColor(CGColor(gray: 0.7, alpha: 1))
            context.strokePath()

            let start = page * rowsPerPage
            let end = min(start + rowsPerPage, points.count)
            for (offset, point) in points[start..<end].enumerated() {
                let y = CGFloat(682 - offset * 20)
                draw(dateFormatter.string(from: point.capturedAt), x: 42, y: y, size: 7, context: context)
                draw(percent(point.cpuFraction), x: 172, y: y, size: 7, context: context)
                draw("\(rate(point.diskReadBytesPerSecond)) / \(rate(point.diskWriteBytesPerSecond))", x: 220, y: y, size: 7, context: context)
                draw("\(rate(point.networkReceiveBytesPerSecond)) / \(rate(point.networkSendBytesPerSecond))", x: 340, y: y, size: 7, context: context)
                draw(String(format: "%.0f%%", point.coverage * 100), x: 486, y: y, size: 7, context: context)
            }
            draw("\(page + 1) / \(pageCount)", x: 510, y: 28, size: 8, context: context)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    private func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
    }

    private func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000_000 { return String(format: "%.1fG", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(format: "%.0f", value)
    }
}
