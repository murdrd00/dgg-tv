import AVFoundation
import Foundation

/// Gets Kick's delay down by rewriting its playlists on the way to AVPlayer.
///
/// Kick's streams list their next segments as `EXT-X-PREFETCH`, an addition of
/// Amazon's that lets its own player fetch a segment while it's still being
/// made. AVPlayer ignores the tag, and also stays a few segments back from the
/// newest one it can see, which with 4-second segments comes to about 15
/// seconds. Listing the prefetched segments as ordinary ones moves the live edge
/// forward by their length. Their URLs don't change when they later appear
/// properly, so to AVPlayer it's simply a playlist that's further along.
/// `LiveEdge` in the app then keeps playback close to that edge.
///
/// Playlists come through here on a custom scheme. Segments keep their real URLs
/// and go straight to the network.
public final class LiveLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    private static let scheme = "dgglive"
    private let queue = DispatchQueue(label: "gg.destiny.tv.liveloader")
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// The asset keeps only a weak reference to this, so the caller must hold it
    /// for as long as the asset plays.
    public func asset(for url: URL) -> AVURLAsset {
        let asset = AVURLAsset(url: Self.swapped(url, to: Self.scheme))
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    private static func swapped(_ url: URL, to scheme: String) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        parts?.scheme = scheme
        return parts?.url ?? url
    }

    public func resourceLoader(_ loader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let wrapped = request.request.url, wrapped.scheme == Self.scheme else { return false }
        let real = Self.swapped(wrapped, to: "https")
        let holder = Unchecked(request)
        session.dataTask(with: real) { data, response, error in
            let request = holder.value
            guard let data, let text = String(data: data, encoding: .utf8),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                request.finishLoading(with: error ?? URLError(.badServerResponse))
                return
            }
            let out = Data(Self.rewrite(text, base: real).utf8)
            request.contentInformationRequest?.contentType = "public.m3u-playlist"
            request.contentInformationRequest?.contentLength = Int64(out.count)
            request.contentInformationRequest?.isByteRangeAccessSupported = false
            request.dataRequest?.respond(with: out)
            request.finishLoading()
        }.resume()
        return true
    }

    private struct Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - Playlists

    public static func rewrite(_ text: String, base: URL) -> String {
        text.contains("#EXT-X-STREAM-INF") ? master(text, base: base) : media(text)
    }

    /// Every rendition has to come back through here too.
    private static func master(_ text: String, base: URL) -> String {
        text.components(separatedBy: "\n").map { line in
            if line.hasPrefix("#EXT-X-STREAM-INF") { return understated(line) }
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let url = URL(string: line, relativeTo: base)?.absoluteURL else { return line }
            return swapped(url, to: scheme).absoluteString
        }.joined(separator: "\n")
    }

    /// A segment still being made arrives at the speed it's made, which AVPlayer
    /// reads as a slow connection, so it dropped a 1080p stream to 360p. Claiming
    /// less than the true bitrate keeps it where it is, and it still drops if the
    /// connection really is slow.
    public static let bitrateScale = 4.0

    private static func understated(_ line: String) -> String {
        var out = ""
        var rest = Substring(line)
        while let range = rest.range(of: "BANDWIDTH=") {
            out += rest[..<range.upperBound]
            rest = rest[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            out += Double(digits).map { String(Int($0 / bitrateScale)) } ?? String(digits)
            rest = rest[digits.endIndex...]
        }
        return out + rest
    }

    private static let dates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func media(_ text: String) -> String {
        var lastDate: Date?
        var lastLength = 0.0
        var out: [String] = []
        // Only the next one. A second is still to start, so AVPlayer sits waiting
        // on it, stalls, and decides the connection is bad.
        var prefetched = false
        let lines = text.components(separatedBy: "\n")
        // Kick declares more than it uses, and AVPlayer's reloads and its
        // distance from the live edge both follow this number.
        let longest = lines.filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).prefix { $0 != "," }) }.max()
        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION"), let longest {
                out.append("#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))")
                continue
            }
            if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                lastDate = dates.date(from: String(line.dropFirst(25)))
            } else if line.hasPrefix("#EXTINF:") {
                lastLength = Double(line.dropFirst(8).prefix { $0 != "," }) ?? lastLength
            }
            guard line.hasPrefix("#EXT-X-PREFETCH:") else {
                out.append(line)
                continue
            }
            guard !prefetched else { continue }
            prefetched = true
            // Its real length isn't known yet, but they barely vary. The date
            // carries on from the last one, which keeps the delay reading right.
            if let date = lastDate?.addingTimeInterval(lastLength) {
                out.append("#EXT-X-PROGRAM-DATE-TIME:" + dates.string(from: date))
                lastDate = date
            }
            out.append("#EXTINF:\(lastLength),live")
            out.append(String(line.dropFirst(16)))
        }
        return out.joined(separator: "\n")
    }
}
