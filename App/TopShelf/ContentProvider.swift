import TVServices
import DGGKit

/// Top Shelf: when DGGTV sits in the top row of the Home screen, the space
/// above shows what's live on the Big Screen, busiest first. Choosing one opens
/// the app straight into it.
///
/// This runs on its own, outside the app, so it reads the site's list itself.
final class ContentProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent() async -> TVTopShelfContent? {
        guard let items = await EmbedFeed.snapshot() else { return nil }
        let shelf = items
            .filter { $0.live != false && $0.ref.playsInApp }
            .sorted { $0.watching > $1.watching }
            .prefix(12)
            .map(item)
        guard !shelf.isEmpty else { return nil }
        let section = TVTopShelfItemCollection(items: Array(shelf))
        section.title = "Live now"
        return TVTopShelfSectionedContent(sections: [section])
    }

    private func item(_ entry: EmbedFeed.Item) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: entry.ref.token)
        let name = entry.name ?? entry.ref.displayName
        item.title = entry.watching > 0 ? "\(name) · \(entry.watching) watching" : name
        item.imageShape = .hdtv
        if let preview = entry.preview {
            item.setImageURL(preview, for: .screenScale1x)
            item.setImageURL(preview, for: .screenScale2x)
        }
        var link = URLComponents()
        link.scheme = "dggtv"
        link.host = "watch"
        link.queryItems = [URLQueryItem(name: "ref", value: entry.ref.token)]
        if let url = link.url {
            item.displayAction = TVTopShelfAction(url: url)
            item.playAction = TVTopShelfAction(url: url)
        }
        return item
    }
}
