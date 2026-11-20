// swift-tools-version: 6.0
import PackageDescription

// Kern der iPhone-App PDF Search: Index, Texterkennung, Suche, PDF-Ausgabe.
// Bewusst unabhängig von PDFSucherKit (Mac-App), damit Änderungen dort die iPhone-App nicht berühren.
let package = Package(
    name: "PDFSearchCore",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "PDFSearchCore", targets: ["PDFSearchCore"]),
    ],
    targets: [
        .target(name: "PDFSearchCore"),
        .testTarget(name: "PDFSearchCoreTests", dependencies: ["PDFSearchCore"]),
    ],
    swiftLanguageModes: [.v6]
)
