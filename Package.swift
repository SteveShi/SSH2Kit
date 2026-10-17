// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSH2Kit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
  name: "SSH2Kit",
  targets: ["SSH2Kit"]
        )
    ],
    targets: [
        .target(
  name: "SSH2Kit",
  dependencies: ["Clibssh2"]
        ),
        .target(
  name: "Clibssh2",
  dependencies: ["libssh2kit"]
        ),
        .binaryTarget(
  name: "libssh2kit",
  url: "https://github.com/SteveShi/SSH2Kit/releases/download/v1.3.26/libssh2kit.xcframework.zip",
  checksum: "143c5cb9dd4ee4288a88266a1c9408987bd534ecc7278754be99893be10d7310"
        )
    ]
)
