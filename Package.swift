// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notas",
    platforms: [.macOS("26.0")],
    products: [.library(name: "NotasShared", type: .static, targets: ["NotasShared"])],
    targets: [
        .target(name: "NotasShared", path: "Sources/NotasShared", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Notas",
            dependencies: ["NotasShared"],
            path: "Sources/Notas",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
