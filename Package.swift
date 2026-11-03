// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Askme",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Askme", targets: ["Askme"])],
    targets: [
        .target(name: "AskmeCore"),
        .executableTarget(name: "Askme", dependencies: ["AskmeCore"]),
        .testTarget(name: "AskmeCoreTests", dependencies: ["AskmeCore"])
    ]
)
