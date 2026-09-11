// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoneyBook",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MoneyBook", targets: ["MoneyBook"]),
    ],
    targets: [
        .executableTarget(
            name: "MoneyBook",
            path: "Sources/MoneyBook",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MoneyBookTests",
            dependencies: ["MoneyBook"],
            path: "Tests/MoneyBookTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
