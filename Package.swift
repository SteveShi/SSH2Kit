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
  url: "https://github.com/SteveShi/libssh2-swift/releases/download/v1.3.14/libssh2kit.xcframework.zip",
  checksum: "6e8f961781f13bcf805254c2c943efa3629a817894916d176d5e7a91f06fd304"
        )
    ]
)
