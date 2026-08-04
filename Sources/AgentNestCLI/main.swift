import AgentNestCore
import Foundation

@main
struct AgentNestCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments.first {
            case "scan":
                try await scan(arguments: arguments)
            case "license-trial":
                try await license(arguments: arguments, activation: false)
            case "license-activate":
                try await license(arguments: arguments, activation: true)
            case "license-verify":
                try verifyReceipt(arguments: arguments)
            default:
                throw CLIError.usage
            }
        } catch {
            FileHandle.standardError.write(Data("agentnest-cli: \(error.localizedDescription)\n".utf8))
            exit(error is CLIError ? 64 : 1)
        }
    }

    private static func scan(arguments: [String]) async throws {
        guard let rootPath = value(for: "--root", in: arguments) else { throw CLIError.usage }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let customLocations = values(for: "--custom", in: arguments).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        var environment: [String: String] = [:]
        if let codexHome = value(for: "--codex-home", in: arguments) {
            environment["CODEX_HOME"] = codexHome
        }
        let catalog = try AgentDefinitionCatalog.bundled()
        let snapshot = try await ScanUseCase(catalog: catalog).execute(
            request: ScanRequest(root: root, customLocations: customLocations, environment: environment)
        )
        try writeJSON(snapshot)
    }

    private static func license(arguments: [String], activation: Bool) async throws {
        guard let server = value(for: "--server", in: arguments).flatMap(URL.init(string:)),
              let machineID = value(for: "--machine-id", in: arguments),
              let encodedKey = value(for: "--public-key", in: arguments),
              let publicKey = decodeBase64URL(encodedKey) else { throw CLIError.usage }
        let machineIDHash = MachineIdentityProvider.hash(rawMachineIdentifier: machineID)
        let client = LicenseServiceClient(baseURL: server)
        let response: EntitlementResponse
        if activation {
            guard let licenseKey = value(for: "--license-key", in: arguments) else { throw CLIError.usage }
            response = try await client.activate(licenseKey: licenseKey, machineIDHash: machineIDHash)
        } else {
            response = try await client.startTrial(machineIDHash: machineIDHash)
        }
        let verifier = try ReceiptVerifier(publicKeyData: publicKey)
        let entitlement = try verifier.verify(response.receipt, machineIDHash: machineIDHash)
        try writeJSON(LicenseCommandOutput(entitlement: entitlement, receipt: response.receipt, refreshToken: response.refreshToken))
    }

    private static func verifyReceipt(arguments: [String]) throws {
        guard let path = value(for: "--receipt", in: arguments),
              let machineID = value(for: "--machine-id", in: arguments),
              let encodedKey = value(for: "--public-key", in: arguments),
              let publicKey = decodeBase64URL(encodedKey) else { throw CLIError.usage }
        let receipt = try JSONDecoder().decode(SignedEntitlementReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let payload = try ReceiptVerifier(publicKeyData: publicKey).verify(
            receipt,
            machineIDHash: MachineIdentityProvider.hash(rawMachineIdentifier: machineID)
        )
        try writeJSON(payload)
    }

    private static func writeJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func decodeBase64URL(_ input: String) -> Data? {
        var value = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: value)
    }

    private static func value(for option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func values(for option: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            arguments[index] == option && index + 1 < arguments.count ? arguments[index + 1] : nil
        }
    }
}

private enum CLIError: LocalizedError {
    case usage

    var errorDescription: String? {
        """
        usage:
          agentnest-cli scan --root PATH [--codex-home PATH] [--custom PATH]
          agentnest-cli license-trial --server URL --machine-id ID --public-key BASE64URL
          agentnest-cli license-activate --server URL --machine-id ID --public-key BASE64URL --license-key KEY
          agentnest-cli license-verify --receipt PATH --machine-id ID --public-key BASE64URL
        """
    }
}

private struct LicenseCommandOutput: Encodable {
    let entitlement: EntitlementPayload
    let receipt: SignedEntitlementReceipt
    let refreshToken: String?
}
