// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DeadlineStartup", platforms: [.macOS(.v13)], products: [.executable(name: "DeadlineStartup", targets: ["DeadlineStartup"])], targets: [.executableTarget(name: "DeadlineStartup")])
