import Foundation

public struct SignedEntitlementReceipt: Codable, Equatable, Sendable {
    public let payload: String
    public let signature: String

    public init(payload: String, signature: String) {
        self.payload = payload
        self.signature = signature
    }
}

public struct EntitlementPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let provider: String
    public let licenseId: String
    public let machineIdHash: String
    public let productId: String
    public let plan: String
    public let features: [String]
    public let issuedAt: Date
    public let refreshAfter: Date
    public let offlineUntil: Date
    public let subscriptionExpiresAt: Date?
    public let minAppVersion: String?
    public let receiptId: String

    public init(
        schemaVersion: Int,
        provider: String,
        licenseId: String,
        machineIdHash: String,
        productId: String,
        plan: String,
        features: [String],
        issuedAt: Date,
        refreshAfter: Date,
        offlineUntil: Date,
        subscriptionExpiresAt: Date?,
        minAppVersion: String?,
        receiptId: String
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.licenseId = licenseId
        self.machineIdHash = machineIdHash
        self.productId = productId
        self.plan = plan
        self.features = features
        self.issuedAt = issuedAt
        self.refreshAfter = refreshAfter
        self.offlineUntil = offlineUntil
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.minAppVersion = minAppVersion
        self.receiptId = receiptId
    }
}

public struct EntitlementResponse: Codable, Equatable, Sendable {
    public let receipt: SignedEntitlementReceipt
    public let refreshToken: String?
}

public enum LicenseState: Equatable, Sendable {
    case missing
    case valid(EntitlementPayload)
    case needsRefresh(EntitlementPayload)
    case expired
    case invalid(ReceiptVerificationError)
    case rejected(code: String)
    case serviceUnavailable(lastValid: EntitlementPayload?)
}

public enum ReceiptVerificationError: String, Error, Codable, Sendable {
    case malformedEnvelope
    case invalidSignature
    case unsupportedSchema
    case providerMismatch
    case productMismatch
    case deviceMismatch
    case unsupportedFeature
    case issuedInFuture
    case offlineWindowExpired
    case subscriptionExpired
    case appVersionUnsupported
    case replayedReceipt
}

public enum LicenseFeature: String, CaseIterable, Codable, Sendable {
    case scan
    case overview
    case skillWrite = "skill.write"
    case patch
    case cleanup
    case trace
    case history
    case export
}
