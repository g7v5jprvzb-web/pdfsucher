// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFSucherKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "IndexKit", targets: ["IndexKit"]),
        .library(name: "SearchKit", targets: ["SearchKit"]),
        .library(name: "OutputKit", targets: ["OutputKit"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "ViewerUI", targets: ["ViewerUI"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .library(name: "OCRKit", targets: ["OCRKit"]),
    ],
    targets: [
        .target(name: "IndexKit"),
        .target(name: "SearchKit", dependencies: ["IndexKit"]),
        .target(name: "OutputKit", dependencies: ["IndexKit"]),
        .target(name: "MediaKit", dependencies: ["IndexKit"]),
        .target(name: "ViewerUI", dependencies: ["SearchKit", "OutputKit", "MediaKit"]),
        .target(name: "AppCore", dependencies: ["IndexKit", "SearchKit", "OutputKit", "ViewerUI", "OCRKit", "MediaKit"]),
        .target(name: "TestSupport"),
        .target(name: "OCRKit", dependencies: ["IndexKit"]),
        .testTarget(name: "IndexKitTests", dependencies: ["TestSupport", "IndexKit"]),
        .testTarget(name: "OCRKitTests", dependencies: ["TestSupport", "OCRKit", "IndexKit", "SearchKit"]),
        .testTarget(name: "SearchKitTests", dependencies: ["TestSupport", "SearchKit", "IndexKit"]),
        .testTarget(name: "MediaKitTests", dependencies: ["TestSupport", "MediaKit", "IndexKit"]),
        .testTarget(name: "OutputKitTests", dependencies: ["TestSupport", "OutputKit"]),
        .testTarget(name: "AppCoreTests", dependencies: ["TestSupport", "AppCore", "IndexKit", "SearchKit", "OutputKit", "ViewerUI"]),
        .testTarget(name: "ViewerUITests", dependencies: ["TestSupport", "ViewerUI", "SearchKit", "OutputKit", "OCRKit", "IndexKit"]),
    ],
    swiftLanguageModes: [.v6]
)
