// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SolidFerryKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeviceCore", targets: ["DeviceCore"]),
        .library(name: "AdbKit", targets: ["AdbKit"]),
        .library(name: "UsbKit", targets: ["UsbKit"]),
        .library(name: "TransferKit", targets: ["TransferKit"]),
        .library(name: "MtpKit", targets: ["MtpKit"]),
        .executable(name: "sferry", targets: ["sferry"]),
    ],
    targets: [
        .target(name: "DeviceCore"),
        .target(name: "AdbKit", dependencies: ["DeviceCore"]),
        .target(name: "UsbKit"),
        .target(name: "TransferKit", dependencies: ["DeviceCore"]),
        .target(name: "MtpKit", dependencies: ["DeviceCore", "UsbKit"]),
        .executableTarget(name: "sferry", dependencies: ["AdbKit", "DeviceCore", "UsbKit", "TransferKit", "MtpKit"]),
        .testTarget(name: "AdbKitTests", dependencies: ["AdbKit", "DeviceCore"]),
        .testTarget(name: "TransferKitTests", dependencies: ["TransferKit", "DeviceCore"]),
        .testTarget(name: "MtpKitTests", dependencies: ["MtpKit", "DeviceCore"]),
        .testTarget(name: "UsbKitTests", dependencies: ["UsbKit"]),
        .testTarget(name: "DeviceCoreTests", dependencies: ["DeviceCore"]),
    ]
)
