// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "libssh2-swift",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
  name: "libssh2-swift",
  targets: ["libssh2-swift"]
        )
    ],
    targets: [
        .target(
  name: "libssh2-swift",
  dependencies: ["Clibssh2"]
        ),
        .target(
  name: "Clibssh2",
  dependencies: ["libssh2kit"]
        ),
        .binaryTarget(
  name: "libssh2kit",
  url: "https://github.com/SteveShi/libssh2-swift/releases/download/v1.3.13/libssh2kit.xcframework.zip",
  checksum: "84712ac11a20caf059e6d0c6b07bc1bbcbac6ee95ebec61d5e6805336c79bc30"
        )
    ]
)
