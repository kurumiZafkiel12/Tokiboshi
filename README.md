# Tokiboshi

代理客户端，**Windows 版**。独立项目，与 Hotaru 无直接关联。

- **内核**：sing-box
- **界面**：Flutter
- **中间层**：Rust（flutter_rust_bridge；Flutter 界面 ↔ Rust 中间层 ↔ sing-box 内核）

图标：`assets/icon.png`（时崎狂三主题，时钟与红黑配色）。

## 使用（v0.3）

1. 从 Releases 下载安装包（`Tokiboshi-Setup-0.3.0.exe`）或便携 zip，运行 `tokiboshi.exe`。
2. 首次点「启动」时会自动下载 sing-box 内核（固定 1.14.4，存放在数据目录的 `core\` 下）；也可以在设置页手动「下载/更新内核」，或在设置里指定自己的 sing-box 路径。
3. 导入节点 / 订阅（节点页或订阅页）：
   - 分享链接：vless / vmess / trojan / hysteria2(hy2) / ss / socks5 等
   - 订阅 URL：base64 节点列表、Clash YAML、sing-box JSON 都可以；订阅内容里若还嵌着其他订阅链接，会一并展开拉取（一个链接包含多个订阅）
4. 点「启动」：全部节点会生成一份完整配置——`proxy` 选择组 + `auto` 自动测速组、route 分流规则（私有地址直连、广告拦截、国内站点/IP 直连，其余走代理）、Clash API 控制通道。在「面板」页（zashboard，由 sing-box 托管）里切换节点、切 Rule/Global 模式、看连接与流量；面板里选中的节点会被记住，重启不丢。
5. 默认同时开启 Windows 系统代理（127.0.0.1:7890，可改端口或关掉）；「停止」会关闭系统代理并停内核。内核意外退出会自动重启（最多 3 次），「日志」页可看内核输出。
6. 节点与设置保存在 `%APPDATA%\Tokiboshi\data.json`，生成的运行配置在同目录 `config.json`。

## 结构

| 路径 | 内容 |
|---|---|
| `lib/` | Flutter 界面；`lib/bridge/` 是中间层接口与 Rust 实现；`lib/src/rust/` 为 flutter_rust_bridge 生成绑定（勿手改） |
| `rust/` | Rust 中间层：配置校验/生成（`src/config.rs`）、链接/订阅解析（`src/links.rs`）、内核进程管理与监督（`src/process.rs`）、内核下载（`src/core_download.rs`）、对 Flutter 的 API（`src/api/`） |
| `rust_builder/` | flutter_rust_bridge 的构建插件（cargokit） |
| `windows/` | Windows 平台工程 |
| `.github/workflows/windows.yml` | Windows CI：测试 + 构建 Release + 生成安装包后上传产物（内核由应用运行时按需下载，不再随包附带） |

## 开发

```sh
cd rust && cargo test          # 中间层测试（权威）
flutter analyze && flutter test
flutter build windows --release
flutter_rust_bridge_codegen generate   # 改了 rust/src/api 后重新生成绑定
```

## 状态（v0.3.0）

以 AI-Workspace 项目讨论为准（区分已验证 / 已实现未验证 / 未完成）。v0.3 起转为 GUI 壳架构：sing-box 子进程 + Clash API + zashboard 面板（内嵌 WebView）。已知边界：TUN 未做（设置里有开关字段但不建议开）、流量统计走面板、系统代理只写注册表，个别应用需重开才感知变化。
