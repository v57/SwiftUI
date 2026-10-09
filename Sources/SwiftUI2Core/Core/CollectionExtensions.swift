import Foundation

// SwiftUI ships these collection helpers (used with `onDelete` / `onMove`).
extension MutableCollection {
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var items = Array(self)
        let moving = source.map { items[$0] }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        for offset in source.sorted(by: >) { items.remove(at: offset) }
        items.insert(contentsOf: moving, at: adjustedDestination)
        for (index, item) in zip(indices, items) { self[index] = item }
    }
}

extension RangeReplaceableCollection where Self: MutableCollection {
    public mutating func remove(atOffsets offsets: IndexSet) {
        for offset in offsets.sorted(by: >) {
            remove(at: index(startIndex, offsetBy: offset))
        }
    }
}
