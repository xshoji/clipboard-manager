// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClipboardManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipboardManager", targets: ["ClipboardManager"]),
        .executable(name: "ClipboardHTMLRenderer", targets: ["ClipboardHTMLRenderer"])
    ],
    targets: [
        .executableTarget(
            name: "ClipboardManager",
            path: "ClipboardManager",
            exclude: ["App/Info.plist", "App/Info.E2E.plist"],
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
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision"),
            ]
        ),
        .executableTarget(
            name: "ClipboardHTMLRenderer",
            path: "ClipboardHTMLRenderer",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "ClipboardManagerTests",
            dependencies: ["ClipboardManager"],
            path: "Tests/UnitTests"
        ),
    ]
)
