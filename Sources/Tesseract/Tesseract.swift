public import FDBRecordLayer
public import FoundationDB
public import SwiftProtobuf
@_exported public import TesseractGeometry

// MARK: - Index declarations

/// Indexes records by a point, optionally after an equality prefix.
///
/// Each record keeps the leaf cell of its location in an `int64` field (``S2CellID/indexKey``; set it with
/// ``cellKey(for:)`` whenever you set the location), and the index is an ordinary value index on
/// `(prefix…, cell)`. A region query covers the region with cells, scans each cell's range of leaf IDs within the
/// given prefix, and checks the exact location of every candidate.
///
/// ```swift
/// static let placeLocation = PointIndex<Place>(name: "place.location", key: 201, cell: \.cell) {
///     LatLng(latitude: $0.latitude, longitude: $0.longitude)
/// }
/// // "Alice's places near here" reads only Alice's entries:
/// static let placeByOwner = PointIndex<Place>(name: "place.owner-location", key: 202, prefix: [.field(\.owner)],
///                                             cell: \.cell) { LatLng(latitude: $0.latitude, longitude: $0.longitude) }
/// RecordType(Place.self, key: 2, primaryKey: \.id).index(placeLocation).index(placeByOwner)
/// ```
public struct PointIndex<M: SwiftProtobuf.Message & Sendable>: Sendable {
    public let name: String
    /// The index's explicit subspace key, as for any Record Layer index. `nil` uses the name.
    public let key: Int?
    /// Columns before the cell, which every query fixes with equality. Each must produce exactly one value per
    /// record (no fan-out).
    public let prefix: [KeyExpression<M>]
    public let cell: KeyPath<M, Int64> & Sendable
    public let location: @Sendable (M) -> LatLng
    /// How query regions are covered: more cells mean less over-scanning, but more range reads.
    public var queryCoverer = S2RegionCoverer(minLevel: 0, maxLevel: S2CellID.maxLevel, maxCells: 16)

    public init(
        name: String, key: Int? = nil, prefix: [KeyExpression<M>] = [], cell: KeyPath<M, Int64> & Sendable,
        location: @escaping @Sendable (M) -> LatLng
    ) {
        self.name = name
        self.key = key
        self.prefix = prefix
        self.cell = cell
        self.location = location
    }

    /// The value to store in the cell field for a record at `location`.
    public func cellKey(for location: LatLng) -> Int64 {
        S2CellID(location).indexKey
    }

    var expression: KeyExpression<M> {
        prefix.isEmpty ? .field(cell) : .concat(prefix + [.field(cell)])
    }
}

/// Indexes records by an area (a geofence), optionally after an equality prefix: the cells covering it, in a
/// repeated `int64` field, under a fan-out value index on `(prefix…, coverage cell)`.
///
/// "Which areas contain this point?" looks up the point's ancestor cells at each level in ``levels``: an area whose
/// covering contains the point has one of them. Every candidate is then checked exactly with ``contains``.
///
/// ```swift
/// static let zoneArea = RegionIndex<Zone>(name: "zone.area", key: 301, coverage: \.coverage) { zone, point in
///     zone.center.distance(to: point) <= zone.radiusMeters
/// }
/// zone.coverage = zoneArea.coverage(of: S2Cap(center: centre, radiusMeters: 250))
/// ```
public struct RegionIndex<M: SwiftProtobuf.Message & Sendable>: Sendable {
    public let name: String
    public let key: Int?
    /// Columns before the coverage cell, which every query fixes with equality. No fan-out.
    public let prefix: [KeyExpression<M>]
    public let coverage: KeyPath<M, [Int64]> & Sendable
    /// Exactly whether a record's area contains a point.
    public let contains: @Sendable (M, LatLng) -> Bool
    /// The cell levels coverings use. A point query reads one index prefix per level, so keep the range narrow:
    /// coarse enough for the largest areas, fine enough for the smallest.
    public let levels: ClosedRange<Int>
    public let maxCells: Int

    public init(
        name: String, key: Int? = nil, prefix: [KeyExpression<M>] = [], coverage: KeyPath<M, [Int64]> & Sendable,
        levels: ClosedRange<Int> = 6...18, maxCells: Int = 8,
        contains: @escaping @Sendable (M, LatLng) -> Bool
    ) {
        self.name = name
        self.key = key
        self.prefix = prefix
        self.coverage = coverage
        self.levels = levels
        self.maxCells = maxCells
        self.contains = contains
    }

    /// The value to store in the coverage field for a record covering `region`.
    public func coverage(of region: some S2Region) -> [Int64] {
        S2RegionCoverer(minLevel: levels.lowerBound, maxLevel: levels.upperBound, maxCells: maxCells)
            .covering(region).map(\.indexKey)
    }

    var expression: KeyExpression<M> {
        let cells = KeyExpression<M>.field(coverage, .fanOut)
        return prefix.isEmpty ? cells : .concat(prefix + [cells])
    }
}

extension RecordType {
    /// Declares a ``PointIndex``: a value index on `(prefix…, cell)`.
    public func index(_ spatial: PointIndex<M>, addedVersion: Int? = nil) -> RecordType<M> {
        index(spatial.name, on: spatial.expression, key: spatial.key, addedVersion: addedVersion)
    }

    /// Declares a ``RegionIndex``: a fan-out value index on `(prefix…, coverage cell)`.
    public func index(_ spatial: RegionIndex<M>, addedVersion: Int? = nil) -> RecordType<M> {
        index(spatial.name, on: spatial.expression, key: spatial.key, addedVersion: addedVersion)
    }
}

// MARK: - Queries

/// A record found by a spatial query, with its distance from the query's reference point (if it has one).
public struct SpatialMatch<M: SwiftProtobuf.Message & Sendable>: Sendable {
    public let stored: FDBStoredRecord<M>
    public let distanceMeters: Double?
    public var record: M { stored.record }
}

/// Where a paged query got to: pass it back, with the *same* query, to read the next page.
///
/// Region pages follow index order, `(cell, primary key)`, a total order, so this is keyset pagination: the
/// continuation is a fingerprint of the query followed by the last index entry the page read. Nearest-first pages
/// follow `(distance, primary key)`, and the continuation records the ring being read and the last match. Either
/// way it is exact (records at the same place are never skipped or repeated); between pages, records written behind
/// it are missed and records written ahead of it are seen. Using it with a different query throws
/// ``TesseractError/invalidContinuation``. Opaque; ``bytes`` round-trips.
public struct SpatialContinuation: Sendable, Hashable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) { self.bytes = bytes }
}

/// One page of a region query, in index order (by cell, not by distance).
public struct SpatialPage<M: SwiftProtobuf.Message & Sendable>: Sendable {
    public let records: [FDBStoredRecord<M>]
    /// `nil` when the query is exhausted.
    public let continuation: SpatialContinuation?
}

/// One page of a nearest-first query.
public struct NearestPage<M: SwiftProtobuf.Message & Sendable>: Sendable {
    /// Nearest first; ties by primary key.
    public let matches: [SpatialMatch<M>]
    /// `nil` when everything within the maximum distance has been returned.
    public let continuation: SpatialContinuation?
}

/// How much one page may do. FoundationDB transactions must finish within five seconds, so a query over a dense
/// area is read a page per transaction.
public struct SpatialScanLimits: Sendable, Hashable {
    /// Stop after this many matching records (0: no limit).
    public var records: Int
    /// Stop after loading this many candidate records, matching or not (0: no limit). This is what bounds the work
    /// a page does when the filters reject most candidates. Point queries skip index entries whose cell can't be in
    /// the region without loading them; at most 16 times this many of those are read per page.
    public var entries: Int

    public init(records: Int = 0, entries: Int = 2_000) {
        self.records = records
        self.entries = entries
    }

    /// Everything, in one transaction. Only for regions known to be small.
    public static let unlimited = SpatialScanLimits(records: 0, entries: 0)
}

public enum TesseractError: Error, Sendable, Equatable {
    /// The index is still being built (or disabled) in this store.
    case indexNotReadable(String)
    /// A continuation that doesn't belong to this query.
    case invalidContinuation
    /// A query must give one value for each of the index's prefix columns.
    case prefixMismatch(expected: Int, got: Int)
}

/// A filter applied to each candidate (after the exact geometric test, before the limit counts it). It sees the
/// stored record, so it can test the record's version (`stored.version`) as well as its fields.
public typealias SpatialFilter<M: SwiftProtobuf.Message & Sendable> = @Sendable (FDBStoredRecord<M>) -> Bool

extension FDBRecordStore {
    /// One page of the records whose point lies in `region` (and whose prefix columns equal `prefix`). Exact.
    ///
    /// The index ranges a page reads become read conflicts of this transaction, so a concurrent write of a record
    /// into those ranges makes the transaction retry. Pages are each consistent; read them in separate
    /// transactions, passing ``SpatialPage/continuation`` back with the same query.
    public func records<M>(
        in region: some S2Region, using index: PointIndex<M>, prefix: [any IndexableValue] = [],
        limits: SpatialScanLimits = SpatialScanLimits(), continuation: SpatialContinuation? = nil,
        where filter: SpatialFilter<M>? = nil
    ) async throws -> SpatialPage<M> {
        try checkReadable(index.name)
        let prefixValues = try Self.prefixValues(prefix, expected: index.prefix.count)
        let ranges = S2RegionCoverer.leafRanges(of: index.queryCoverer.covering(region))
            .map { ($0.lowerBound.indexKey, $0.upperBound.indexKey) }
        return try await scanPage(
            M.self, subspaceKey: index.subspaceKey, prefix: prefixValues, valueRanges: ranges, limits: limits,
            continuation: continuation,
            // The covering over-approximates the region; an entry's leaf cell says whether it can possibly be in it.
            candidate: { region.mayIntersect(S2Cell(S2CellID(indexKey: $0))) }
        ) { stored in
            region.contains(index.location(stored.record).point) && (filter?(stored) ?? true)
        }
    }

    /// Records within `radiusMeters` of `center`, nearest first, with their distances. Exact. Reads the whole
    /// circle in this transaction, up to `maxEntries` index entries (then throws ``SpatialScanLimitExceeded``).
    public func records<M>(
        within radiusMeters: Double, of center: LatLng, using index: PointIndex<M>, prefix: [any IndexableValue] = [],
        maxEntries: Int = 10_000, where filter: SpatialFilter<M>? = nil
    ) async throws -> [SpatialMatch<M>] {
        let page = try await records(
            in: S2Cap(center: center, radiusMeters: radiusMeters), using: index, prefix: prefix,
            limits: SpatialScanLimits(records: 0, entries: maxEntries), where: filter
        )
        guard page.continuation == nil else { throw SpatialScanLimitExceeded(entries: maxEntries) }
        return Self.byDistance(page.records, from: center, index: index)
    }

    /// The `count` records nearest `center`, no further than `maxDistanceMeters`, nearest first, in one
    /// transaction. For more than a screenful, use ``nearest(to:using:prefix:within:pageSize:continuation:firstRingMeters:maxEntries:where:)``.
    public func nearest<M>(
        _ count: Int, to center: LatLng, within maxDistanceMeters: Double, using index: PointIndex<M>,
        prefix: [any IndexableValue] = [], maxEntries: Int = 10_000, where filter: SpatialFilter<M>? = nil
    ) async throws -> [SpatialMatch<M>] {
        try await nearest(
            to: center, using: index, prefix: prefix, within: maxDistanceMeters, pageSize: count,
            maxEntries: maxEntries, where: filter
        ).matches
    }

    /// One page of the records nearest `center`, nearest first (ties by primary key), out to `maxDistanceMeters`.
    ///
    /// Reads outwards in rings. A ring is read whole — that's what lets it be sorted by distance — and handed out
    /// a page at a time; rings double in width as they go, and a ring holding more than `maxEntries` index entries
    /// is halved until it fits, so a page's work stays bounded however dense the area. (The exception is more
    /// than `maxEntries` records at exactly one distance, which can't be split: that ring is read whole.)
    ///
    /// Pass ``NearestPage/continuation`` back, with the same arguments, in a new transaction for the next page.
    public func nearest<M>(
        to center: LatLng, using index: PointIndex<M>, prefix: [any IndexableValue] = [],
        within maxDistanceMeters: Double, pageSize: Int, continuation: SpatialContinuation? = nil,
        firstRingMeters: Double = 250, maxEntries: Int = 2_000, where filter: SpatialFilter<M>? = nil
    ) async throws -> NearestPage<M> {
        try checkReadable(index.name)
        let prefixValues = try Self.prefixValues(prefix, expected: index.prefix.count)
        var query = Bytes()
        query.append(double: center.latitude)
        query.append(double: center.longitude)
        query.append(double: maxDistanceMeters)
        query.append(double: firstRingMeters)
        query += Tuple(prefixValues).encode()
        let fingerprint = Self.fingerprint(query.bytes)

        var cursor = try continuation.map { try NearestCursor(decoding: $0.bytes, fingerprint: fingerprint) }
            ?? NearestCursor(inner: 0, outer: min(firstRingMeters, maxDistanceMeters), after: nil)
        var matches: [SpatialMatch<M>] = []
        var entriesRead = 0

        while true {
            // Read the ring whole, halving it while it's too dense to read in one go.
            var ring: SpatialPage<M>
            while true {
                ring = try await records(
                    in: S2Annulus(center: center, innerRadiusMeters: cursor.inner, outerRadiusMeters: cursor.outer),
                    using: index, prefix: prefix,
                    limits: SpatialScanLimits(records: 0, entries: cursor.outer - cursor.inner < 0.01 ? 0 : maxEntries),
                    where: filter
                )
                if ring.continuation == nil { break }
                cursor.outer = cursor.inner + (cursor.outer - cursor.inner) / 2
            }
            entriesRead += ring.records.count

            let isLast = cursor.outer >= maxDistanceMeters
            var sorted = Self.byDistance(ring.records, from: center, index: index).filter {
                $0.distanceMeters! >= cursor.inner && (isLast ? $0.distanceMeters! <= cursor.outer : $0.distanceMeters! < cursor.outer)
            }
            if let after = cursor.after {
                sorted.removeAll { !NearestCursor.isAfter($0, after) }
            }
            for match in sorted {
                matches.append(match)
                if matches.count >= pageSize {
                    cursor.after = (match.distanceMeters!, match.stored.primaryKey.encode())
                    return NearestPage(matches: matches, continuation: SpatialContinuation(bytes: cursor.encoded(fingerprint)))
                }
            }

            // Ring exhausted: the next is twice as wide.
            if isLast { return NearestPage(matches: matches, continuation: nil) }
            let width = cursor.outer - cursor.inner
            cursor = NearestCursor(inner: cursor.outer, outer: min(cursor.outer + width * 2, maxDistanceMeters), after: nil)
            // Don't read ring after ring of nothing in one transaction.
            if entriesRead >= maxEntries {
                return NearestPage(matches: matches, continuation: SpatialContinuation(bytes: cursor.encoded(fingerprint)))
            }
        }
    }

    /// One page of the records whose area contains `point`. Exact.
    ///
    /// Membership is transactionally consistent: the index entries read become read conflicts, so if another
    /// transaction adds or removes an area containing this point, this one retries rather than acting on a stale
    /// answer. A point lies in at most one cell of any area's covering, so no record appears twice.
    public func records<M>(
        containing point: LatLng, using index: RegionIndex<M>, prefix: [any IndexableValue] = [],
        limits: SpatialScanLimits = SpatialScanLimits(), continuation: SpatialContinuation? = nil,
        where filter: SpatialFilter<M>? = nil
    ) async throws -> SpatialPage<M> {
        try checkReadable(index.name)
        let prefixValues = try Self.prefixValues(prefix, expected: index.prefix.count)
        let ranges = S2CellID(point).ancestors(levels: index.levels).sorted().map { ($0.indexKey, $0.indexKey) }
        return try await scanPage(
            M.self, subspaceKey: index.subspaceKey, prefix: prefixValues, valueRanges: ranges, limits: limits,
            continuation: continuation
        ) { stored in
            index.contains(stored.record, point) && (filter?(stored) ?? true)
        }
    }

    /// One page of the records whose area's covering intersects `region`'s covering: every area that intersects
    /// the region, and possibly some near it (coverings over-approximate). Within a page each record appears once;
    /// an area with several covering cells in the region may appear again on a later page.
    public func records<M>(
        intersecting region: some S2Region, using index: RegionIndex<M>, prefix: [any IndexableValue] = [],
        limits: SpatialScanLimits = SpatialScanLimits(), continuation: SpatialContinuation? = nil,
        where filter: SpatialFilter<M>? = nil
    ) async throws -> SpatialPage<M> {
        try checkReadable(index.name)
        let prefixValues = try Self.prefixValues(prefix, expected: index.prefix.count)
        let covering = S2RegionCoverer(minLevel: index.levels.lowerBound, maxLevel: index.levels.upperBound, maxCells: 16)
            .covering(region)
        // Areas with a cell inside one of the query's cells: one range per query cell.
        var ranges = S2RegionCoverer.leafRanges(of: covering).map { ($0.lowerBound.indexKey, $0.upperBound.indexKey) }
        // Areas with a cell containing one of the query's cells: its strict ancestors. A cell's ID lies in none of
        // its descendants' ranges, so these never overlap the ranges above.
        var ancestors = Set<S2CellID>()
        for cell in covering where cell.level > index.levels.lowerBound {
            ancestors.formUnion(cell.parent.ancestors(levels: index.levels))
        }
        ranges += ancestors.map { ($0.indexKey, $0.indexKey) }
        ranges.sort { $0.0 < $1.0 }
        return try await scanPage(
            M.self, subspaceKey: index.subspaceKey, prefix: prefixValues, valueRanges: ranges, limits: limits,
            continuation: continuation
        ) { filter?($0) ?? true }
    }

    /// Pairs every point record in `region` with the area records containing it: a spatial join, one page of
    /// points per call. To join a large region in parallel, split its covering into cells and join each cell in
    /// its own transaction (or on its own node).
    public func join<P, A>(
        _ points: PointIndex<P>, with areas: RegionIndex<A>, in region: some S2Region,
        pointPrefix: [any IndexableValue] = [], areaPrefix: [any IndexableValue] = [],
        limits: SpatialScanLimits = SpatialScanLimits(), continuation: SpatialContinuation? = nil
    ) async throws -> (pairs: [(point: FDBStoredRecord<P>, areas: [FDBStoredRecord<A>])], continuation: SpatialContinuation?) {
        let page = try await records(in: region, using: points, prefix: pointPrefix, limits: limits, continuation: continuation)
        var pairs: [(point: FDBStoredRecord<P>, areas: [FDBStoredRecord<A>])] = []
        for point in page.records {
            let containing = try await records(
                containing: points.location(point.record), using: areas, prefix: areaPrefix, limits: .unlimited
            )
            pairs.append((point, containing.records))
        }
        return (pairs, page.continuation)
    }

    // MARK: Index scans

    private func checkReadable(_ name: String) throws {
        guard isIndexScannable(name) else { throw TesseractError.indexNotReadable(name) }
    }

    private static func prefixValues(_ values: [any IndexableValue], expected: Int) throws -> [any TupleElement] {
        guard values.count == expected else { throw TesseractError.prefixMismatch(expected: expected, got: values.count) }
        return values.map { $0.asTupleElement() }
    }

    private static func byDistance<M>(_ records: [FDBStoredRecord<M>], from center: LatLng, index: PointIndex<M>) -> [SpatialMatch<M>] {
        records
            .map { SpatialMatch(stored: $0, distanceMeters: index.location($0.record).distance(to: center)) }
            .sorted { NearestCursor.isAfter($1, ($0.distanceMeters!, $0.stored.primaryKey.encode())) }
    }

    /// Reads a page of a value index on `(prefix…, cell)` over ascending, disjoint cell ranges within `prefix`,
    /// loads the records, and keeps those `matches` accepts.
    ///
    /// The Record Layer's planner only uses one bound of a range, so spatial scans read the index directly, in the
    /// documented store layout `S / 2 / <index key> / <values...> / <primary key...>` (the Java Record Layer's).
    private func scanPage<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, subspaceKey: any TupleElement, prefix: [any TupleElement], valueRanges: [(Int64, Int64)],
        limits: SpatialScanLimits, continuation: SpatialContinuation?,
        candidate: ((Int64) -> Bool)? = nil,
        matches: (FDBStoredRecord<M>) -> Bool
    ) async throws -> SpatialPage<M> {
        let entries = subspace.child(Int64(2), subspaceKey)
        // A continuation is only meaningful for the query that made it: it carries a fingerprint of the query.
        var query = Bytes()
        query += Tuple(prefix).encode()
        for (lower, upper) in valueRanges {
            query.append(int: lower)
            query.append(int: upper)
        }
        let fingerprint = Self.fingerprint(query.bytes)
        var resumeAfter: FDB.Bytes?
        if let continuation {
            guard continuation.bytes.count > 8, Array(continuation.bytes.prefix(8)) == fingerprint else {
                throw TesseractError.invalidContinuation
            }
            resumeAfter = entries.prefix + continuation.bytes.dropFirst(8)
        }
        let columns = prefix.count + 1

        // Scan in batches, so a page that filters most candidates out still loads records concurrently.
        let batchSize = 64
        var found: [FDBStoredRecord<M>] = []
        var scanned = 0, skipped = 0
        var batch: [(key: FDB.Bytes, primaryKey: Tuple)] = []
        var seen = Set<FDB.Bytes>()

        /// Loads and filters a batch. Returns the key to continue after if the page filled up part-way.
        func flush() async throws -> FDB.Bytes? {
            defer { batch.removeAll(keepingCapacity: true) }
            let loaded = try await loadAll(M.self, batch.map(\.primaryKey))
            for (entry, stored) in zip(batch, loaded) {
                guard let stored, matches(stored), seen.insert(entry.primaryKey.encode()).inserted else { continue }
                found.append(stored)
                if limits.records > 0, found.count >= limits.records { return entry.key }
            }
            return nil
        }

        func page(continuingAfter key: FDB.Bytes?) -> SpatialPage<M> {
            SpatialPage(records: found, continuation: key.map { SpatialContinuation(bytes: fingerprint + $0.dropFirst(entries.prefix.count)) })
        }

        for (lower, upper) in valueRanges {
            var begin = entries.pack(Tuple(prefix + [lower]))
            let end = entries.pack(Tuple(prefix + [upper])) + [0xFF]
            if let resumeAfter {
                guard resumeAfter < end else { continue }
                begin = max(begin, resumeAfter + [0x00])
            }
            for try await (key, _) in context.transaction.getRange(beginKey: begin, endKey: end) {
                let elements = try entries.unpack(key)
                // Entries whose cell can't be in the region are skipped unloaded, and don't count as work done
                // beyond the cheap key read (bounded separately).
                if let candidate, let cell = elements[prefix.count] as? Int64, !candidate(cell) {
                    skipped += 1
                    if limits.entries > 0, skipped >= limits.entries * 16 {
                        return page(continuingAfter: try await flush() ?? key)
                    }
                    continue
                }
                batch.append((key, Tuple(Array(elements.dropFirst(columns)))))
                scanned += 1
                if batch.count >= batchSize, let stop = try await flush() {
                    return page(continuingAfter: stop)
                }
                if limits.entries > 0, scanned >= limits.entries {
                    return page(continuingAfter: try await flush() ?? key)
                }
            }
        }
        return page(continuingAfter: try await flush())
    }

    /// FNV-1a: stable across processes and platforms, unlike `Hasher`.
    private static func fingerprint(_ bytes: [UInt8]) -> [UInt8] {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return (0..<8).map { UInt8(truncatingIfNeeded: hash >> UInt64($0 * 8)) }
    }

    /// Loads records concurrently, keeping the order of `keys`; `nil` for any that are gone.
    func loadAll<M: SwiftProtobuf.Message & Sendable>(_ type: M.Type, _ keys: [Tuple]) async throws -> [FDBStoredRecord<M>?] {
        try await withThrowingTaskGroup(of: (Int, FDBStoredRecord<M>?).self) { group in
            var loaded = [FDBStoredRecord<M>?](repeating: nil, count: keys.count)
            var next = 0
            func launch() {
                guard next < keys.count else { return }
                let index = next, key = keys[index]
                next += 1
                group.addTask { (index, try await self.load(M.self, primaryKey: key)) }
            }
            for _ in 0..<32 { launch() }
            while let (index, stored) = try await group.next() {
                loaded[index] = stored
                launch()
            }
            return loaded
        }
    }
}

/// Where a nearest-first query got to: the ring `[inner, outer)` being read, and the last match handed out.
private struct NearestCursor {
    var inner: Double
    var outer: Double
    var after: (distance: Double, primaryKey: [UInt8])?

    /// Whether `match` comes after `(distance, primaryKey)` in nearest-first order.
    static func isAfter<M>(_ match: SpatialMatch<M>, _ after: (distance: Double, primaryKey: [UInt8])) -> Bool {
        let distance = match.distanceMeters!
        if distance != after.distance { return distance > after.distance }
        return after.primaryKey.lexicographicallyPrecedes(match.stored.primaryKey.encode())
    }

    init(inner: Double, outer: Double, after: (distance: Double, primaryKey: [UInt8])?) {
        self.inner = inner
        self.outer = outer
        self.after = after
    }

    init(decoding bytes: [UInt8], fingerprint: [UInt8]) throws {
        guard bytes.count >= 8 + 8 + 8 + 1, Array(bytes.prefix(8)) == fingerprint else {
            throw TesseractError.invalidContinuation
        }
        var reader = bytes.dropFirst(8)
        func double() throws -> Double {
            guard reader.count >= 8 else { throw TesseractError.invalidContinuation }
            let value = reader.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            reader = reader.dropFirst(8)
            return Double(bitPattern: value)
        }
        inner = try double()
        outer = try double()
        let hasAfter = reader.first == 1
        reader = reader.dropFirst()
        after = hasAfter ? (try double(), Array(reader)) : nil
        guard inner.isFinite, outer.isFinite, inner <= outer else { throw TesseractError.invalidContinuation }
    }

    func encoded(_ fingerprint: [UInt8]) -> [UInt8] {
        var bytes = Bytes()
        bytes.bytes = fingerprint
        bytes.append(double: inner)
        bytes.append(double: outer)
        if let after {
            bytes.bytes.append(1)
            bytes.append(double: after.distance)
            bytes.bytes += after.primaryKey
        } else {
            bytes.bytes.append(0)
        }
        return bytes.bytes
    }
}

/// A byte buffer for fingerprints and continuations.
private struct Bytes {
    var bytes: [UInt8] = []

    mutating func append(int value: Int64) {
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: value >> Int64(56 - $0 * 8)) }
    }

    mutating func append(double value: Double) {
        append(int: Int64(bitPattern: value.bitPattern))
    }

    static func += (lhs: inout Bytes, rhs: [UInt8]) {
        lhs.bytes += rhs
    }
}

/// A query that must read a whole region in one transaction found more index entries than it was allowed to read.
public struct SpatialScanLimitExceeded: Error, Sendable, Equatable {
    public let entries: Int
}

extension PointIndex {
    var subspaceKey: any TupleElement { key.map { Int64($0) } ?? name }
}

extension RegionIndex {
    var subspaceKey: any TupleElement { key.map { Int64($0) } ?? name }
}

extension Array where Element == UInt8 {
    static func < (a: [UInt8], b: [UInt8]) -> Bool { a.lexicographicallyPrecedes(b) }
}

private func max(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { a < b ? b : a }

extension FDBRecordVersion {
    /// The FoundationDB commit version that wrote the record (the versionstamp's first 8 bytes), comparable with
    /// read versions: a record is visible to a transaction reading at `v` exactly when `commitVersion <= v`.
    public var commitVersion: Int64 {
        globalVersion.prefix(8).reduce(0) { $0 << 8 | Int64($1) }
    }
}
