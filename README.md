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

## 0.5.1 修复分支

项目地址：https://github.com/kurumiZafkiel12/Tokiboshi

问题反馈：https://github.com/kurumiZafkiel12/Tokiboshi/issues

- **端口占用**：`listen tcp 127.0.0.1:7890: bind` 表示其他进程已监听该端口。启动前会在原端口及其后的 31 个端口中寻找空闲端口，自动保存实际端口并用于系统代理；Clash API 端口单独分配。不会关闭其他客户端。手动配置的浏览器/SOCKS 代理需跟随仪表盘显示的实际端口更新。原生层也会检查占用，并等待真实监听就绪；若系统代理设置失败，会停止本次启动的内核。
- **合并订阅**：递归展开纯 URL 列表、base64 URL 列表、Clash `proxy-providers`，支持只有 provider 的订阅、JSON 格式的 Clash 配置、YAML 合并锚点与字符串端口。不再按名字丢弃节点。保留源声明的 User-Agent 与过滤规则；默认请求声明 Clash.Meta 格式兼容性。8 层深度、64 个请求、256 次展开与 100000 个节点上限均会提示，循环、失败和无效过滤规则也会提示。不同客户端可能因为响应格式、过滤规则、重复节点和节点源可达性得到不同数量。
- **分组抽屉**：节点按订阅和 provider 分组，可展开/折叠，标题显示数量；订阅筛选包含该订阅的全部 provider 节点。此版分组以节点来源为准，尚不等同于导入 Clash 的全部 `proxy-groups` 策略语义。
- **链式代理**：停止内核后，在节点页选择「链式代理」，配置前置和落地节点。顺序是「本机 → 前置 → 落地 → 目标」。保存两个独立副本，并选中落地节点；请保留同组前置节点。副本不会随原订阅更新；暂不允许再次串联已有链的节点。实际 UDP 能力取决于两端协议与服务器。导入的 Clash `dialer-proxy` 和 sing-box `detour` 会保留；缺失依赖、歧义名称和循环链路会明确拒绝。
- **图标**：外框四角透明，Flutter PNG、托盘 ICO 与 Windows EXE 图标保持一致。

Rust 真实内核验证（需自行准备官方 sing-box 1.14.4）：

```sh
SING_BOX=/absolute/path/to/sing-box cargo test --locked --manifest-path rust/Cargo.toml
```

未设置 `SING_BOX` 时，真实内核集成测试会提前返回，不能视为真实内核验证。Windows 发布包仍须执行 `flutter analyze`、`flutter test` 和 Windows CI 构建；本修复分支的验证记录见 AI-Workspace 的 Tokiboshi 项目报告。
