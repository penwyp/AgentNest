public struct StorageOwnershipFilter: Sendable {
    public let scope: StorageOwnershipScope
    private let productHomeIDs: Set<PhysicalResourceIdentity>

    public init(scope: StorageOwnershipScope, snapshot: DeviceSnapshot) {
        self.scope = scope
        switch scope {
        case .product(let productID):
            productHomeIDs = Set(snapshot.homes.filter { $0.productID == productID }.map(\.id))
        case .all, .home:
            productHomeIDs = []
        }
    }

    public func includes(_ artifact: ArtifactRecord) -> Bool {
        switch scope {
        case .all:
            true
        case .product:
            artifact.homeIDs.contains { productHomeIDs.contains($0) }
        case .home(let homeID):
            artifact.homeIDs.contains(homeID)
        }
    }

    public func includes(_ unit: CleanupUnit) -> Bool {
        switch scope {
        case .all:
            true
        case .product(let productID):
            unit.productID == productID
        case .home(let homeID):
            unit.homeIdentity == homeID
        }
    }
}
