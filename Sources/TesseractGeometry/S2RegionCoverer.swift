/// Approximates regions with a few cells.
///
/// A *covering* is a set of cells whose union contains the region; it trades precision for cell count. Cells are
/// subdivided largest first, keeping only children that may intersect the region, until either every cell is
/// contained in the region, the finest level is reached, or splitting further would exceed `maxCells`.
public struct S2RegionCoverer: Sendable, Hashable {
    /// No cell in a covering is larger than this level. May push the count above `maxCells`.
    public var minLevel: Int
    /// No cell is smaller than this level.
    public var maxLevel: Int
    /// A soft limit on the number of cells.
    public var maxCells: Int

    public init(minLevel: Int = 0, maxLevel: Int = S2CellID.maxLevel, maxCells: Int = 8) {
        precondition(0...S2CellID.maxLevel ~= minLevel && minLevel <= maxLevel && maxLevel <= S2CellID.maxLevel)
        self.minLevel = minLevel
        self.maxLevel = maxLevel
        self.maxCells = max(1, maxCells)
    }

    /// Cells, sorted, non-overlapping, whose union contains `region`. Empty if the region is empty.
    public func covering(_ region: some S2Region) -> [S2CellID] {
        var result: [S2CellID] = []
        // Breadth-first, so the largest cells are split first and the budget is spent evenly.
        var queue: [S2Cell] = (0..<6).map { S2Cell(S2CellID(face: $0)) }.filter(region.mayIntersect)
        var head = 0

        while head < queue.count {
            let cell = queue[head]
            head += 1
            let pending = queue.count - head

            if cell.level >= minLevel && (cell.level >= maxLevel || region.contains(cell)) {
                result.append(cell.id)
                continue
            }
            let children = cell.id.children.map(S2Cell.init).filter(region.mayIntersect)
            if cell.level >= minLevel && result.count + pending + children.count > maxCells {
                result.append(cell.id)
                continue
            }
            queue.append(contentsOf: children)
        }
        return Self.normalised(result, minLevel: minLevel)
    }

    /// Sorted, with cells inside other cells removed, and complete sets of four siblings replaced by their parent
    /// (when that parent is allowed).
    static func normalised(_ cells: [S2CellID], minLevel: Int) -> [S2CellID] {
        var output: [S2CellID] = []
        for cell in cells.sorted() {
            if let last = output.last, last.contains(cell) { continue }
            output.append(cell)
            // Merge siblings into their parent while the last four are a complete family.
            while output.count >= 4, let last = output.last, !last.isFace, last.level - 1 >= minLevel {
                let parent = last.parent
                let family = output.suffix(4)
                guard family.allSatisfy({ !$0.isFace && $0.level == last.level && $0.parent == parent }) else { break }
                output.removeLast(4)
                output.append(parent)
            }
        }
        return output
    }

    /// The leaf-cell ID ranges a covering spans, merged where they touch: one range scan each.
    public static func leafRanges(of covering: [S2CellID]) -> [ClosedRange<S2CellID>] {
        var ranges: [ClosedRange<S2CellID>] = []
        for cell in covering.sorted() {
            let range = cell.rangeMin...cell.rangeMax
            if let last = ranges.last, last.upperBound.rawValue &+ 2 >= range.lowerBound.rawValue {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }
}
