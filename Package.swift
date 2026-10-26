// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Pinch",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "Pinch", targets: ["Pinch"])
  ],
  targets: [
    .executableTarget(
      name: "Pinch",
      path: "Sources"
    ),
    .testTarget(
      name: "PinchTests",
      dependencies: ["Pinch"],
      path: "Tests"
    ),
  ]
)
