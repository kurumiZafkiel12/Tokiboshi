# Tokiboshi

新的代理软件。独立项目，与 Hotaru 无直接关联。

- **内核**：sing-box
- **界面**：Flutter
- **中间层**：Rust（Flutter 界面 ↔ Rust 中间层 ↔ sing-box 内核）

图标：`assets/icon.png`（时崎狂三主题，时钟与红黑配色）。

## 结构

| 路径 | 内容 |
|---|---|
| `lib/` | Flutter 界面；`lib/bridge/core_bridge.dart` 是与 Rust 中间层的接口及 Dart 镜像实现 |
| `rust/` | Rust 中间层：sing-box 配置校验/生成（`src/config.rs`）、内核进程启停（`src/process.rs`）、对 Flutter 的 API（`src/api/`） |
| `test/` | Flutter 侧桥接逻辑与界面测试，与 Rust 单元测试保持同一组用例 |

## 开发

Rust 中间层（权威实现）：

```sh
cd rust
cargo test
```

Flutter 界面：

```sh
flutter pub get
flutter analyze
flutter test
```

生成 Rust ↔ Dart 绑定（flutter_rust_bridge）后，`lib/src/rust/` 为生成代码，界面改走真实 Rust 实现：

```sh
flutter_rust_bridge_codegen generate
```

## 状态（v0.0.1 骨架）

以 AI-Workspace 项目讨论为准：`projects/tokiboshi/STATUS.md`（区分已验证 / 已实现未验证 / 未完成）。平台优先级待定。
