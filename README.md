# Tokiboshi

代理客户端，**Windows 版**。独立项目，与 Hotaru 无直接关联。

- **内核**：sing-box
- **界面**：Flutter
- **中间层**：Rust（flutter_rust_bridge；Flutter 界面 ↔ Rust 中间层 ↔ sing-box 内核）

图标：`assets/icon.png`（时崎狂三主题，时钟与红黑配色）。

## 使用（v0.1）

1. 从 GitHub Actions 的 `windows` 构建下载 `Tokiboshi-windows` 产物 zip 并解压（内含 `tokiboshi.exe` 与配套的 `sing-box.exe`）。
2. 运行 `tokiboshi.exe`，点右上角导入按钮，粘贴：
   - 单条分享链接：vless / vmess / trojan / hysteria2(hy2) / ss
   - 多条链接、base64 订阅内容，或 sing-box JSON 配置（取其 outbounds）
3. 在列表里选中节点，点「启动」。启动前中间层会用真实 sing-box 对生成配置做 `check`，不通过会直接报错。
4. 默认同时开启 Windows 系统代理（127.0.0.1:7890，可在界面改端口或关掉系统代理开关）；「停止」会关闭系统代理并停内核。
5. 节点与设置保存在 `%APPDATA%\Tokiboshi\data.json`，生成的运行配置在同目录 `config.json`。

## 结构

| 路径 | 内容 |
|---|---|
| `lib/` | Flutter 界面；`lib/bridge/` 是中间层接口与 Rust 实现；`lib/src/rust/` 为 flutter_rust_bridge 生成绑定（勿手改） |
| `rust/` | Rust 中间层：配置校验/生成（`src/config.rs`）、链接/订阅解析（`src/links.rs`）、内核进程启停（`src/process.rs`）、对 Flutter 的 API（`src/api/`） |
| `rust_builder/` | flutter_rust_bridge 的构建插件（cargokit） |
| `windows/` | Windows 平台工程 |
| `.github/workflows/windows.yml` | Windows CI：测试 + 构建 Release + 打包 sing-box 后上传产物 |

## 开发

```sh
cd rust && cargo test          # 中间层测试（权威）
flutter analyze && flutter test
flutter build windows --release
flutter_rust_bridge_codegen generate   # 改了 rust/src/api 后重新生成绑定
```

## 状态（v0.1.0）

以 AI-Workspace 项目讨论为准（区分已验证 / 已实现未验证 / 未完成）。已知边界：暂不支持 Clash YAML 订阅、TUN、多节点分组/测速；系统代理只写注册表，个别应用需重开才感知变化。
