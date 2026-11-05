import Foundation

/// Caches the rendered form of each chat line.
///
/// Chat redraws ~8x a second. Rebuilding an NSAttributedString each time hands
/// the text view a brand new object, which makes TextKit tear down and rebuild
/// its attachment views — so animated emotes were destroyed and recreated
/// constantly, appearing for a split second and vanishing.
///
/// Returning the SAME instance lets the view skip the work entirely.
final class LineCache {
    private var store: [UUID: (generation: Int, size: Double, value: NSAttributedString)] = [:]
    private var order: [UUID] = []
    private let limit = 400

    func string(id: UUID, generation: Int, size: Double,
                build: () -> NSAttributedString) -> NSAttributedString {
        if let hit = store[id], hit.generation == generation, hit.size == size {
            return hit.value
        }
        let built = build()
        if store[id] == nil {
            order.append(id)
            if order.count > limit {
                let drop = order.removeFirst()
                store[drop] = nil
            }
        }
        store[id] = (generation, size, built)
        return built
    }
}
