// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MeetingAssistant", platforms: [.macOS(.v14)], products: [.executable(name: "MeetingAssistant", targets: ["MeetingAssistant"])], targets: [.systemLibrary(name: "CSQLite"), .executableTarget(name: "MeetingAssistant", dependencies: ["CSQLite"], swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "MeetingAssistantTests", dependencies: ["MeetingAssistant"], swiftSettings: [.swiftLanguageMode(.v5)])])
