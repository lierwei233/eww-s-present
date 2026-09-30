// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cike",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cike", targets: ["Cike"])],
    targets: [.executableTarget(name: "Cike")]
)
