// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BarcodeMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BarcodeMenuBar", targets: ["BarcodeMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "BarcodeMenuBar",
            path: ".",
            sources: [
                "BarcodeMenuBarApp.swift"
            ]
        )
    ]
)
