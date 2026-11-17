import SwiftUI
import UIKit
import Observation
import DGGKit

/// Emote artwork and the stylesheet that says how to draw it.
@MainActor
@Observable
final class EmoteImageStore {

    /// Bumped when chat lines need rebuilding: the stylesheet arriving, or a
    /// flair badge. Emote art doesn't, because a line's layout comes from the
    /// stylesheet and the picture drops into place by itself. Rebuilding would
    /// restart every animation on screen each time a new emote was first seen.
    private(set) var generation = 0
    private(set) var sheet: EmoteStyleSheet?

    private var names: Set<String> = []
    private var badges: [String: UIImage] = [:]
    private var inFlight: Set<String> = []
    private var assets: [String: EmoteAsset] = [:]
    private var waiting: [String: [(EmoteAsset) -> Void]] = [:]

    func load() async {
        await EmoteCatalog.shared.load()
        await apply()
    }

    /// Checks for emotes added since. True if there were any, after which chat
    /// lines are rebuilt so they show.
    @discardableResult
    func refresh() async -> Bool {
        guard await EmoteCatalog.shared.refresh() else { return false }
        await apply()
        return true
    }

    private func apply() async {
        let catalog = await EmoteCatalog.shared.snapshot()
        names = Set(catalog.compactMap { $0.value.url == nil ? nil : $0.key })
        // New emotes come with new rules in the stylesheet, for their size and
        // any animation, so it's fetched again too.
        if let any = catalog.values.compactMap(\.url).first,
           let fresh = await EmoteStyleSheet.load(anyEmoteImageURL: any) {
            sheet = fresh
        }
        generation += 1
    }

    func isEmote(_ token: String) -> Bool { names.contains(token) }

    var allPrefixes: Set<String> { names }

    func looks(_ context: EmoteContext) -> [EmoteLook] {
        sheet?.looks(for: context) ?? []
    }

    /// Calls back with the art, straight away if it's already here.
    func asset(_ url: String, _ done: @escaping (EmoteAsset) -> Void) {
        if let hit = assets[url] {
            done(hit)
            return
        }
        guard waiting[url] == nil else {
            waiting[url]?.append(done)
            return
        }
        waiting[url] = [done]
        Task { [weak self] in
            let asset = await Self.fetch(url)
            guard let self else { return }
            let callbacks = self.waiting.removeValue(forKey: url) ?? []
            guard let asset else { return }
            self.assets[url] = asset
            callbacks.forEach { $0(asset) }
        }
    }

    private nonisolated static func fetch(_ url: String) async -> EmoteAsset? {
        let data: Data?
        if url.hasPrefix("data:") {
            data = url.range(of: "base64,").flatMap { Data(base64Encoded: String(url[$0.upperBound...])) }
        } else if let u = URL(string: url) {
            data = try? await URLSession.shared.data(from: u).0
        } else {
            data = nil
        }
        guard let data else { return nil }
        return await Task.detached { EmoteAsset.decode(data) }.value
    }

    /// Flair badges come from their own URLs, not the emote manifest.
    func badge(_ url: String) -> UIImage? {
        if let img = badges[url] { return img }
        guard let u = URL(string: url), !inFlight.contains(url) else { return nil }
        inFlight.insert(url)
        Task { [weak self] in
            defer { self?.inFlight.remove(url) }
            guard let (data, _) = try? await URLSession.shared.data(from: u),
                  let raw = UIImage(data: data) else { return }
            self?.badges[url] = Self.scaled(raw, toHeight: 24)
            self?.badgesArrived()
        }
        return nil
    }

    /// Badges land one after another in the first seconds, a few dozen of them.
    /// Each used to rebuild every line on screen, restarting its emotes, so they
    /// are gathered up and chat is rebuilt once for the lot.
    @ObservationIgnored private var badgeBump: Task<Void, Never>?

    private func badgesArrived() {
        guard badgeBump == nil else { return }
        badgeBump = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.badgeBump = nil
            self.generation += 1
        }
    }

    private static func scaled(_ img: UIImage, toHeight h: CGFloat) -> UIImage {
        guard img.size.height > 0 else { return img }
        let w = img.size.width * (h / img.size.height)
        let size = CGSize(width: w, height: h)
        return UIGraphicsImageRenderer(size: size).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
