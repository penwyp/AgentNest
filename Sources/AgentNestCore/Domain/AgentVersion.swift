import Foundation

public enum AgentVersionComparison: Equatable, Sendable {
    case older
    case equal
    case newer
    case unknown
}

/// 语义化版本比较的精简实现，专门用于“已安装版本 vs 市场最新版本”。
/// 支持常见的 `v` 前缀、数字点分段、`-` 预发布段；无法解析为数字核心时返回 `.unknown`。
public enum AgentVersion {
    /// 版本号只保留第一个逗号之前的内容；例如 `1.2.3, 1.2.4` → `1.2.3`。
    public static func normalizedVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comma = trimmed.firstIndex(of: ",") else { return trimmed }
        return trimmed[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func compare(_ candidate: String, to reference: String) -> AgentVersionComparison {
        guard let lhs = parse(normalizedVersion(candidate)), let rhs = parse(normalizedVersion(reference)) else {
            return .unknown
        }
        let core = compareNumeric(lhs.core, rhs.core)
        if core != 0 {
            return core < 0 ? .older : .newer
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return .equal
        case (nil, .some):
            // 正式版高于预发布版。
            return .newer
        case (.some, nil):
            return .older
        case let (.some(lhsPre), .some(rhsPre)):
            let result = compareNumeric(lhsPre, rhsPre)
            if result == 0 { return .equal }
            return result < 0 ? .older : .newer
        }
    }

    public static func isUpdate(latest: String, installed: String) -> Bool {
        // 官网版本常带完整构建号（5.3.13.35912340），而 App bundle 只写 5.3.13；
        // 两者属于同一发布，不应被判定为“可更新”。
        guard !isSameRelease(latest, installed) else { return false }
        return compare(latest, to: installed) == .newer
    }

    /// 判断两个版本是否属于同一发布。用于官网安装器：
    /// App bundle 通常只写 `5.3.13`，而官网更新接口写 `5.3.13.35912340`。
    public static func isSameRelease(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsVersion = parse(normalizedVersion(lhs)),
              let rhsVersion = parse(normalizedVersion(rhs)) else { return false }
        let count = min(lhsVersion.core.count, rhsVersion.core.count)
        guard count >= 3 else { return false }
        for index in 0..<count where lhsVersion.core[index] != rhsVersion.core[index] {
            return false
        }
        return true
    }

    private struct ParsedVersion {
        let core: [Int]
        let prerelease: [Int]?
    }

    private static func parse(_ raw: String) -> ParsedVersion? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix("v") { value.removeFirst() }
        let prereleaseSeparator = value.firstIndex(where: { $0 == "-" || $0 == "+" })
        let coreText: String
        let prereleaseText: String?
        if let separator = prereleaseSeparator {
            coreText = String(value[..<separator])
            let suffix = String(value[value.index(after: separator)...])
            prereleaseText = value[separator] == "-" && !suffix.isEmpty ? suffix : nil
        } else {
            coreText = value
            prereleaseText = nil
        }

        guard let core = parseNumericSegments(coreText, allowEmpty: false), !core.isEmpty else {
            return nil
        }
        let prerelease: [Int]?
        if let prereleaseText {
            guard let parsed = parseNumericSegments(prereleaseText, allowEmpty: true), !parsed.isEmpty else {
                return nil
            }
            prerelease = parsed
        } else {
            prerelease = nil
        }
        return ParsedVersion(core: core, prerelease: prerelease)
    }

    private static func parseNumericSegments(_ text: String, allowEmpty: Bool) -> [Int]? {
        var segments: [Int] = []
        for component in text.split(separator: ".", omittingEmptySubsequences: false) {
            if component.isEmpty {
                guard allowEmpty else { return nil }
                segments.append(0)
                continue
            }
            guard let number = leadingInteger(in: String(component)) else { return nil }
            segments.append(number)
        }
        return segments
    }

    private static func leadingInteger(in text: String) -> Int? {
        var digits = ""
        for character in text {
            guard character.isASCII, character.isNumber else { break }
            digits.append(character)
        }
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        return value
    }

    private static func compareNumeric(_ lhs: [Int], _ rhs: [Int]) -> Int {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let lhsValue = index < lhs.count ? lhs[index] : 0
            let rhsValue = index < rhs.count ? rhs[index] : 0
            if lhsValue < rhsValue { return -1 }
            if lhsValue > rhsValue { return 1 }
        }
        return 0
    }
}
