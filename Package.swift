// swift-tools-version:6.0
// 奶蛙桌宠 · macOS 移植版
// 基于 yugh6/Naiwa（Windows / .NET Framework 4.x 原始素材版 v1.2.2）的源码移植。
// 素材（素材.nwp、原版笑声.wav）版权归原作者 yugh6 所有，本项目仅为个人向的 macOS 重实现。
import PackageDescription

let package = Package(
    name: "Naiwa",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "Naiwa",
            path: "Sources/Naiwa",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
