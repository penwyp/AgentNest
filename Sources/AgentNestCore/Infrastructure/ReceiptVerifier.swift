import CryptoKit
import Foundation

public struct ReceiptVerifier: Sendable {
    public let provider: String
    public let productID: String
    public let applicationVersion: String
    private let publicKey: Curve25519.Signing.PublicKey

    public init(
        publicKeyData: Data,
        provider: String = "agentnest-local",
        productID: String = "com.agentnest.macos",
        applicationVersion: String = "0.1.0"
    ) throws {
        self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        self.provider = provider
        self.productID = productID
        self.applicationVersion = applicationVersion
    }

    public func verify(
        _ envelope: SignedEntitlementReceipt,
        machineIDHash: String,
        now: Date = Date(),
        replacing current: EntitlementPayload? = nil
    ) throws -> EntitlementPayload {
        guard let payloadData = Data(base64URLString: envelope.payload),
              let signatureData = Data(base64URLString: envelope.signature) else {
            throw ReceiptVerificationError.malformedEnvelope
        }
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw ReceiptVerificationError.invalidSignature
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = RFC3339.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid RFC3339 timestamp")
            }
            return date
        }
        guard let payload = try? decoder.decode(EntitlementPayload.self, from: payloadData) else {
            throw ReceiptVerificationError.malformedEnvelope
        }
        guard payload.schemaVersion == 1 else { throw ReceiptVerificationError.unsupportedSchema }
        guard payload.provider == provider else { throw ReceiptVerificationError.providerMismatch }
        guard payload.productId == productID else { throw ReceiptVerificationError.productMismatch }
        guard payload.machineIdHash == machineIDHash else { throw ReceiptVerificationError.deviceMismatch }
        guard payload.features.allSatisfy({ feature in LicenseFeature.allCases.contains { $0.rawValue == feature } }) else {
            throw ReceiptVerificationError.unsupportedFeature
        }
        guard payload.issuedAt <= now.addingTimeInterval(5 * 60) else { throw ReceiptVerificationError.issuedInFuture }
        guard now <= payload.offlineUntil else { throw ReceiptVerificationError.offlineWindowExpired }
        if let expiresAt = payload.subscriptionExpiresAt, now > expiresAt {
            throw ReceiptVerificationError.subscriptionExpired
        }
        if let minimum = payload.minAppVersion,
           applicationVersion.compare(minimum, options: .numeric) == .orderedAscending {
            throw ReceiptVerificationError.appVersionUnsupported
        }
        if let current {
            guard payload.issuedAt > current.issuedAt ||
                    (payload.issuedAt == current.issuedAt && payload.receiptId == current.receiptId) else {
                throw ReceiptVerificationError.replayedReceipt
            }
        }
        return payload
    }
}

private enum RFC3339 {
    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

extension Data {
    init?(base64URLString: String) {
        var value = base64URLString.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value.append(String(repeating: "=", count: 4 - remainder)) }
        self.init(base64Encoded: value)
    }
}
