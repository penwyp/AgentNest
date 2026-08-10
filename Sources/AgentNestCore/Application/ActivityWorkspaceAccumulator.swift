import Foundation

public struct ActivityWorkspaceAccumulator: Sendable {
    private let retention: TimeInterval
    private var points: [ActivityTrendPoint] = []
    private var current: ActivitySnapshot?

    public init(retention: TimeInterval = 3_600) {
        precondition(retention > 0)
        self.retention = retention
    }

    public mutating func record(_ snapshot: ActivitySnapshot) -> ActivityWorkspaceSnapshot {
        if let current, snapshot.capturedAt <= current.capturedAt {
            return workspace(current: current)
        }

        current = snapshot
        points.append(ActivityTrendPoint(snapshot: snapshot))
        let cutoff = snapshot.capturedAt.addingTimeInterval(-retention)
        if let firstRetainedIndex = points.firstIndex(where: { $0.capturedAt >= cutoff }), firstRetainedIndex > 0 {
            points.removeFirst(firstRetainedIndex)
        }
        return workspace(current: snapshot)
    }

    public mutating func reset() {
        points.removeAll(keepingCapacity: true)
        current = nil
    }

    private func workspace(current: ActivitySnapshot) -> ActivityWorkspaceSnapshot {
        ActivityWorkspaceSnapshot(
            current: current,
            trend: points
        )
    }
}
