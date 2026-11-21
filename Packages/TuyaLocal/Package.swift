// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TuyaLocal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TuyaLocal", targets: ["TuyaLocal"]),
        .executable(name: "tuya-probe", targets: ["tuya-probe"]),
    ],
    dependencies: [
        // Test-only: virtual clock for heartbeat/backoff timing tests.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.6"),
    ],
    targets: [
        .target(
            name: "TuyaLocal",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "tuya-probe",
            dependencies: ["TuyaLocal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TuyaLocalTests",
            dependencies: [
                "TuyaLocal",
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
