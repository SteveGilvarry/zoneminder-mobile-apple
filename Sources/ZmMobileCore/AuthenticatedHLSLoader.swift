import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

public final class AuthenticatedHLSLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let accessTokenProvider: @Sendable () async throws -> String
    private let session: URLSession

    public init(
        session: URLSession = .shared,
        accessTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.session = session
        self.accessTokenProvider = accessTokenProvider
    }

    public func assetURL(for realURL: URL) -> URL {
        var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false)!
        components.scheme = realURL.scheme == "https" ? "zmauths" : "zmauth"
        return components.url!
    }

    public func realURL(for customURL: URL) -> URL? {
        var components = URLComponents(url: customURL, resolvingAgainstBaseURL: false)
        switch customURL.scheme {
        case "zmauth":
            components?.scheme = "http"
        case "zmauths":
            components?.scheme = "https"
        default:
            return customURL
        }
        return components?.url
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let realURL = realURL(for: url) else {
            loadingRequest.finishLoading(with: ZmHLSLoaderError.invalidURL)
            return false
        }

        let provider = accessTokenProvider
        let urlSession = session
        let loadingRequestBox = LoadingRequestBox(loadingRequest)

        Task {
            do {
                let token = try await provider()
                var request = URLRequest(url: realURL)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await urlSession.data(for: request)
                let loadingRequest = loadingRequestBox.request
                if let contentInformation = loadingRequest.contentInformationRequest,
                   let http = response as? HTTPURLResponse {
                    contentInformation.contentType = http.value(forHTTPHeaderField: "Content-Type")
                    contentInformation.contentLength = Int64(data.count)
                    contentInformation.isByteRangeAccessSupported = true
                }
                loadingRequest.dataRequest?.respond(with: data)
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }
}

public enum ZmHLSLoaderError: Error {
    case invalidURL
}

private final class LoadingRequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest

    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }
}
#endif
