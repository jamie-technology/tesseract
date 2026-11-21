import Foundation
import Testing

@testable import TesseractGeometry

/// Values from s2sphere (a port of Google's S2), to check IDs are bit-for-bit compatible.
let reference: [(LatLng, UInt64, level15: String, level8: String)] = [
    (LatLng(latitude: 0, longitude: 0), 1_152_921_504_606_846_977, "100000004", "10001"),
    (LatLng(latitude: 51.5007, longitude: -0.1246), 5_221_366_058_900_800_963, "487604c44", "48761"),
    (LatLng(latitude: -33.8568, longitude: 151.2153), 7_715_420_867_172_409_887, "6b12ae66c", "6b12b"),
    (LatLng(latitude: 89.9, longitude: 10), 4_995_994_163_539_129_101, "45555638c", "45555"),
    (LatLng(latitude: -89.9, longitude: -170), 11_913_523_191_180_210_957, "a5555638c", "a5555"),
    (LatLng(latitude: 40.7484, longitude: -73.9857), 9_926_595_113_904_274_803, "89c259a9c", "89c25"),
    (LatLng(latitude: 0, longitude: 180), 8_070_450_532_247_928_831, "6fffffffc", "6ffff"),
    (LatLng(latitude: 35.6586, longitude: 139.7454), 6_924_438_073_539_270_971, "60188bbdc", "60189"),
]

/// Deterministic pseudorandom points, so failures reproduce.
struct Points: Sequence, IteratorProtocol {
    var state: UInt64
    mutating func next() -> LatLng? {
        func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        // Uniform on the sphere.
        return LatLng(latitude: asin(2 * unit() - 1) * 180 / .pi, longitude: unit() * 360 - 180)
    }
}

@Suite("S2 cell IDs")
struct CellIDTests {
    @Test("Leaf cells and tokens match S2", arguments: reference.indices)
    func matchesReference(index: Int) {
        let (latLng, id, level15, level8) = reference[index]
        let cell = S2CellID(latLng)
        #expect(cell.rawValue == id)
        #expect(cell.level == 30 && cell.isLeaf && cell.isValid)
        #expect(cell.parent(15).token == level15)
        #expect(cell.parent(8).token == level8)
        #expect(S2CellID(token: level15) == cell.parent(15))
    }

    @Test("Faces")
    func faces() {
        #expect(S2CellID(face: 0).token == "1")
        #expect(S2CellID(face: 1).token == "3")
        #expect(S2CellID(face: 5).token == "b")
        #expect(S2CellID(face: 3).isFace && S2CellID(face: 3).level == 0)
    }

    @Test("Points round-trip through (face, i, j)")
    func roundTrip() {
        for latLng in Points(state: 1).prefix(2000) {
            let cell = S2CellID(latLng)
            let (face, i, j) = cell.faceIJ()
            #expect(S2CellID(face: face, i: i, j: j) == cell)
            // A leaf cell is about a centimetre across.
            #expect(LatLng(S2Cell(cell).center).distance(to: latLng) < 0.02)
        }
    }

    @Test("Hierarchy: parents contain children, children tile the parent's range")
    func hierarchy() {
        for latLng in Points(state: 2).prefix(200) {
            let leaf = S2CellID(latLng)
            for level in [0, 5, 13, 22, 29] {
                let cell = leaf.parent(level)
                #expect(cell.level == level)
                #expect(cell.contains(leaf))
                let children = cell.children
                #expect(children.map(\.level) == Array(repeating: level + 1, count: 4))
                #expect(children.first!.rangeMin == cell.rangeMin)
                #expect(children.last!.rangeMax == cell.rangeMax)
                #expect(children.allSatisfy { $0.parent == cell })
                #expect(children.filter { $0.contains(leaf) }.count == 1)
            }
        }
    }

    @Test("Index keys keep ID order")
    func indexKeys() {
        let cells = Points(state: 3).prefix(500).map { S2CellID($0) }
        #expect(cells.sorted().map(\.indexKey) == cells.map(\.indexKey).sorted())
        #expect(cells.allSatisfy { S2CellID(indexKey: $0.indexKey) == $0 })
    }

    @Test("Cell geometry agrees with point lookup")
    func cellGeometry() {
        for latLng in Points(state: 4).prefix(300) {
            let cell = S2Cell(S2CellID(latLng, level: 12))
            #expect(cell.contains(latLng.point))
            #expect(cell.contains(cell.center))
            #expect(cell.distance(to: latLng.point) == 0)
            #expect(cell.capBound.contains(latLng.point))
            for vertex in cell.vertices { #expect(cell.capBound.contains(vertex)) }
        }
    }
}

@Suite("Coverings")
struct CoveringTests {
    @Test("Cap coverings contain every point of the cap", arguments: [50.0, 300, 5_000, 250_000])
    func capCoverings(radius: Double) {
        let coverer = S2RegionCoverer(minLevel: 4, maxLevel: 20, maxCells: 8)
        for centre in Points(state: UInt64(radius)).prefix(40) {
            let cap = S2Cap(center: centre, radiusMeters: radius)
            let covering = coverer.covering(cap)
            #expect(!covering.isEmpty)
            #expect(covering.allSatisfy { (4...20).contains($0.level) })
            // Points on and inside the boundary.
            for bearing in stride(from: 0.0, to: 360, by: 15) {
                for fraction in [0.0, 0.5, 0.999] {
                    let point = destination(from: centre, meters: radius * fraction, bearing: bearing)
                    let leaf = S2CellID(point)
                    #expect(covering.contains { $0.contains(leaf) }, "\(point) is outside the covering of \(cap)")
                }
            }
            // Sorted and disjoint.
            #expect(covering == covering.sorted())
            for (a, b) in zip(covering, covering.dropFirst()) { #expect(!a.intersects(b)) }
        }
    }

    @Test("Annulus coverings contain the ring and skip its middle")
    func annulusCoverings() {
        let coverer = S2RegionCoverer(minLevel: 6, maxLevel: 20, maxCells: 16)
        for centre in Points(state: 77).prefix(30) {
            let ring = S2Annulus(center: centre, innerRadiusMeters: 2_000, outerRadiusMeters: 3_000)
            let covering = coverer.covering(ring)
            for bearing in stride(from: 0.0, to: 360, by: 10) {
                for meters in [2_000.5, 2_500, 2_999.5] {
                    let point = destination(from: centre, meters: meters, bearing: bearing)
                    #expect(covering.contains { $0.contains(S2CellID(point)) })
                }
            }
            // With cells to spare, the hole isn't covered (with few cells, a big cell may straddle it: only a cost).
            let fine = S2RegionCoverer(minLevel: 6, maxLevel: 20, maxCells: 64).covering(ring)
            #expect(!fine.contains { $0.contains(S2CellID(centre)) }, "the centre is well inside the hole")
        }
    }

    @Test("Coverings are reasonably tight")
    func tightness() {
        let cap = S2Cap(center: LatLng(latitude: 51.5, longitude: -0.12), radiusMeters: 500)
        let covering = S2RegionCoverer(minLevel: 8, maxLevel: 18, maxCells: 12).covering(cap)
        // Area of the covering versus the cap's: a cell's area is ~ (its cap bound's radius)².
        let coveredArea = covering.map { pow(S2Cell($0).capBound.radiusMeters, 2) * 2 }.reduce(0, +)
        #expect(coveredArea < .pi * 500 * 500 * 8)
        #expect(covering.count <= 16)
    }

    @Test("Rectangle coverings, including across the antimeridian")
    func rectangles() {
        let rects = [
            S2LatLngRect(south: 51.4, west: -0.3, north: 51.6, east: 0.1),
            S2LatLngRect(south: -18, west: 177, north: -16, east: -179),
        ]
        for rect in rects {
            let covering = S2RegionCoverer(minLevel: 2, maxLevel: 16, maxCells: 10).covering(rect)
            for point in Points(state: 9).prefix(20_000) where rect.contains(point) {
                #expect(covering.contains { $0.contains(S2CellID(point)) })
            }
            for latitude in stride(from: rect.south, through: rect.north, by: 0.05) {
                for longitude in [rect.west, rect.east] {
                    let point = LatLng(latitude: latitude, longitude: longitude)
                    #expect(covering.contains { $0.contains(S2CellID(point)) })
                }
            }
        }
    }

    @Test("Leaf ranges merge adjacent cells")
    func leafRanges() {
        let parent = S2CellID(LatLng(latitude: 10, longitude: 10), level: 10)
        let ranges = S2RegionCoverer.leafRanges(of: parent.children)
        #expect(ranges == [parent.rangeMin...parent.rangeMax])
    }

    @Test("Normalising merges complete families")
    func normalising() {
        let parent = S2CellID(LatLng(latitude: -40, longitude: 60), level: 9)
        #expect(S2RegionCoverer.normalised(parent.children.reversed(), minLevel: 0) == [parent])
        #expect(S2RegionCoverer.normalised(parent.children, minLevel: 10) == parent.children)
    }
}

/// The point `meters` from `start` along `bearing` (degrees clockwise from north).
func destination(from start: LatLng, meters: Double, bearing: Double) -> LatLng {
    let delta = meters / Earth.radiusMeters, theta = bearing * .pi / 180
    let phi1 = start.latitude * .pi / 180, lambda1 = start.longitude * .pi / 180
    let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
    let lambda2 = lambda1 + atan2(sin(theta) * sin(delta) * cos(phi1), cos(delta) - sin(phi1) * sin(phi2))
    var longitude = lambda2 * 180 / .pi
    if longitude > 180 { longitude -= 360 }
    if longitude < -180 { longitude += 360 }
    return LatLng(latitude: phi2 * 180 / .pi, longitude: longitude)
}
