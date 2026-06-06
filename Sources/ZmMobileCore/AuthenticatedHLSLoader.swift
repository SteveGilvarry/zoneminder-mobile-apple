import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Routes every HLS request (master playlist, child playlists, media segments, keys) through
/// `URLSession` with a `Bearer` token attached.
///
/// The ZoneMinder backend emits child playlist / segment URIs in its playlists *without*
/// propagating an auth token, and `AVPlayer` will not let us attach headers to those derived
/// requests directly. So we hand `AVPlayer` a custom-scheme (`zmauth` / `zmauths`) master URL,
/// intercept every request here, and — crucially — **rewrite each URI inside fetched playlists
/// back to the custom scheme** so the child playlists and segments come back through this loader
/// (and get the `Authorization` header) instead of being fetched unauthenticated by `AVPlayer`.
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

    /// Swap a real `http(s)` URL to the custom scheme so `AVPlayer` defers loading to this delegate.
    public func assetURL(for realURL: URL) -> URL { zmAssetURL(for: realURL) }

    /// Swap a custom-scheme URL back to its real `http(s)` URL for the actual network fetch.
    public func realURL(for customURL: URL) -> URL? { zmRealURL(for: customURL) }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let realURL = zmRealURL(for: url) else {
            loadingRequest.finishLoading(with: ZmHLSLoaderError.invalidURL)
            return false
        }

        let provider = accessTokenProvider
        let urlSession = session
        let box = LoadingRequestBox(loadingRequest)

        Task {
            do {
                let token = try await provider()
                let loaded = try await zmFetchHLSResource(realURL: realURL, token: token, session: urlSession)
                let loadingRequest = box.request
                if let info = loadingRequest.contentInformationRequest {
                    info.contentType = loaded.contentType
                    info.contentLength = Int64(loaded.data.count)
                    info.isByteRangeAccessSupported = !loaded.isPlaylist
                }
                if let dataRequest = loadingRequest.dataRequest {
                    let offset = Int(dataRequest.currentOffset)
                    if offset < loaded.data.count {
                        let end = dataRequest.requestsAllDataToEndOfResource
                            ? loaded.data.count
                            : min(offset + dataRequest.requestedLength, loaded.data.count)
                        dataRequest.respond(with: loaded.data.subdata(in: offset..<end))
                    }
                }
                loadingRequest.finishLoading()
            } catch {
                box.request.finishLoading(with: error)
            }
        }
        return true
    }
}

public enum ZmHLSLoaderError: Error {
    case invalidURL
}

// MARK: - Free helpers (kept out of the non-Sendable class so the loader Task captures nothing instance-bound)

struct ZmLoadedResource: Sendable {
    let data: Data
    let contentType: String?
    let isPlaylist: Bool
}

func zmAssetURL(for realURL: URL) -> URL {
    var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false)!
    components.scheme = realURL.scheme == "https" ? "zmauths" : "zmauth"
    return components.url!
}

func zmRealURL(for customURL: URL) -> URL? {
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

/// Fetch a resource with the bearer token; rewrite child URIs if it is a playlist.
func zmFetchHLSResource(realURL: URL, token: String, session: URLSession) async throws -> ZmLoadedResource {
    var request = URLRequest(url: realURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (rawData, response) = try await session.data(for: request)
    let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?
        .split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }

    let isPlaylist = realURL.pathExtension.lowercased() == "m3u8"
        || (mime?.lowercased().contains("mpegurl") ?? false)

    let data: Data
    if isPlaylist, let text = String(data: rawData, encoding: .utf8) {
        data = Data(zmRewritePlaylist(text, realBaseURL: realURL).utf8)
    } else {
        data = rawData
    }
    return ZmLoadedResource(data: data, contentType: zmContentType(isPlaylist: isPlaylist, mime: mime), isPlaylist: isPlaylist)
}

/// Best-effort UTI for the content-information request. `AVPlayer` needs the playlist typed as
/// HLS; segments are fine with a mapped UTI (or none — the playlist already described them).
func zmContentType(isPlaylist: Bool, mime: String?) -> String? {
    if isPlaylist { return "public.m3u-playlist" }
    #if canImport(UniformTypeIdentifiers)
    if let mime, let type = UTType(mimeType: mime) { return type.identifier }
    #endif
    return nil
}

/// Rewrite all URIs in an HLS playlist to the custom scheme, resolving relative URIs first.
func zmRewritePlaylist(_ text: String, realBaseURL: URL) -> String {
    func rewrite(_ uri: String) -> String {
        let trimmed = uri.trimmingCharacters(in: .whitespaces)
        guard let resolved = URL(string: trimmed, relativeTo: realBaseURL)?.absoluteURL else { return uri }
        return zmAssetURL(for: resolved).absoluteString
    }

    return text
        .components(separatedBy: "\n")
        .map { line -> String in
            if line.hasPrefix("#") {
                return zmRewriteURIAttribute(in: line, rewrite: rewrite)
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            return rewrite(trimmed)
        }
        .joined(separator: "\n")
}

/// Rewrite the value of a `URI="..."` attribute (EXT-X-KEY / -MEDIA / -MAP / -I-FRAME-STREAM-INF).
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

    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }
}
#endif
