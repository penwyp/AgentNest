import Foundation

public enum LicenseServiceError: Error, Equatable {
    case invalidResponse
    case rejected(code: String)
}

public struct LicenseServiceClient: Sendable {
    public let baseURL: URL
    public let productID: String
    private let session: URLSession

    public init(
        baseURL: URL,
        productID: String = "com.agentnest.macos",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.productID = productID
        self.session = session
    }

    public func startTrial(machineIDHash: String) async throws -> EntitlementResponse {
        try await post(path: "v1/trials", body: MachineRequest(productId: productID, machineIdHash: machineIDHash))
    }

    public func activate(licenseKey: String, machineIDHash: String) async throws -> EntitlementResponse {
        try await post(path: "v1/activate", body: ActivationRequest(
            productId: productID,
            machineIdHash: machineIDHash,
            licenseKey: licenseKey
        ))
    }

    public func refresh(refreshToken: String, machineIDHash: String) async throws -> EntitlementResponse {
        try await post(path: "v1/refresh", body: RefreshRequest(
            productId: productID,
            machineIdHash: machineIDHash,
            refreshToken: refreshToken
        ))
    }

    public func deactivate(refreshToken: String, machineIDHash: String) async throws {
        let _: EmptyResponse = try await post(path: "v1/deactivate", body: RefreshRequest(
            productId: productID,
            machineIdHash: machineIDHash,
            refreshToken: refreshToken
        ), acceptsEmptyResponse: true)
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        acceptsEmptyResponse: Bool = false
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LicenseServiceError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let failure = try? JSONDecoder().decode(APIError.self, from: data)
            throw LicenseServiceError.rejected(code: failure?.code ?? "http_\(response.statusCode)")
        }
        if acceptsEmptyResponse && data.isEmpty, let empty = EmptyResponse() as? Response { return empty }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LicenseServiceError.invalidResponse
        }
        return decoded
    }
}

private struct MachineRequest: Encodable { let productId: String; let machineIdHash: String }
private struct ActivationRequest: Encodable { let productId: String; let machineIdHash: String; let licenseKey: String }
private struct RefreshRequest: Encodable { let productId: String; let machineIdHash: String; let refreshToken: String }
private struct APIError: Decodable { let code: String }
private struct EmptyResponse: Decodable { init() {} }
