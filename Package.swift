// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "horizon",
    platforms: [.macOS(.v14)],
    targets: [
        // No dependencies. ImageIO reads/writes 16-bit TIFF (including the
        // zstd-compressed masters tifffile writes), Accelerate does the LUT.
        .executableTarget(name: "horizon", path: "Sources/horizon")
    ]
)
