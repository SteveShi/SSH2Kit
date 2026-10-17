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
  url: "https://github.com/SteveShi/SSH2Kit/releases/download/v1.3.28/libssh2kit.xcframework.zip",
  checksum: "ec094f4f3d0565d3e4405276d13b1f810d681fe74643e3746fa4958348c05f09"
        )
    ]
)
