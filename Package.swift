// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "palimpsest-ink",
    platforms: [
        .macOS(.v14)
    ],
    products: {
        var products: [Product] = [
            .library(name: "PalimpsestCore", targets: ["PalimpsestCore"])
        ]
        #if os(macOS)
        products.append(.executable(name: "PalimpsestInk", targets: ["PalimpsestInk"]))
        #endif
        #if os(Windows)
        products.append(.executable(name: "PalimpsestWin", targets: ["PalimpsestWin"]))
        #endif
        #if os(Linux)
        products.append(.executable(name: "palimpsest-ink", targets: ["PalimpsestLinux"]))
        #endif
        return products
    }(),
    targets: {
        var targets: [Target] = [
            // Portable: Foundation only, no AppKit/CoreGraphics. Builds on
            // macOS, Linux and Windows Swift toolchains.
            .target(
                name: "PalimpsestCore",
                path: "Sources/ScribbleEverywhereCore"
            )
        ]
        #if os(macOS)
        targets.append(
            // macOS shell: AppKit + ScreenCaptureKit + Carbon.
            .executableTarget(
                name: "PalimpsestInk",
                dependencies: ["PalimpsestCore"],
                path: "Sources/ScribbleEverywhereMac"
            )
        )
        targets.append(.testTarget(
            name: "PalimpsestMacTests",
            dependencies: ["PalimpsestInk", "PalimpsestCore"],
            path: "Tests/ScribbleEverywhereMacTests"
        ))
        #endif
        #if os(Windows)
        targets.append(
            // Windows shell: systray applet, layered overlay, WM_POINTER pen
            // input (Surface Book built-in pen/touch), GDI capture, pure-Swift PNG.
            .executableTarget(
                name: "PalimpsestWin",
                dependencies: ["PalimpsestCore"],
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
                name: "PalimpsestWinTests",
                dependencies: ["PalimpsestWin", "PalimpsestCore"],
                path: "Tests/ScribbleEverywhereWinTests"
            )
        )
        #endif
        #if os(Linux)
        targets.append(
            // C interop: wayland-scanner generated protocol code (run
            // scripts/gen-wayland-protocols.sh first) + libpng writer.
            .target(
                name: "CPalimpsestLinux",
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
                name: "PalimpsestLinux",
                dependencies: ["PalimpsestCore", "CPalimpsestLinux"],
                path: "Sources/ScribbleEverywhereLinux"
            )
        )
        targets.append(.testTarget(
            name: "PalimpsestLinuxTests",
            dependencies: ["PalimpsestLinux", "PalimpsestCore", "CPalimpsestLinux"],
            path: "Tests/ScribbleEverywhereLinuxTests"
        ))
        #endif
        targets.append(
            .testTarget(
                name: "PalimpsestCoreTests",
                dependencies: ["PalimpsestCore"],
                path: "Tests/ScribbleEverywhereCoreTests"
            )
        )
        return targets
    }()
)
