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
  url: "https://github.com/SteveShi/SSH2Kit/releases/download/v1.3.29/libssh2kit.xcframework.zip",
  checksum: "b1f4458a499a2b19600f8612bf080aec07437fa6f613fd968a22bbaf902cf402"
        )
    ]
)
