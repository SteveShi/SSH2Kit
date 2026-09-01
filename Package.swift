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
  url: "https://github.com/SteveShi/SSH2Kit/releases/download/v1.3.16/libssh2kit.xcframework.zip",
  checksum: "0e06b4e31adcb06152c28c00af9ca339012a3622431e974919494c4707a29abc"
        )
    ]
)
