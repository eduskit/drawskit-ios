# iOS SDK (DrawsKit)

## 集成

发布后的 Swift Package 仓库为：

```text
https://github.com/eduskit/drawskit-ios
```

在 Xcode 中选择 **File → Add Package Dependencies**，输入该地址并选择所需版本。
也可以在 `Package.swift` 中声明：

```swift
dependencies: [
    .package(url: "https://github.com/eduskit/drawskit-ios.git", from: "0.1.2"),
]
```

SPM 从 `https://sdk.eduskit.com/drawskit/ios/<版本>/binary.zip` 下载多架构 Rust
XCFramework，并使用 `Package.swift` 中的 checksum 校验。完整手动集成包仍可从
`https://sdk.eduskit.com/drawskit/ios/<版本>/sdk.zip` 下载。构建命令为
`pnpm release:pack ios`。详见 [SDK 发布流程](https://github.com/eduskit/drawskit/blob/afb9cc7aa6ff9be08edffc2d6e91524ec5bd6ead/docs/releasing.md)。

## 快速上手

```swift
import DrawsKit

let drawsKit = DrawsKit(initParams: DrawsKitInitParams(
    id: "whiteboard",
    roomId: "12345",
    appid: "1400000000",
    userId: "user_001",
    token: "xxx"
))

drawsKit.on(DrawsKit.EVENT.DK_INIT) {
    print("白板就绪")
}

drawsKit.setToolType(DrawsKit.ToolType.DRAWSKIT_TOOL_TYPE_PEN)
```

## 目录

```
platforms/ios/
├── drawskit-sdk/     # 本地 Swift Package
└── demo/            # Demo App
```

## 运行 Demo

```bash
# 1. 构建 Rust FFI 静态库（模拟器）
pnpm build:ios:ffi

# 真机构建（可选）
# pnpm build:ios:ffi:device

# 2. 解析本地 Swift Package 并打开工程
pnpm ios:resolve
open platforms/ios/demo/Demo.xcodeproj
```

## 实现状态

- **已接入（阶段一）**：FFI 引擎、`DrawsKitEngine`、`DrawsKitView`、Core Graphics 渲染、触摸/捏合缩放、生命周期、白板页、工具态、历史、静态课件、导入导出
- **已接入（阶段二，对齐 Web/Android Demo）**：
  - 完整 `DemoToolbar`（10 类工具 + 二级面板 + 状态栏）
  - 文本工具：`TextInputOverlay`（UITextView 就地编辑）
  - H5 课件：`CoursewareHost`（WKWebView 在 canvas 下方）
  - `attachView(_:boardContainer:)` 布局与 Android `boardContainer` 一致
- **仍为 `todo()`**：同步、音视频、权限、分组等 ~110 个 API（与 Android 一致）
- **坐标**：UIKit 使用 point 坐标（等同 Web CSS px），`viewport_resize` 发送 `dpr: 1`；勿再除以 `displayScale`（否则笔画相对偏粗）
