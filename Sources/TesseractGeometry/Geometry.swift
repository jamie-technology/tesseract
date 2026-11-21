#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A point on the unit sphere (or any vector in ℝ³).
public struct S2Point: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func + (a: S2Point, b: S2Point) -> S2Point { S2Point(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    public static func - (a: S2Point, b: S2Point) -> S2Point { S2Point(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    public static func * (a: S2Point, k: Double) -> S2Point { S2Point(x: a.x * k, y: a.y * k, z: a.z * k) }

    public func dot(_ other: S2Point) -> Double { x * other.x + y * other.y + z * other.z }

    public func cross(_ other: S2Point) -> S2Point {
        S2Point(x: y * other.z - z * other.y, y: z * other.x - x * other.z, z: x * other.y - y * other.x)
    }

    public var norm: Double { dot(self).squareRoot() }

    public var normalized: S2Point {
        let n = norm
        return n == 0 ? self : self * (1 / n)
    }

    /// The angle between two directions, in radians. Accurate for tiny and near-antipodal angles alike.
    public func angle(to other: S2Point) -> Double {
        atan2(cross(other).norm, dot(other))
    }
}

/// A latitude and longitude in degrees (WGS 84, treated as a sphere).
public struct LatLng: Hashable, Sendable, CustomStringConvertible {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ point: S2Point) {
        latitude = atan2(point.z, (point.x * point.x + point.y * point.y).squareRoot()) * 180 / .pi
        longitude = atan2(point.y, point.x) * 180 / .pi
    }

    /// Latitude within ±90°, longitude within ±180°, neither NaN.
    public var isValid: Bool {
        abs(latitude) <= 90 && abs(longitude) <= 180
    }

    public var point: S2Point {
        let phi = latitude * .pi / 180, theta = longitude * .pi / 180
        let cosPhi = cos(phi)
        return S2Point(x: cos(theta) * cosPhi, y: sin(theta) * cosPhi, z: sin(phi))
    }

    /// Great-circle distance in metres.
    public func distance(to other: LatLng) -> Double {
        Earth.meters(fromRadians: point.angle(to: other.point))
    }

    public var description: String { "(\(latitude), \(longitude))" }
}

/// Earth as a sphere of mean radius.
public enum Earth {
    public static let radiusMeters = 6_371_008.8

    public static func radians(fromMeters meters: Double) -> Double { meters / radiusMeters }
    public static func meters(fromRadians radians: Double) -> Double { radians * radiusMeters }
}

/// The quadratic projection from cube faces to the sphere, as S2 defines it.
enum S2Projection {
    static func face(of p: S2Point) -> Int {
        let ax = abs(p.x), ay = abs(p.y), az = abs(p.z)
        var face = ax > ay ? (ax > az ? 0 : 2) : (ay > az ? 1 : 2)
        let component = face == 0 ? p.x : face == 1 ? p.y : p.z
        if component < 0 { face += 3 }
        return face
    }

    static func uv(of p: S2Point, onFace face: Int) -> (u: Double, v: Double) {
        switch face {
        case 0: (p.y / p.x, p.z / p.x)
        case 1: (-p.x / p.y, p.z / p.y)
        case 2: (-p.x / p.z, -p.y / p.z)
        case 3: (p.z / p.x, p.y / p.x)
        case 4: (p.z / p.y, -p.x / p.y)
        default: (-p.y / p.z, -p.x / p.z)
        }
    }

    static func point(face: Int, u: Double, v: Double) -> S2Point {
        switch face {
        case 0: S2Point(x: 1, y: u, z: v)
        case 1: S2Point(x: -u, y: 1, z: v)
        case 2: S2Point(x: -u, y: -v, z: 1)
        case 3: S2Point(x: -1, y: -v, z: -u)
        case 4: S2Point(x: v, y: -1, z: -u)
        default: S2Point(x: v, y: u, z: -1)
        }
    }

    static func stToUV(_ s: Double) -> Double {
        s >= 0.5 ? (1.0 / 3.0) * (4 * s * s - 1) : (1.0 / 3.0) * (1 - 4 * (1 - s) * (1 - s))
    }

    static func uvToST(_ u: Double) -> Double {
        u >= 0 ? 0.5 * (1 + 3 * u).squareRoot() : 1 - 0.5 * (1 - 3 * u).squareRoot()
    }

    static func stToIJ(_ s: Double) -> Int {
        max(0, min(S2CellID.maxSize - 1, Int((Double(S2CellID.maxSize) * s).rounded(.down))))
    }
}
