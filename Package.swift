// swift-tools-version: 6.4
import PackageDescription

// Tesseract: a spatial layer for FoundationDB's Record Layer.
//
// - TesseractGeometry: S2 geometry in pure Swift (cell IDs on the Hilbert curve, caps, rectangles, region
//   coverings). No dependencies, so apps can use it too.
// - Tesseract: spatial indexes on Record Layer stores. Points are indexed by their leaf cell in an ordinary value
//   index and found with range scans over a covering; regions (geofences) are indexed by their covering cells in a
//   fan-out index and found by a point's ancestors. Scans run inside the record context's transaction, so they
//   take part in its conflict checking: spatial reads are serialisable like any other.
let package = Package(
    name: "Tesseract",
    platforms: [.macOS("26.2"), .iOS("26.0")],
    products: [
        .library(name: "TesseractGeometry", targets: ["TesseractGeometry"]),
        .library(name: "Tesseract", targets: ["Tesseract"]),
    ],
    dependencies: [
        .package(url: "https://github.com/itspolly/fdb-swift-bindings.git", branch: "main", traits: ["RecordLayer"]),
        .package(url: "https://github.com/apple/swift-protobuf.git", branch: "main"),
    ],
    targets: [
        .target(name: "TesseractGeometry", swiftSettings: swiftSettings),
        .target(
            name: "Tesseract",
            dependencies: [
                "TesseractGeometry",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "FDBRecordLayer", package: "fdb-swift-bindings"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "TesseractGeometryTests", dependencies: ["TesseractGeometry"], swiftSettings: swiftSettings),
        .testTarget(
            name: "TesseractTests",
            dependencies: [
                "Tesseract",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "FDBRecordLayer", package: "fdb-swift-bindings"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: fdbLinkerSettings,
            plugins: [.plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf")]
        ),
    ]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]
}

// macOS: libfdb_c.dylib is installed in /usr/local/lib without a pkg-config file. Only the tests link it; libraries
// leave linking to the executable that uses them.
var fdbLinkerSettings: [LinkerSetting] {
    [.unsafeFlags(["-L/usr/local/lib", "-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"], .when(platforms: [.macOS]))]
}
