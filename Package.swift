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
  url: "https://github.com/SteveShi/SSH2Kit/releases/download/v1.3.22/libssh2kit.xcframework.zip",
  checksum: "043a52b52cc4c562e7ef57275082a1baa96460d846cb7493a362c43d3076666b"
        )
    ]
)
