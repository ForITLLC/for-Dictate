// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictateOffscreenProof",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/ForITLLC/for-iCommon.git",
            revision: "352f567e839b8faf61b6df5840c5275b016addce"
        ),
    ],
    targets: [
        .testTarget(
            name: "DictateOffscreenProofTests",
            dependencies: [.product(name: "ForITCommon", package: "for-icommon")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
