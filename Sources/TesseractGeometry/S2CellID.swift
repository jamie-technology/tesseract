/// A cell in S2's hierarchical decomposition of the sphere, identified by its position on the Hilbert curve.
///
/// The sphere is projected onto the six faces of a cube; each face is a quadtree 30 levels deep. A cell ID packs
/// the face (3 bits) and the cell's position along a Hilbert curve through that face's quadtree, followed by a
/// single 1 bit that marks the level. So:
///
/// - Cells that are close on the sphere tend to have close IDs, and
/// - every cell's descendants occupy one contiguous range of IDs (``rangeMin``...``rangeMax``).
///
/// The second property is what makes spatial indexing over ordered keys work: a region is covered by a few cells,
/// and each cell becomes one range scan over the leaf cells of indexed points. IDs (and ``token``s) are
/// bit-for-bit compatible with Google's S2 libraries.
public struct S2CellID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public static let maxLevel = 30
    static let maxSize = 1 << maxLevel
    static let posBits = 2 * maxLevel + 1

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The level-0 cell for a cube face, 0...5.
    public init(face: Int) {
        rawValue = UInt64(face) << UInt64(Self.posBits) + Self.lsb(forLevel: 0)
    }

    /// The leaf cell containing a point.
    public init(_ point: S2Point) {
        let face = S2Projection.face(of: point)
        let (u, v) = S2Projection.uv(of: point, onFace: face)
        self = Self(
            face: face,
            i: S2Projection.stToIJ(S2Projection.uvToST(u)),
            j: S2Projection.stToIJ(S2Projection.uvToST(v))
        )
    }

    /// The leaf cell containing a latitude and longitude.
    public init(_ latLng: LatLng) {
        self.init(latLng.point)
    }

    /// The cell at `level` containing a latitude and longitude.
    public init(_ latLng: LatLng, level: Int) {
        self = Self(latLng).parent(level)
    }

    /// Parses a ``token``. `nil` if it isn't one.
    public init?(token: String) {
        guard !token.isEmpty, token.count <= 16 else { return nil }
        if token == "X" {
            rawValue = 0
            return
        }
        guard let value = UInt64(token, radix: 16) else { return nil }
        rawValue = value << UInt64(4 * (16 - token.count))
    }

    // MARK: Structure

    public var face: Int { Int(rawValue >> UInt64(Self.posBits)) }

    /// The lowest set bit: it marks the level.
    public var lsb: UInt64 { rawValue & (0 &- rawValue) }

    public static func lsb(forLevel level: Int) -> UInt64 {
        1 << UInt64(2 * (maxLevel - level))
    }

    public var level: Int { Self.maxLevel - rawValue.trailingZeroBitCount / 2 }

    public var isValid: Bool {
        face < 6 && (lsb & 0x1555_5555_5555_5555) != 0
    }

    public var isLeaf: Bool { rawValue & 1 != 0 }
    public var isFace: Bool { rawValue & (Self.lsb(forLevel: 0) - 1) == 0 }

    /// The ancestor at `level`, which must be at most this cell's level.
    public func parent(_ level: Int) -> S2CellID {
        precondition(level >= 0 && level <= self.level, "level \(level) is not an ancestor of \(self.level)")
        let newLSB = Self.lsb(forLevel: level)
        return S2CellID(rawValue: (rawValue & (0 &- newLSB)) | newLSB)
    }

    public var parent: S2CellID { parent(level - 1) }

    /// The four children, in Hilbert-curve order.
    public var children: [S2CellID] {
        precondition(!isLeaf, "leaf cells have no children")
        let childLSB = lsb >> 2
        var child = rawValue - lsb + childLSB
        var result: [S2CellID] = []
        result.reserveCapacity(4)
        for _ in 0..<4 {
            result.append(S2CellID(rawValue: child))
            child += childLSB << 1
        }
        return result
    }

    /// The smallest leaf cell ID within this cell.
    public var rangeMin: S2CellID { S2CellID(rawValue: rawValue - (lsb - 1)) }
    /// The largest leaf cell ID within this cell.
    public var rangeMax: S2CellID { S2CellID(rawValue: rawValue + (lsb - 1)) }

    public func contains(_ other: S2CellID) -> Bool {
        other.rawValue >= rangeMin.rawValue && other.rawValue <= rangeMax.rawValue
    }

    public func intersects(_ other: S2CellID) -> Bool {
        other.rangeMin.rawValue <= rangeMax.rawValue && other.rangeMax.rawValue >= rangeMin.rawValue
    }

    /// This cell's ancestors (and itself) at each level in `levels`, finest first. Levels finer than this cell are
    /// skipped.
    public func ancestors(levels: ClosedRange<Int>) -> [S2CellID] {
        guard levels.lowerBound <= level else { return [] }
        return (levels.lowerBound...min(levels.upperBound, level)).reversed().map { parent($0) }
    }

    // MARK: Encodings

    /// The compact hex form S2 uses: the ID without trailing zero nibbles. `X` for the invalid ID 0.
    public var token: String {
        guard rawValue != 0 else { return "X" }
        let hex = String(rawValue, radix: 16)
        let padded = String(repeating: "0", count: 16 - hex.count) + hex
        return String(padded.reversed().drop(while: { $0 == "0" }).reversed())
    }

    /// The ID as a signed integer with the same ordering, for storing in signed (e.g. tuple or protobuf `int64`)
    /// fields: the sign bit is flipped, so ID order and `Int64` order agree.
    public var indexKey: Int64 { Int64(bitPattern: rawValue ^ (1 << 63)) }

    public init(indexKey: Int64) {
        rawValue = UInt64(bitPattern: indexKey) ^ (1 << 63)
    }

    public var description: String { token }

    public static func < (a: S2CellID, b: S2CellID) -> Bool { a.rawValue < b.rawValue }

    // MARK: Hilbert curve

    init(face: Int, i: Int, j: Int) {
        var n = UInt64(face) << UInt64(Self.posBits - 1)
        var bits = face & HilbertTables.swapMask
        for k in stride(from: 7, through: 0, by: -1) {
            let mask = (1 << HilbertTables.lookupBits) - 1
            bits += ((i >> (k * HilbertTables.lookupBits)) & mask) << (HilbertTables.lookupBits + 2)
            bits += ((j >> (k * HilbertTables.lookupBits)) & mask) << 2
            bits = HilbertTables.lookupPos[bits]
            n |= UInt64(bits >> 2) << UInt64(k * 2 * HilbertTables.lookupBits)
            bits &= HilbertTables.swapMask | HilbertTables.invertMask
        }
        rawValue = n * 2 + 1
    }

    /// The face, and the (i, j) coordinates of the leaf cell at (or just beside) this cell's centre.
    func faceIJ() -> (face: Int, i: Int, j: Int) {
        var i = 0, j = 0
        let face = self.face
        var bits = face & HilbertTables.swapMask
        for k in stride(from: 7, through: 0, by: -1) {
            let nbits = k == 7 ? Self.maxLevel - 7 * HilbertTables.lookupBits : HilbertTables.lookupBits
            bits += Int((rawValue >> UInt64(k * 2 * HilbertTables.lookupBits + 1)) & ((1 << UInt64(2 * nbits)) - 1)) << 2
            bits = HilbertTables.lookupIJ[bits]
            i += (bits >> (HilbertTables.lookupBits + 2)) << (k * HilbertTables.lookupBits)
            j += ((bits >> 2) & ((1 << HilbertTables.lookupBits) - 1)) << (k * HilbertTables.lookupBits)
            bits &= HilbertTables.swapMask | HilbertTables.invertMask
        }
        return (face, i, j)
    }
}

/// Lookup tables that convert 4 bits of (i, j) at a time to and from Hilbert-curve positions.
enum HilbertTables {
    static let lookupBits = 4
    static let swapMask = 1
    static let invertMask = 2

    static let posToIJ = [[0, 1, 3, 2], [0, 2, 3, 1], [3, 2, 0, 1], [3, 1, 0, 2]]
    static let posToOrientation = [swapMask, 0, 0, invertMask | swapMask]

    static let (lookupPos, lookupIJ): ([Int], [Int]) = {
        let size = 1 << (2 * lookupBits + 2)
        var pos = [Int](repeating: 0, count: size)
        var ij = [Int](repeating: 0, count: size)

        func fill(level: Int, i: Int, j: Int, origin: Int, position: Int, orientation: Int) {
            if level == lookupBits {
                let ijIndex = (i << lookupBits) + j
                pos[(ijIndex << 2) + origin] = (position << 2) + orientation
                ij[(position << 2) + origin] = (ijIndex << 2) + orientation
                return
            }
            let r = posToIJ[orientation]
            for index in 0..<4 {
                fill(
                    level: level + 1, i: (i << 1) + (r[index] >> 1), j: (j << 1) + (r[index] & 1), origin: origin,
                    position: (position << 2) + index, orientation: orientation ^ posToOrientation[index]
                )
            }
        }
        for orientation in [0, swapMask, invertMask, swapMask | invertMask] {
            fill(level: 0, i: 0, j: 0, origin: orientation, position: 0, orientation: orientation)
        }
        return (pos, ij)
    }()
}
