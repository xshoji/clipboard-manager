// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClipboardManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipboardManager", targets: ["ClipboardManager"])
    ],
    targets: [
        .executableTarget(
            name: "ClipboardManager",
            path: "ClipboardManager",
            exclude: ["App/Info.plist"],
            resources: [
                .process("Resources/Assets.xcassets")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("SwiftData"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreImage"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
