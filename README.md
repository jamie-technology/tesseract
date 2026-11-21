# Tesseract

Spatial indexing for the [FoundationDB Record Layer in Swift](https://github.com/itspolly/fdb-swift-bindings): S2 cells over ordered keys, inside serialisable transactions.

- **TesseractGeometry**: S2 geometry in pure Swift, with no dependencies, so apps can use it too.
  - Cell IDs on the Hilbert curve, bit-for-bit compatible with Google's S2 and checked against a reference implementation.
  - Caps (circles) and latitude-longitude rectangles, including ones that cross the antimeridian.
  - A region coverer.
- **Tesseract**: spatial indexes on Record Layer stores.

## Requirements

- Swift 6.4 (tools version 6.4), macOS 26.2 or iOS 26.
- `Tesseract` needs the FoundationDB client library (`libfdb_c`) where the executable that uses it links. `TesseractGeometry` has no dependencies.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/itspolly/tesseract.git", branch: "main"),
],
targets: [
    .target(name: "MyService", dependencies: [
        .product(name: "Tesseract", package: "tesseract"),          // spatial indexes (pulls in the Record Layer)
        // .product(name: "TesseractGeometry", package: "tesseract"), // geometry only, e.g. in an app
    ]),
]
```

`Tesseract` re-exports `TesseractGeometry`. On macOS the FoundationDB client installs `libfdb_c.dylib` in `/usr/local/lib` without a pkg-config file, so executables add `-L/usr/local/lib` and an rpath to it (see this package's test target).

## Geometry

```swift
import TesseractGeometry

let cell = S2CellID(LatLng(latitude: 51.5007, longitude: -0.1246), level: 15)
cell.token                       // "487604c44"
cell.parent(8).contains(cell)    // true

let circle = S2Cap(center: LatLng(latitude: 51.5, longitude: -0.12), radiusMeters: 500)
let covering = S2RegionCoverer(minLevel: 8, maxLevel: 18, maxCells: 12).covering(circle)
```

## Indexes

**Points** (`PointIndex`) store their leaf cell in an `int64` field under an ordinary value index. `S2CellID.indexKey` flips the sign bit, so signed order matches cell order. A region query covers the region with cells, range-scans each cell's leaf IDs in the index, and checks every candidate's exact location.

```swift
let placeLocation = PointIndex<Place>(name: "place.location", key: 201, cell: \.cell) {
    LatLng(latitude: $0.latitude, longitude: $0.longitude)
}
RecordType(Place.self, key: 2, primaryKey: \.id).index(placeLocation)

place.cell = placeLocation.cellKey(for: location)
```

**Areas**, such as geofences (`RegionIndex`), store the cells covering them in a repeated `int64` field under a fan-out index. "Which areas contain this point?" reads the point's ancestor cell at each level in the index's level range. A point lies in at most one cell of any covering, so each area turns up once. Candidates are then checked with your exact `contains`.

```swift
let zoneArea = RegionIndex<Zone>(name: "zone.area", key: 301, coverage: \.coverage, levels: 8...18) { zone, point in
    zone.center.distance(to: point) <= zone.radiusMeters
}
zone.coverage = zoneArea.coverage(of: S2Cap(center: centre, radiusMeters: 250))
```

### Composite indexes

Both kinds take an equality **prefix**: key expressions placed before the cell, so the index is
`(prefix…, cell)`. A query fixes the prefix, and its cell ranges are read inside it, so the scan
narrows rather than filters. "Alice's places near here" reads only Alice's entries:

```swift
let placeByOwner = PointIndex<Place>(name: "place.owner-location", key: 202, prefix: [.field(\.owner)],
                                     cell: \.cell) { LatLng(latitude: $0.latitude, longitude: $0.longitude) }

try await store.records(in: S2Cap(center: here, radiusMeters: 2_000), using: placeByOwner, prefix: ["alice"])
```

Prefix columns can't fan out, and every query must give a value for each (otherwise
`TesseractError.prefixMismatch`). Ranges on another column (`price < 10 AND within(cap)`) still
belong in a `where:` filter: index keys are ordered by one range column at most.

## Queries

On an open `FDBRecordStore`:

| | |
|---|---|
| `records(in:using:limits:continuation:where:)` | points in any `S2Region`, a page at a time |
| `records(within:of:using:)` | points within a distance, nearest first |
| `nearest(_:to:within:using:)` | k nearest, in one transaction |
| `nearest(to:using:within:pageSize:continuation:)` | nearest first, a page per transaction |
| `records(containing:using:…)` | areas containing a point (geofence membership) |
| `records(intersecting:using:…)` | areas whose covering meets a region's (a superset) |
| `join(_:with:in:)` | points paired with the areas containing them |

**Consistency.** Scans read the index inside the record context's transaction, so the ranges they read become read conflicts. If another transaction adds an area containing your point while you decide something based on membership, your commit fails with `not_committed` and the retry loop runs again. Spatial reads are serialisable like any other.

**Pagination.** Transactions must finish within five seconds, so queries over dense areas read a page per transaction.
- `SpatialScanLimits` bounds both results and index entries read, so the work per page is bounded even when filters reject most candidates.
- Pages follow index order, `(cell, primary key)`, which is total. The continuation is the last entry read (keyset pagination), so records sharing a cell are never skipped or repeated.
- A continuation carries a fingerprint of its query and is refused by any other.
- Each page is consistent; a sequence of pages is not a single snapshot.
- **Nearest first** is paged in rings. Each ring is read whole and sorted by `(distance, primary key)`, then handed out a page at a time. The continuation records the ring and the last match.
  - Rings double in width as the query moves out.
  - A ring with more candidates than the budget is halved until it fits.
  - More records than the budget at exactly one distance can't be split, so that ring is read whole.
- Point queries test each index entry's leaf cell against the region before loading its record. Over-covered entries cost one key read, not a record load, and only candidates count towards `SpatialScanLimits.entries`.

**Filters.** `where:` sees the stored record, including its version, before the limit counts it. For example, `{ $0.version!.commitVersion <= snapshot }` queries "as of" a database version, which is how Wavefinder replays journeys. The filter is applied after the scan: index keys are ordered by cell, so only one dimension can be a range.

**How the scan works.** The Record Layer's planner only uses one bound of a range, so Tesseract reads index entries directly, using the store layout the bindings document (`S / 2 / <index key> / <value> / <primary key…>`, the Java Record Layer's).

## Tests

`swift test`. The `TesseractTests` suite needs a local FoundationDB. It writes under `("tesseract-tests", <uuid>)` and clears what it writes.

## Not yet

- Polygons.
- Exact intersection tests for `records(intersecting:)`.

## License

MIT. See [LICENSE](LICENSE).
