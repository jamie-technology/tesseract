import FDBRecordLayer
import Foundation
import FoundationDB
import SwiftProtobuf
import Testing

@testable import Tesseract

actor Bootstrap {
    static let shared = Bootstrap()
    private var database: (FDBDatabase)?

    func open() async throws -> FDBDatabase {
        if let database { return database }
        if !FDBClient.isInitialized { try await FDBClient.initialize() }
        let opened = try FDBClient.openDatabase()
        database = opened
        return opened
    }
}

let placeLocation = PointIndex<TesseractTest_Place>(name: "place.location", key: 101, cell: \.cell) {
    LatLng(latitude: $0.latitude, longitude: $0.longitude)
}

let zoneArea = RegionIndex<TesseractTest_Zone>(name: "zone.area", key: 201, coverage: \.coverage, levels: 8...18) {
    zone, point in zone.center.distance(to: point) <= zone.radiusMeters
}

extension TesseractTest_Zone {
    var center: LatLng { LatLng(latitude: latitude, longitude: longitude) }
}

let metaData = RecordMetaData(version: 1) {
    RecordType(TesseractTest_Place.self, key: 1, primaryKey: \.id).index(placeLocation)
    RecordType(TesseractTest_Zone.self, key: 2, primaryKey: \.id).index(zoneArea)
}

/// A store at a fresh path, cleared afterwards.
func withStore<T: Sendable>(_ body: (FDBDatabase, KeySpacePath) async throws -> T) async throws -> T {
    let database = try await Bootstrap.shared.open()
    let path = KeySpacePath("tesseract-tests").child(UUID().uuidString)
    let (begin, end) = path.toSubspace().range
    do {
        let result = try await body(database, path)
        try await database.withTransaction { $0.clearRange(beginKey: begin, endKey: end) }
        return result
    } catch {
        try? await database.withTransaction { $0.clearRange(beginKey: begin, endKey: end) }
        throw error
    }
}

func open(_ context: FDBRecordContext, _ path: KeySpacePath) async throws -> FDBRecordStore {
    try await FDBRecordStore.open(context: context, path: path, metaData: metaData)
}

/// Deterministic pseudorandom numbers, so failures reproduce.
struct Random {
    var state: UInt64
    mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func near(_ centre: LatLng, degrees: Double) -> LatLng {
        LatLng(latitude: centre.latitude + (unit() * 2 - 1) * degrees, longitude: centre.longitude + (unit() * 2 - 1) * degrees)
    }
}

let london = LatLng(latitude: 51.5074, longitude: -0.1278)

func places(_ count: Int, seed: UInt64) -> [TesseractTest_Place] {
    var random = Random(state: seed)
    return (0..<count).map { n in
        let at = random.near(london, degrees: 0.15)
        return TesseractTest_Place.with {
            $0.id = "p\(n)"
            $0.latitude = at.latitude
            $0.longitude = at.longitude
            $0.cell = placeLocation.cellKey(for: at)
        }
    }
}

func zones(_ count: Int, seed: UInt64) -> [TesseractTest_Zone] {
    var random = Random(state: seed)
    return (0..<count).map { n in
        let at = random.near(london, degrees: 0.15)
        let radius = 150 + random.unit() * 3_000
        return TesseractTest_Zone.with {
            $0.id = "z\(n)"
            $0.latitude = at.latitude
            $0.longitude = at.longitude
            $0.radiusMeters = radius
            $0.coverage = zoneArea.coverage(of: S2Cap(center: at, radiusMeters: radius))
        }
    }
}

@Suite("Spatial indexes")
struct SpatialIndexTests {
    @Test("Points in a circle match a brute-force search", arguments: [100.0, 1_000, 5_000, 20_000])
    func pointsInCircle(radius: Double) async throws {
        let all = places(600, seed: 7)
        try await withStore { database, path in
            try await database.withRecordContext { context in
                let store = try await open(context, path)
                for place in all { _ = try await store.save(place) }
            }
            var random = Random(state: UInt64(radius))
            for _ in 0..<5 {
                let centre = random.near(london, degrees: 0.1)
                let found = try await database.withRecordContext { context in
                    try await open(context, path).records(within: radius, of: centre, using: placeLocation)
                }
                let expected = all.filter { placeLocation.location($0).distance(to: centre) <= radius }
                #expect(Set(found.map(\.record.id)) == Set(expected.map(\.id)))
                #expect(found.map(\.distanceMeters!) == found.map(\.distanceMeters!).sorted())
            }
        }
    }

    @Test("Nearest neighbours match a brute-force search")
    func nearest() async throws {
        let all = places(400, seed: 11)
        try await withStore { database, path in
            try await database.withRecordContext { context in
                let store = try await open(context, path)
                for place in all { _ = try await store.save(place) }
            }
            let centre = LatLng(latitude: 51.52, longitude: -0.1)
            let found = try await database.withRecordContext { context in
                try await open(context, path).nearest(10, to: centre, within: 50_000, using: placeLocation)
            }
            let expected = all.sorted {
                placeLocation.location($0).distance(to: centre) < placeLocation.location($1).distance(to: centre)
            }.prefix(10)
            #expect(found.map(\.record.id) == expected.map(\.id))
        }
    }

    @Test("Geofence membership matches a brute-force search")
    func containing() async throws {
        let all = zones(300, seed: 3)
        try await withStore { database, path in
            try await database.withRecordContext { context in
                let store = try await open(context, path)
                for zone in all { _ = try await store.save(zone) }
            }
            var random = Random(state: 99)
            for _ in 0..<40 {
                let point = random.near(london, degrees: 0.12)
                let found = try await database.withRecordContext { context in
                    try await open(context, path).records(containing: point, using: zoneArea).records
                }
                let expected = all.filter { $0.center.distance(to: point) <= $0.radiusMeters }
                #expect(Set(found.map(\.record.id)) == Set(expected.map(\.id)))
            }
        }
    }

    @Test("Areas intersecting a region include every area that really does")
    func intersecting() async throws {
        let all = zones(300, seed: 5)
        try await withStore { database, path in
            try await database.withRecordContext { context in
                let store = try await open(context, path)
                for zone in all { _ = try await store.save(zone) }
            }
            let query = S2Cap(center: london, radiusMeters: 2_000)
            let found = try await database.withRecordContext { context in
                try await open(context, path).records(intersecting: query, using: zoneArea).records
            }
            let ids = Set(found.map(\.record.id))
            let expected = all.filter { $0.center.distance(to: london) <= $0.radiusMeters + 2_000 }
            #expect(Set(expected.map(\.id)).isSubset(of: ids))
            #expect(ids.count < all.count)
        }
    }

    @Test("A spatial join pairs points with the areas containing them")
    func join() async throws {
        let somePlaces = places(150, seed: 21), someZones = zones(80, seed: 22)
        try await withStore { database, path in
            try await database.withRecordContext { context in
                let store = try await open(context, path)
                for place in somePlaces { _ = try await store.save(place) }
                for zone in someZones { _ = try await store.save(zone) }
            }
            let region = S2Cap(center: london, radiusMeters: 6_000)
            let pairs = try await database.withRecordContext { context in
                try await open(context, path).join(placeLocation, with: zoneArea, in: region, limits: .unlimited).pairs
                    .map { ($0.point.record.id, Set($0.areas.map(\.record.id))) }
            }
            for (placeID, zoneIDs) in pairs {
                let place = somePlaces.first { $0.id == placeID }!
                let expected = someZones.filter { $0.center.distance(to: placeLocation.location(place)) <= $0.radiusMeters }
                #expect(zoneIDs == Set(expected.map(\.id)))
            }
            #expect(pairs.count == somePlaces.filter { region.contains(placeLocation.location($0).point) }.count)
        }
    }

    @Test("A geofence added under a membership check makes the check's transaction conflict")
    func membershipIsSerialisable() async throws {
        try await withStore { database, path in
            let point = LatLng(latitude: 51.5, longitude: -0.12)
            // Make sure the store exists, so opening it below only reads.
            try await database.withRecordContext { context in _ = try await open(context, path) }

            // T1 checks which zones contain the point, and (finding none) decides to write something.
            let first = FDBRecordContext(transaction: try database.createTransaction())
            let store = try await open(first, path)
            #expect(try await store.records(containing: point, using: zoneArea).records.isEmpty)
            _ = try await store.save(TesseractTest_Place.with { $0.id = "decided-on-empty"; $0.cell = placeLocation.cellKey(for: point) })

            // Meanwhile T2 adds a zone around the point, and commits first.
            try await database.withRecordContext { context in
                _ = try await open(context, path).save(TesseractTest_Zone.with {
                    $0.id = "late"
                    $0.latitude = point.latitude
                    $0.longitude = point.longitude
                    $0.radiusMeters = 500
                    $0.coverage = zoneArea.coverage(of: S2Cap(center: point, radiusMeters: 500))
                })
            }

            // T1's answer is stale, so it must not commit.
            let error = await #expect(throws: FDBError.self) { _ = try await first.commit() }
            #expect(error?.code == 1020)
        }
    }

    @Test("A geofence elsewhere does not conflict")
    func unrelatedWritesDoNotConflict() async throws {
        try await withStore { database, path in
            let point = LatLng(latitude: 51.5, longitude: -0.12)
            try await database.withRecordContext { context in _ = try await open(context, path) }

            let first = FDBRecordContext(transaction: try database.createTransaction())
            let store = try await open(first, path)
            _ = try await store.records(containing: point, using: zoneArea)
            _ = try await store.save(TesseractTest_Place.with { $0.id = "x"; $0.cell = placeLocation.cellKey(for: point) })

            let far = LatLng(latitude: 48.85, longitude: 2.35)  // Paris
            try await database.withRecordContext { context in
                _ = try await open(context, path).save(TesseractTest_Zone.with {
                    $0.id = "paris"
                    $0.latitude = far.latitude
                    $0.longitude = far.longitude
                    $0.radiusMeters = 500
                    $0.coverage = zoneArea.coverage(of: S2Cap(center: far, radiusMeters: 500))
                })
            }
            #expect(try await first.commit())
        }
    }

    @Test("Many records at one location, paged across transactions, with a boundary inside one cell")
    func pagingSameLocation() async throws {
        let spot = LatLng(latitude: 51.5, longitude: -0.12)
        let stacked = (0..<250).map { n in
            TesseractTest_Place.with {
                $0.id = String(format: "same-%03d", n)
                $0.latitude = spot.latitude
                $0.longitude = spot.longitude
                $0.cell = placeLocation.cellKey(for: spot)
            }
        }
        let scattered = places(300, seed: 31)
        try await withStore { database, path in
            try await database.withRecordContext { context in
                let store = try await open(context, path)
                for place in stacked + scattered { _ = try await store.save(place) }
            }
            let region = S2Cap(center: spot, radiusMeters: 3_000)
            for limits in [SpatialScanLimits(records: 7, entries: 0), SpatialScanLimits(records: 0, entries: 13), SpatialScanLimits(records: 40, entries: 25)] {
                var ids: [String] = []
                var continuation: SpatialContinuation?
                var pages = 0
                repeat {
                    let page = try await database.withRecordContext { context in
                        try await open(context, path).records(in: region, using: placeLocation, limits: limits, continuation: continuation)
                    }
                    if limits.records > 0 { #expect(page.records.count <= limits.records) }
                    ids += page.records.map(\.record.id)
                    continuation = page.continuation
                    pages += 1
                } while continuation != nil
                let expected = (stacked + scattered).filter { region.contains(placeLocation.location($0).point) }
                #expect(ids.count == expected.count, "no record repeated or skipped with \(limits)")
                #expect(Set(ids) == Set(expected.map(\.id)))
                #expect(pages > 5)
            }
        }
    }

    @Test("A continuation from one query is refused by another")
    func continuationBelongsToItsQuery() async throws {
        try await withStore { database, path in
            try await database.withRecordContext { context in
                let store = try await open(context, path)
                for place in places(100, seed: 41) { _ = try await store.save(place) }
            }
            let page = try await database.withRecordContext { context in
                try await open(context, path).records(in: S2Cap(center: london, radiusMeters: 20_000), using: placeLocation,
                                                      limits: SpatialScanLimits(records: 5))
            }
            let continuation = try #require(page.continuation)
            await #expect(throws: TesseractError.invalidContinuation) {
                try await database.withRecordContext { context in
                    _ = try await open(context, path).records(in: S2Cap(center: london, radiusMeters: 5_000), using: placeLocation,
                                                              continuation: continuation)
                }
            }
        }
    }

    @Test("Filters see record versions: a query at a snapshot ignores later records")
    func versionFilter() async throws {
        let schemaWithVersions = RecordMetaData(version: 1) {
            RecordType(TesseractTest_Place.self, key: 1, primaryKey: \.id).index(placeLocation).storingVersions()
            RecordType(TesseractTest_Zone.self, key: 2, primaryKey: \.id).index(zoneArea).storingVersions()
        }
        let point = LatLng(latitude: 51.5, longitude: -0.12)
        func zone(_ id: String) -> TesseractTest_Zone {
            TesseractTest_Zone.with {
                $0.id = id
                $0.latitude = point.latitude
                $0.longitude = point.longitude
                $0.radiusMeters = 300
                $0.coverage = zoneArea.coverage(of: S2Cap(center: point, radiusMeters: 300))
            }
        }
        try await withStore { database, path in
            func store(_ context: FDBRecordContext) async throws -> FDBRecordStore {
                try await FDBRecordStore.open(context: context, path: path, metaData: schemaWithVersions)
            }
            try await database.withRecordContext { _ = try await store($0).save(zone("early")) }
            let snapshot = try await database.withRecordContext { try await $0.transaction.getReadVersion() }
            try await database.withRecordContext { _ = try await store($0).save(zone("late")) }

            let atSnapshot = try await database.withRecordContext { context in
                try await store(context).records(containing: point, using: zoneArea) { stored in
                    (stored.version?.commitVersion ?? .max) <= snapshot
                }.records.map(\.record.id)
            }
            #expect(atSnapshot == ["early"])
        }
    }
}
