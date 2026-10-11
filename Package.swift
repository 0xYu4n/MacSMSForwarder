// swift-tools-version: 6.0
// Mac短信转发（MacSMSForwarder）SwiftPM 工程描述
// 纯 SwiftPM 编译：无需 Xcode，使用 scripts/build-app.sh 组装 .app
import PackageDescription

let package = Package(
  name: "MacSMSForwarder",
  // 与上游 imsg 保持一致：最低 macOS 14
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "MacSMSForwarder", targets: ["MacSMSForwarder"]),
    .library(name: "ForwarderCore", targets: ["ForwarderCore"]),
  ],
  dependencies: [
    // 收发能力：openclaw/imsg 的 IMsgCore（MIT），按 tag 锁定版本，后续可替换为自己的 fork
    .package(url: "https://github.com/openclaw/imsg.git", exact: "0.15.10"),
    // 自有数据库：GRDB（MIT）
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
  ],
  targets: [
    // 核心逻辑：存储、规则、模板、转发通道、收信、发送（不依赖 UI，方便测试）
    .target(
      name: "ForwarderCore",
      dependencies: [
        .product(name: "IMsgCore", package: "imsg"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Sources/ForwarderCore",
      // 使用 Swift 5 语言模式，避免 Swift 6 严格并发检查带来的大量样板代码
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // SwiftUI 图形界面 App
    .executableTarget(
      name: "MacSMSForwarder",
      dependencies: ["ForwarderCore"],
      path: "Sources/MacSMSForwarder",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // 单元测试统一放在 tests 目录
    .testTarget(
      name: "ForwarderCoreTests",
      dependencies: ["ForwarderCore"],
      path: "tests/ForwarderCoreTests",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
