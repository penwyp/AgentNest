import Foundation

/// 市场最新版本刷新触发规则（纯函数，可测试）：
/// - 只刷新缺失或超过 TTL 的产品；
/// - 失败退避期间不重复尝试；
/// - `force` 跳过缓存与退避限制，但调用方仍需保证单飞。
public struct MarketVersionRefreshPolicy: Sendable, Equatable {
    public let cacheTTL: TimeInterval
    public let retryAfter: TimeInterval

    public init(cacheTTL: TimeInterval = 30 * 60, retryAfter: TimeInterval = 2 * 60) {
        self.cacheTTL = cacheTTL
        self.retryAfter = retryAfter
    }

    public func staleProductIDs(
        allProductIDs: [String],
        fetchedAtByProduct: [String: Date],
        now: Date = Date()
    ) -> [String] {
        allProductIDs.filter { productID in
            guard let fetchedAt = fetchedAtByProduct[productID] else { return true }
            return now.timeIntervalSince(fetchedAt) >= cacheTTL
        }
    }

    public func shouldRefresh(
        force: Bool,
        staleProductIDs: [String],
        lastAttemptAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard force || !staleProductIDs.isEmpty else { return false }
        guard force || lastAttemptAt.map({ now.timeIntervalSince($0) >= retryAfter }) ?? true else {
            return false
        }
        return true
    }
}
