import Foundation
import OSLog

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

private let hlsLog = Logger(subsystem: "com.zoneminder.mobile", category: "hls")

/// Serves authenticated HLS to `AVPlayer` via a custom (`zmauth`/`zmauths`) scheme.
///
/// AVPlayer's HLS engine will accept *playlist* bytes from a resource loader, but for media
/// (`init.mp4`, segments) it refuses returned data and demands a redirect to a real URL
/// (`CoreMediaErrorDomain -12881 "custom url not redirect"`). So:
///   - **Playlists** (`.m3u8`): fetch with a Bearer header and return the body, rewriting every
///     child URI to the custom scheme so child playlists/segments come back through this loader.
///   - **Media** (segments / init): redirect AVPlayer to the real `http(s)` URL with `?token=`
///     appended, so AVPlayer fetches and decodes it itself (the backend accepts query-param auth
///     for media URLs, which can't carry an Authorization header anyway).
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

    public func assetURL(for realURL: URL) -> URL { zmAssetURL(for: realURL) }
    public func realURL(for customURL: URL) -> URL? { zmRealURL(for: customURL) }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let realURL = zmRealURL(for: url) else {
            loadingRequest.finishLoading(with: ZmHLSLoaderError.invalidURL)
            return false
        }

        let provider = accessTokenProvider
        let urlSession = session
        let box = LoadingRequestBox(loadingRequest)
        let isPlaylist = realURL.pathExtension.lowercased() == "m3u8"

        Task {
            do {
                let token = try await provider()
                let lr = box.request
                if isPlaylist {
                    let body = try await zmFetchPlaylist(realURL: realURL, token: token, session: urlSession)
                    if let info = lr.contentInformationRequest {
                        info.contentType = "public.m3u-playlist"
                        info.contentLength = Int64(body.count)
                        info.isByteRangeAccessSupported = false
                    }
                    if let dataRequest = lr.dataRequest {
                        let offset = Int(dataRequest.currentOffset)
                        if offset < body.count {
                            let end = dataRequest.requestsAllDataToEndOfResource
                                ? body.count
                                : min(offset + dataRequest.requestedLength, body.count)
                            dataRequest.respond(with: body.subdata(in: offset..<end))
                        }
                    }
                    lr.finishLoading()
                    hlsLog.debug("playlist \(realURL.path, privacy: .public) bytes=\(body.count)")
                } else {
                    // Media: redirect to the real URL with the token in the query string.
                    let redirectURL = zmAppendToken(realURL, token: token)
                    lr.redirect = URLRequest(url: redirectURL)
                    lr.response = HTTPURLResponse(url: redirectURL, statusCode: 302, httpVersion: nil, headerFields: nil)
                    lr.finishLoading()
                    hlsLog.debug("redirect \(realURL.path, privacy: .public)")
                }
            } catch {
                hlsLog.error("FAILED \(realURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                box.request.finishLoading(with: error)
            }
        }
        return true
    }
}

public enum ZmHLSLoaderError: Error { case invalidURL }

// MARK: - Free helpers (kept off the non-Sendable class so the loader Task captures nothing instance-bound)

func zmAssetURL(for realURL: URL) -> URL {
    var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false)!
    components.scheme = realURL.scheme == "https" ? "zmauths" : "zmauth"
    return components.url!
}

func zmRealURL(for customURL: URL) -> URL? {
    var components = URLComponents(url: customURL, resolvingAgainstBaseURL: false)
    switch customURL.scheme {
    case "zmauth": components?.scheme = "http"
    case "zmauths": components?.scheme = "https"
    default: return customURL
    }
    return components?.url
}

func zmAppendToken(_ url: URL, token: String) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    var items = components.queryItems ?? []
    items.removeAll { $0.name == "token" }
    items.append(URLQueryItem(name: "token", value: token))
    components.queryItems = items
    return components.url ?? url
}

/// Fetch a playlist with a Bearer header and rewrite every child URI to the custom scheme so
/// child playlists/segments route back through the loader.
func zmFetchPlaylist(realURL: URL, token: String, session: URLSession) async throws -> Data {
    var request = URLRequest(url: realURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (rawData, _) = try await session.data(for: request)
    guard let text = String(data: rawData, encoding: .utf8) else { return rawData }
    return Data(zmRewritePlaylist(text, realBaseURL: realURL).utf8)
}

func zmRewritePlaylist(_ text: String, realBaseURL: URL) -> String {
    func rewrite(_ uri: String) -> String {
        let trimmed = uri.trimmingCharacters(in: .whitespaces)
        guard let resolved = URL(string: trimmed, relativeTo: realBaseURL)?.absoluteURL else { return uri }
        return zmAssetURL(for: resolved).absoluteString
    }
    return text
        .components(separatedBy: "\n")
        .map { line -> String in
            if line.hasPrefix("#") { return zmRewriteURIAttribute(in: line, rewrite: rewrite) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            return rewrite(trimmed)
        }
        .joined(separator: "\n")
}

private func zmRewriteURIAttribute(in line: String, rewrite: (String) -> String) -> String {
    let marker = "URI=\""
    guard let start = line.range(of: marker) else { return line }
    let valueStart = start.upperBound
    guard let closing = line.range(of: "\"", range: valueStart..<line.endIndex) else { return line }
    let value = String(line[valueStart..<closing.lowerBound])
    return line.replacingCharacters(in: valueStart..<closing.lowerBound, with: rewrite(value))
}

private final class LoadingRequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
}
#endif
