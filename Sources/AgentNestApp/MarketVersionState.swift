import Foundation

enum MarketAgentVersionPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case unavailable
}

struct MarketAgentVersionState: Equatable, Sendable {
    var phase: MarketAgentVersionPhase = .idle
    var latestVersion: String?
    var fetchedAt: Date?
}

struct MarketVersionCacheEntry: Codable, Equatable, Sendable {
    var latestVersion: String
    var fetchedAt: Date
}
