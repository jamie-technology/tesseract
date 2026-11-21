#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A cell's geometry: its four corners and centre on the sphere. Its edges are great-circle arcs.
public struct S2Cell: Hashable, Sendable {
    public let id: S2CellID
    /// Counter-clockwise, as unit vectors.
    public let vertices: [S2Point]
    public let center: S2Point

    public init(_ id: S2CellID) {
        self.id = id
        let (face, i, j) = id.faceIJ()
        let size = 1 << (S2CellID.maxLevel - id.level)
        let i0 = i & -size, j0 = j & -size
        func uv(_ ij: Int) -> Double { S2Projection.stToUV(Double(ij) / Double(S2CellID.maxSize)) }
        let u0 = uv(i0), u1 = uv(i0 + size), v0 = uv(j0), v1 = uv(j0 + size)
        vertices = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)].map { S2Projection.point(face: face, u: $0.0, v: $0.1).normalized }
        center = S2Projection.point(face: face, u: uv(i0 + size / 2), v: uv(j0 + size / 2)).normalized
    }

    public var level: Int { id.level }

    public func contains(_ point: S2Point) -> Bool {
        id.contains(S2CellID(point))
    }

    /// The smallest angle from `point` to anywhere in the cell, in radians: 0 inside.
    public func distance(to point: S2Point) -> Double {
        if contains(point) { return 0 }
        var best = Double.infinity
        for k in 0..<4 {
            best = min(best, Self.distance(from: point, toEdge: vertices[k], vertices[(k + 1) % 4]))
        }
        return best
    }

    /// A cap containing the whole cell.
    public var capBound: S2Cap {
        S2Cap(center: center, radius: vertices.map { center.angle(to: $0) }.max()! * (1 + 1e-12) + 1e-15)
    }

    /// The angle from `p` to the great-circle arc from `a` to `b`.
    static func distance(from p: S2Point, toEdge a: S2Point, _ b: S2Point) -> Double {
        let n = a.cross(b)
        if a.cross(p).dot(n) > 0, p.cross(b).dot(n) > 0 {
            // The nearest point is inside the arc: the distance is to the great circle itself.
            let sine = abs(p.dot(n.normalized))
            return asin(min(1, sine))
        }
        return min(p.angle(to: a), p.angle(to: b))
    }
}

/// An area of the sphere that can be covered with cells.
public protocol S2Region: Sendable {
    /// Whether the region contains the point.
    func contains(_ point: S2Point) -> Bool
    /// Whether the region certainly contains the whole cell. May say `false` for cells it does contain.
    func contains(_ cell: S2Cell) -> Bool
    /// Whether the region might intersect the cell. Must not say `false` for cells it intersects.
    func mayIntersect(_ cell: S2Cell) -> Bool
}

/// A spherical cap: everything within an angle of a centre. A circle on the map.
public struct S2Cap: S2Region, Hashable {
    public var center: S2Point
    /// The radius as an angle at Earth's centre, in radians.
    public var radius: Double

    public init(center: S2Point, radius: Double) {
        self.center = center.normalized
        self.radius = radius
    }

    public init(center: LatLng, radiusMeters: Double) {
        self.init(center: center.point, radius: Earth.radians(fromMeters: radiusMeters))
    }

    public var radiusMeters: Double { Earth.meters(fromRadians: radius) }

    public func contains(_ point: S2Point) -> Bool {
        center.angle(to: point) <= radius
    }

    public func contains(_ cell: S2Cell) -> Bool {
        // A cap no bigger than a hemisphere is convex, so containing the corners means containing the cell.
        radius < .pi / 2 && cell.vertices.allSatisfy(contains)
    }

    public func mayIntersect(_ cell: S2Cell) -> Bool {
        if radius >= .pi { return true }
        return cell.distance(to: center) <= radius * (1 + 1e-12) + 1e-15
    }
}

/// A latitude-longitude rectangle: a map viewport. Longitudes may wrap across the antimeridian (`west > east`).
public struct S2LatLngRect: S2Region, Hashable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    /// Degrees. A `west` greater than `east` spans the antimeridian.
    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    public func contains(_ latLng: LatLng) -> Bool {
        latLng.latitude >= south && latLng.latitude <= north && containsLongitude(latLng.longitude)
    }

    public func contains(_ point: S2Point) -> Bool {
        contains(LatLng(point))
    }

    public func contains(_ cell: S2Cell) -> Bool {
        // Cell edges are great circles, which bulge towards the poles; the cell's cap bound is conservative.
        let bound = cell.capBound.latLngBound
        return contains(bound)
    }

    public func mayIntersect(_ cell: S2Cell) -> Bool {
        if contains(LatLng(cell.center)) { return true }
        return intersects(cell.capBound.latLngBound)
    }

    func containsLongitude(_ longitude: Double) -> Bool {
        west <= east ? (longitude >= west && longitude <= east) : (longitude >= west || longitude <= east)
    }

    var isFullLongitude: Bool { west == -180 && east == 180 }

    func contains(_ other: S2LatLngRect) -> Bool {
        guard other.south >= south, other.north <= north else { return false }
        if isFullLongitude { return true }
        if other.isFullLongitude { return false }
        // Going east from the other's west edge, this rectangle must last at least as long as the other does.
        guard containsLongitude(other.west) else { return false }
        var remaining = (east - other.west).truncatingRemainder(dividingBy: 360)
        if remaining < 0 { remaining += 360 }
        return remaining >= other.longitudeSpan
    }

    func intersects(_ other: S2LatLngRect) -> Bool {
        guard other.south <= north, other.north >= south else { return false }
        if isFullLongitude || other.isFullLongitude { return true }
        return containsLongitude(other.west) || containsLongitude(other.east)
            || other.containsLongitude(west) || other.containsLongitude(east)
    }

    var longitudeSpan: Double {
        west <= east ? east - west : 360 - (west - east)
    }
}

extension S2Cap {
    /// A latitude-longitude rectangle containing the cap.
    public var latLngBound: S2LatLngRect {
        let centre = LatLng(center)
        let radiusDegrees = radius * 180 / .pi
        let south = centre.latitude - radiusDegrees, north = centre.latitude + radiusDegrees
        if south <= -90 || north >= 90 || radius >= .pi / 2 {
            return S2LatLngRect(south: max(-90, south), west: -180, north: min(90, north), east: 180)
        }
        // The cap's widest point in longitude, from spherical trigonometry.
        let dLng = asin(sin(radius) / cos(centre.latitude * .pi / 180)) * 180 / .pi
        var west = centre.longitude - dLng, east = centre.longitude + dLng
        if west < -180 { west += 360 }
        if east > 180 { east -= 360 }
        return S2LatLngRect(south: south, west: west, north: north, east: east)
    }
}

/// A ring: everything at least `innerRadius` and at most `outerRadius` from a centre (angles in radians). A
/// distance band, for reading nearest-first in pieces.
public struct S2Annulus: S2Region, Hashable {
    public var center: S2Point
    public var innerRadius: Double
    public var outerRadius: Double

    public init(center: S2Point, innerRadius: Double, outerRadius: Double) {
        self.center = center.normalized
        self.innerRadius = max(0, innerRadius)
        self.outerRadius = outerRadius
    }

    public init(center: LatLng, innerRadiusMeters: Double, outerRadiusMeters: Double) {
        self.init(
            center: center.point, innerRadius: Earth.radians(fromMeters: innerRadiusMeters),
            outerRadius: Earth.radians(fromMeters: outerRadiusMeters)
        )
    }

    public func contains(_ point: S2Point) -> Bool {
        let angle = center.angle(to: point)
        return angle >= innerRadius && angle <= outerRadius
    }

    public func contains(_ cell: S2Cell) -> Bool {
        // Inside the outer cap, and nowhere nearer than the inner radius.
        S2Cap(center: center, radius: outerRadius).contains(cell) && cell.distance(to: center) >= innerRadius
    }

    public func mayIntersect(_ cell: S2Cell) -> Bool {
        guard S2Cap(center: center, radius: outerRadius).mayIntersect(cell) else { return false }
        if innerRadius == 0 { return true }
        // The cell reaches beyond the inner cap unless all of it is inside: for a cell no bigger than a
        // hemisphere the furthest point from the centre is a vertex.
        return cell.vertices.contains { center.angle(to: $0) >= innerRadius * (1 - 1e-12) }
    }
}
