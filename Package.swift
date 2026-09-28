// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "horizon",
    platforms: [.macOS(.v14)],
    targets: [
        // No package dependencies. ImageIO reads/writes TIFF; Core Image's
        // CIRAWFilter decodes supported camera RAW captures in memory; Accelerate
        // implements the LUT path.
        .executableTarget(name: "horizon", path: "Sources/horizon")
    ]
)
