// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "scribble-everywhere",
    platforms: [
        .macOS(.v14)
    ],
    products: {
        var products: [Product] = [
            .library(name: "ScribbleEverywhereCore", targets: ["ScribbleEverywhereCore"])
        ]
        #if os(macOS)
        products.append(.executable(name: "ScribbleEverywhere", targets: ["ScribbleEverywhere"]))
        #endif
        #if os(Windows)
        products.append(.executable(name: "ScribbleEverywhere", targets: ["ScribbleEverywhereWin"]))
        #endif
        #if os(Linux)
        products.append(.executable(name: "scribble", targets: ["ScribbleEverywhereLinux"]))
        #endif
        return products
    }(),
    targets: {
        var targets: [Target] = [
            // Portable: Foundation only, no AppKit/CoreGraphics. Builds on
            // macOS, Linux and Windows Swift toolchains.
            .target(
                name: "ScribbleEverywhereCore",
                path: "Sources/ScribbleEverywhereCore"
            )
        ]
        #if os(macOS)
        targets.append(
            // macOS shell: AppKit + ScreenCaptureKit + Carbon.
            .executableTarget(
                name: "ScribbleEverywhere",
                dependencies: ["ScribbleEverywhereCore"],
                path: "Sources/ScribbleEverywhereMac"
            )
        )
        targets.append(.testTarget(
            name: "ScribbleEverywhereMacTests",
            dependencies: ["ScribbleEverywhere", "ScribbleEverywhereCore"],
            path: "Tests/ScribbleEverywhereMacTests"
        ))
        #endif
        #if os(Windows)
        targets.append(
            // Windows shell: systray applet, layered overlay, WM_POINTER pen
            // input (Surface Book built-in pen/touch), GDI capture, pure-Swift PNG.
            .executableTarget(
                name: "ScribbleEverywhereWin",
                dependencies: ["ScribbleEverywhereCore"],
                path: "Sources/ScribbleEverywhereWin",
                linkerSettings: [
                    .linkedLibrary("user32"),
                    .linkedLibrary("gdi32"),
                    .linkedLibrary("shell32"),
                    .linkedLibrary("dwmapi"),
                    .linkedLibrary("ole32"),
                    // Executable-only subsystem/entry flags are supplied by
                    // build-windows.ps1. Target linker settings are inherited
                    // by test DLLs, which must use their normal DLL entry point.
                    .linkedLibrary("hid")
                ]
            )
        )
        targets.append(
            .testTarget(
                name: "ScribbleEverywhereWinTests",
                dependencies: ["ScribbleEverywhereWin", "ScribbleEverywhereCore"],
                path: "Tests/ScribbleEverywhereWinTests"
            )
        )
        #endif
        #if os(Linux)
        targets.append(
            // C interop: wayland-scanner generated protocol code (run
            // scripts/gen-wayland-protocols.sh first) + libpng writer.
            .target(
                name: "CScribbleEverywhereLinux",
                path: "Sources/CScribbleEverywhereLinux",
                publicHeadersPath: "include",
                cSettings: [
                    .headerSearchPath("Generated"),
                    .define("_GNU_SOURCE")
                ],
                linkerSettings: [
                    .linkedLibrary("wayland-client"),
                    .linkedLibrary("wayland-cursor"),
                    .linkedLibrary("png"),
                    .linkedLibrary("m")
                ]
            )
        )
        targets.append(
            // Linux shell: Hyprland/Wayland daemon + CLI + optional Omarchy applet.
            .executableTarget(
                name: "ScribbleEverywhereLinux",
                dependencies: ["ScribbleEverywhereCore", "CScribbleEverywhereLinux"],
                path: "Sources/ScribbleEverywhereLinux"
            )
        )
        targets.append(.testTarget(
            name: "ScribbleEverywhereLinuxTests",
            dependencies: ["ScribbleEverywhereLinux", "ScribbleEverywhereCore", "CScribbleEverywhereLinux"],
            path: "Tests/ScribbleEverywhereLinuxTests"
        ))
        #endif
        targets.append(
            .testTarget(
                name: "ScribbleEverywhereCoreTests",
                dependencies: ["ScribbleEverywhereCore"],
                path: "Tests/ScribbleEverywhereCoreTests"
            )
        )
        return targets
    }()
)
