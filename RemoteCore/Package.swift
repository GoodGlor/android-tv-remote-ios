// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RemoteCore", targets: ["RemoteCore"])],
    dependencies: [
        // The ONLY external dependency. Pinned by revision: latest tag (2.4.16,
        // Aug 2024) predates the connection-timeout feature on main.
        .package(
            url: "https://github.com/odyshewroman/AndroidTVRemoteControl",
            revision: "32393c3"
        ),
    ],
    targets: [
        .target(
            name: "RemoteCore",
            dependencies: [
                .product(name: "AndroidTVRemoteControl", package: "AndroidTVRemoteControl"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),
        .executableTarget(
            name: "rc-probe",
            dependencies: ["RemoteCore"]
        ),
    ]
)
