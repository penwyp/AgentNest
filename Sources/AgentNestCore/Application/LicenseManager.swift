import Foundation

public actor LicenseManager {
    public static let refreshTokenAccount = "refresh-token"
    public static let licenseKeyAccount = "license-key"

    private let verifier: ReceiptVerifier
    private let service: LicenseServiceClient
    private let receiptStore: ReceiptStore
    private let credentialStore: any CredentialStore
    private let machineIDHash: String
    private var currentPayload: EntitlementPayload?
    private var refreshTask: Task<LicenseState, Error>?

    public init(
        verifier: ReceiptVerifier,
        service: LicenseServiceClient,
        receiptStore: ReceiptStore = ReceiptStore(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        machineIDHash: String
    ) {
        self.verifier = verifier
        self.service = service
        self.receiptStore = receiptStore
        self.credentialStore = credentialStore
        self.machineIDHash = machineIDHash
    }

    public func loadLocalState(now: Date = Date()) -> LicenseState {
        do {
            guard let receipt = try receiptStore.load() else { return .missing }
            let payload = try verifier.verify(receipt, machineIDHash: machineIDHash, now: now)
            currentPayload = payload
            return payload.refreshAfter <= now ? .needsRefresh(payload) : .valid(payload)
        } catch let error as ReceiptVerificationError {
            currentPayload = nil
            if error == .offlineWindowExpired || error == .subscriptionExpired { return .expired }
            return .invalid(error)
        } catch {
            currentPayload = nil
            return .invalid(.malformedEnvelope)
        }
    }

    public func startTrial(now: Date = Date()) async -> LicenseState {
        do {
            let response = try await service.startTrial(machineIDHash: machineIDHash)
            return try accept(response: response, now: now, saveLicenseKey: nil)
        } catch let error as ReceiptVerificationError {
            return .invalid(error)
        } catch let error as LicenseServiceError {
            return state(for: error, now: now, invalidatesCurrentReceipt: false)
        } catch {
            return .serviceUnavailable(lastValid: validCurrentPayload(at: now))
        }
    }

    public func activate(licenseKey: String, now: Date = Date()) async -> LicenseState {
        do {
            let response = try await service.activate(licenseKey: licenseKey, machineIDHash: machineIDHash)
            return try accept(response: response, now: now, saveLicenseKey: licenseKey)
        } catch let error as ReceiptVerificationError {
            return .invalid(error)
        } catch let error as LicenseServiceError {
            return state(for: error, now: now, invalidatesCurrentReceipt: false)
        } catch {
            return .serviceUnavailable(lastValid: validCurrentPayload(at: now))
        }
    }

    public func refresh(now: Date = Date()) async -> LicenseState {
        if let refreshTask {
            return (try? await refreshTask.value) ?? .serviceUnavailable(lastValid: validCurrentPayload(at: now))
        }
        let task = Task<LicenseState, Error> {
            if currentPayload?.plan == "trial" {
                let response = try await service.startTrial(machineIDHash: machineIDHash)
                return try accept(response: response, now: now, saveLicenseKey: nil)
            }
            guard let token = try credentialStore.read(account: Self.refreshTokenAccount) else {
                return .missing
            }
            do {
                let response = try await service.refresh(refreshToken: token, machineIDHash: machineIDHash)
                return try accept(response: response, now: now, saveLicenseKey: nil)
            } catch let error as ReceiptVerificationError {
                return .invalid(error)
            } catch let error as LicenseServiceError {
                return state(for: error, now: now, invalidatesCurrentReceipt: true)
            } catch {
                return .serviceUnavailable(lastValid: validCurrentPayload(at: now))
            }
        }
        refreshTask = task
        let result = (try? await task.value) ?? .serviceUnavailable(lastValid: validCurrentPayload(at: now))
        refreshTask = nil
        return result
    }

    public func deactivate() async throws {
        guard let token = try credentialStore.read(account: Self.refreshTokenAccount) else {
            throw LicenseServiceError.rejected(code: "refresh_missing")
        }
        try await service.deactivate(refreshToken: token, machineIDHash: machineIDHash)
        try receiptStore.delete()
        try credentialStore.delete(account: Self.refreshTokenAccount)
        try credentialStore.delete(account: Self.licenseKeyAccount)
        currentPayload = nil
    }

    public func clearLocalCredentials() throws {
        try receiptStore.delete()
        try credentialStore.delete(account: Self.refreshTokenAccount)
        try credentialStore.delete(account: Self.licenseKeyAccount)
        currentPayload = nil
    }

    private func accept(
        response: EntitlementResponse,
        now: Date,
        saveLicenseKey: String?
    ) throws -> LicenseState {
        let payload = try verifier.verify(
            response.receipt,
            machineIDHash: machineIDHash,
            now: now,
            replacing: currentPayload
        )
        var updates: [(account: String, previous: String?)] = []
        if response.refreshToken != nil {
            updates.append((Self.refreshTokenAccount, try credentialStore.read(account: Self.refreshTokenAccount)))
        }
        if saveLicenseKey != nil {
            updates.append((Self.licenseKeyAccount, try credentialStore.read(account: Self.licenseKeyAccount)))
        }
        do {
            if let token = response.refreshToken {
                try credentialStore.save(token, account: Self.refreshTokenAccount)
            }
            if let saveLicenseKey {
                try credentialStore.save(saveLicenseKey, account: Self.licenseKeyAccount)
            }
            try receiptStore.save(response.receipt)
        } catch {
            for update in updates.reversed() {
                if let previous = update.previous {
                    try? credentialStore.save(previous, account: update.account)
                } else {
                    try? credentialStore.delete(account: update.account)
                }
            }
            throw error
        }
        currentPayload = payload
        return .valid(payload)
    }

    private func validCurrentPayload(at now: Date) -> EntitlementPayload? {
        guard let currentPayload, now <= currentPayload.offlineUntil else { return nil }
        return currentPayload
    }

    private func state(
        for error: LicenseServiceError,
        now: Date,
        invalidatesCurrentReceipt: Bool
    ) -> LicenseState {
        switch error {
        case .invalidResponse:
            return .serviceUnavailable(lastValid: validCurrentPayload(at: now))
        case .rejected(let code):
            if invalidatesCurrentReceipt {
                try? receiptStore.delete()
                try? credentialStore.delete(account: Self.refreshTokenAccount)
                currentPayload = nil
            }
            if code == "license_expired" { return .expired }
            return .rejected(code: code)
        }
    }
}
