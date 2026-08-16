import Foundation

public enum MarketplaceVersionServiceError: Error, Equatable, Sendable {
    case badResponse
    case httpStatus(Int)
    case responseTooLarge
    case invalidPayload
    case missingVersion
    case invalidVersion
}

/// Homebrew 官方 JSON API 的最新版本读取器。只读取固定的 formula/cask JSON 文件，
/// 不使用 shell、不执行公式，单请求响应限制 512 KB 且超时 10 秒。
public struct MarketplaceVersionService: Sendable {
    public let baseURL: URL
    public let npmRegistryURL: URL
    public let appStoreLookupURL: URL
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://formulae.brew.sh/api")!,
        npmRegistryURL: URL = URL(string: "https://registry.npmjs.org")!,
        appStoreLookupURL: URL = URL(string: "https://itunes.apple.com/lookup")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.npmRegistryURL = npmRegistryURL
        self.appStoreLookupURL = appStoreLookupURL
        self.session = session
    }

    public func latestVersion(websiteUpdateURL: String) async throws -> String {
        guard let url = URL(string: websiteUpdateURL) else {
            throw MarketplaceVersionServiceError.badResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketplaceVersionServiceError.badResponse
        }
        guard http.statusCode == 200 else {
            throw MarketplaceVersionServiceError.httpStatus(http.statusCode)
        }
        guard data.count <= 512 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawVersion = object["version"] as? String
                ?? (object["version"] as? NSNumber)?.stringValue
                ?? object["productVersion"] as? String
                ?? (object["productVersion"] as? NSNumber)?.stringValue else {
            throw MarketplaceVersionServiceError.missingVersion
        }
        let version = AgentVersion.normalizedVersion(rawVersion)
        guard !version.isEmpty, version.count <= 128 else {
            throw MarketplaceVersionServiceError.invalidVersion
        }
        return version
    }

    public func latestVersion(appStoreID: String) async throws -> String {
        var components = URLComponents(url: appStoreLookupURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: appStoreID)]
        guard let url = components?.url else { throw MarketplaceVersionServiceError.badResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketplaceVersionServiceError.badResponse
        }
        guard http.statusCode == 200 else {
            throw MarketplaceVersionServiceError.httpStatus(http.statusCode)
        }
        guard data.count <= 512 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let first = results.first,
              let rawVersion = first["version"] as? String
                ?? (first["version"] as? NSNumber)?.stringValue else {
            throw MarketplaceVersionServiceError.missingVersion
        }
        let version = AgentVersion.normalizedVersion(rawVersion)
        guard !version.isEmpty, version.count <= 128 else {
            throw MarketplaceVersionServiceError.invalidVersion
        }
        return version
    }

    public func latestVersion(for method: AgentInstallMethod) async throws -> String {
        let url: URL
        if method.kind == .npm {
            let packagePath = method.formula.replacingOccurrences(of: "/", with: "%2F")
            let registryBase = npmRegistryURL.absoluteString.hasSuffix("/")
                ? npmRegistryURL.absoluteString
                : npmRegistryURL.absoluteString + "/"
            url = URL(string: registryBase + packagePath)!
        } else if method.kind == .website {
            guard let updateURL = method.websiteUpdateURL,
                  let resolved = URL(string: updateURL.replacingOccurrences(
                      of: "{platform}",
                      with: "\(method.formula.lowercased())-darwin-arm64"
                  )) else {
                throw MarketplaceVersionServiceError.badResponse
            }
            url = resolved
        } else {
            let folder = method.kind == .brew ? "formula" : "cask"
            url = baseURL
                .appending(path: folder)
                .appending(path: "\(method.formula).json")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketplaceVersionServiceError.badResponse
        }
        guard http.statusCode == 200 else {
            throw MarketplaceVersionServiceError.httpStatus(http.statusCode)
        }
        guard data.count <= 512 * 1_024 else {
            throw MarketplaceVersionServiceError.responseTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MarketplaceVersionServiceError.invalidPayload
        }

        let rawVersion: String?
        if method.kind == .npm {
            rawVersion = (object["dist-tags"] as? [String: Any])?["latest"] as? String
                ?? ((object["dist-tags"] as? [String: Any])?["latest"] as? NSNumber)?.stringValue
        } else if method.kind == .brew {
            rawVersion = (object["versions"] as? [String: Any])?["stable"] as? String
                ?? ((object["versions"] as? [String: Any])?["stable"] as? NSNumber)?.stringValue
        } else if method.kind == .website {
            rawVersion = object["version"] as? String
                ?? (object["version"] as? NSNumber)?.stringValue
                ?? object["productVersion"] as? String
                ?? (object["productVersion"] as? NSNumber)?.stringValue
        } else {
            rawVersion = object["version"] as? String
                ?? (object["version"] as? NSNumber)?.stringValue
        }
        guard let rawVersion else {
            throw MarketplaceVersionServiceError.missingVersion
        }
        let version = AgentVersion.normalizedVersion(rawVersion)
        guard !version.isEmpty, version.count <= 128 else {
            throw MarketplaceVersionServiceError.invalidVersion
        }
        return version
    }
}
