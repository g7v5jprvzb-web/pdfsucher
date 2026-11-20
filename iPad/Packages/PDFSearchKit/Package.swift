// swift-tools-version: 6.0
// Eigenständiges Kernpaket der iPad-App „PDF Search“.
// Kopie von IndexKit/SearchKit/OCRKit/MediaKit aus PDFSucherKit (Stand 1.4.2),
// für iOS angepasst. Keine Abhängigkeit vom Mac-Paket.
import PackageDescription

let package = Package(
    name: "PDFSearchKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "IndexKit", targets: ["IndexKit"]),
        .library(name: "SearchKit", targets: ["SearchKit"]),
        .library(name: "OCRKit", targets: ["OCRKit"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
    ],
    targets: [
        .target(name: "IndexKit"),
        .target(name: "SearchKit", dependencies: ["IndexKit"]),
        .target(name: "OCRKit", dependencies: ["IndexKit"]),
        .target(name: "MediaKit", dependencies: ["IndexKit"]),
        .target(name: "TestSupport"),
        .testTarget(name: "IndexKitTests", dependencies: ["TestSupport", "IndexKit"]),
        .testTarget(name: "SearchKitTests", dependencies: ["TestSupport", "SearchKit", "IndexKit"]),
        .testTarget(name: "OCRKitTests", dependencies: ["TestSupport", "OCRKit", "IndexKit", "SearchKit"]),
        .testTarget(name: "MediaKitTests", dependencies: ["TestSupport", "MediaKit", "IndexKit"]),
    ],
    swiftLanguageModes: [.v6]
)
