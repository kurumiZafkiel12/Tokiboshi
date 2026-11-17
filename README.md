<div align="center">
<img src="assets/icon.png" alt="Tokiboshi" width="88">

# Tokiboshi

简洁的 Windows sing-box 客户端：Flutter 界面 + Rust 中间层 + sing-box 内核。独立项目，与 Hotaru 无直接关联。

[**下载安装**](https://github.com/kurumiZafkiel12/Tokiboshi/releases/latest) · [更新记录](https://github.com/kurumiZafkiel12/Tokiboshi/releases) · [问题反馈](https://github.com/kurumiZafkiel12/Tokiboshi/issues)
</div>

## 功能

- **小组件工作台**：可调整的信息组件、底部出口选择器、深浅主题、三档动效与独立角色细节；流量和请求接入真实本地控制器。

- **订阅与节点**：分享链接（vless / vmess / trojan / hysteria2 / ss / socks5 等）、base64 订阅、Clash YAML（含 proxy-providers）、sing-box JSON；订阅里嵌套的其他订阅链接会递归展开（深度与数量有上限，超限会提示）。
- **分组与测速**：节点按来源分组展示，支持延迟测试与链式代理（前置 → 落地），导入的 `dialer-proxy` / `detour` 会保留。
- **分流与模式**：规则（广告拦截、国内直连可开关）、全局、直连三种模式真实生效，可在面板或托盘切换。
- **面板与日志**：内嵌 zashboard（由内核托管）切换节点、查看连接与流量；日志页包含内核输出与规则集状态（`[rules]` 行）。
- **网络接管**：Windows 系统代理与 TUN。端口被占用时自动顺延并更新显示，不会关闭其他客户端。
- **健壮性**：配置数据原子写入 + 备份恢复；内核崩溃自动重启并绑定进程生命周期（GUI 崩溃不遗留后台内核）；下载内核/面板校验官方 SHA256；单实例运行。

Tokiboshi 不提供代理服务器或订阅服务，使用前需要导入自己的节点或订阅。

## 下载与安装

Windows 当前为 **0.0.9 修订版 r2（build 10）**：多方式导入、常规设置接线与更细腻的三档动效。完整配置不兼容时需明确选择仅节点，原配置不会被静默替换。

| 平台 | 版本要求 | 下载 |
| --- | --- | --- |
| Windows | Windows 10/11，x64 | [![Setup x64](https://img.shields.io/badge/Setup-x64-3d8ba3?style=flat-square)](https://github.com/kurumiZafkiel12/Tokiboshi/releases/download/v0.0.9-r2/Tokiboshi-Setup-0.0.9-r2.exe) [![ZIP x64](https://img.shields.io/badge/ZIP-x64-3d8ba3?style=flat-square)](https://github.com/kurumiZafkiel12/Tokiboshi/releases/download/v0.0.9-r2/Tokiboshi-windows.zip) |
| Android | Android 7.0+（API24），三种架构 | [![APK arm64-v8a](https://img.shields.io/badge/APK-arm64--v8a-3DDC84?style=flat-square&logo=android&logoColor=white&labelColor=555555)](https://github.com/kurumiZafkiel12/Tokiboshi/releases/download/v0.0.9-android-r1/Tokiboshi-0.0.9-android-arm64-v8a.apk)<br>[![APK armeabi-v7a](https://img.shields.io/badge/APK-armeabi--v7a-3DDC84?style=flat-square&logo=android&logoColor=white&labelColor=555555)](https://github.com/kurumiZafkiel12/Tokiboshi/releases/download/v0.0.9-android-r1/Tokiboshi-0.0.9-android-armeabi-v7a.apk)<br>[![APK x86_64](https://img.shields.io/badge/APK-x86_64-3DDC84?style=flat-square&logo=android&logoColor=white&labelColor=555555)](https://github.com/kurumiZafkiel12/Tokiboshi/releases/download/v0.0.9-android-r1/Tokiboshi-0.0.9-android-x86_64.apk) |

安装文件与 SHA256 校验清单（`SHA256SUMS.txt`）均在发布页。安装程序尚未做 Authenticode 签名。

- 推荐使用上方简体中文安装版：安装时自动关闭本安装路径的旧进程，覆盖程序并按安装清单清理退役文件，保留节点、设置及恢复文件；便携版解压到新目录使用。
- 首次使用：**订阅页**导入订阅 → **节点页**选节点 → **连接工作台**点「启动代理」→ 打开「系统代理」。内核（sing-box 1.14.4，固定版本，官方校验）随包提供，缺失时自动下载，也可在设置页手动管理。
- 虚拟网卡（TUN）需要以管理员身份运行 Tokiboshi；普通权限下会明确提示，不会静默失败。
- 节点与设置保存在 `%APPDATA%\Tokiboshi\data.json`，升级覆盖安装不影响数据。
- 当前版本及历史变化见[发布说明](https://github.com/kurumiZafkiel12/Tokiboshi/releases)。

Android 对应同版功能，使用系统 VPN 和前台服务，应用 build 11；一般手机选择 arm64-v8a，32 位设备选择 armeabi-v7a，x86_64 用于对应设备/模拟器。[Android 构建与验证说明](docs/android.md)。

## 开发

<details>
<summary>从源码构建</summary>

需要 Flutter 与 Rust；Windows 构建还需要 Visual Studio C++ 桌面组件和 Inno Setup 6。

```sh
cd rust && cargo test          # 中间层测试（权威）
flutter analyze && flutter test
flutter build windows --release
flutter_rust_bridge_codegen generate   # 改了 rust/src/api 后重新生成绑定
```

真实内核集成验证（需自备官方 sing-box 1.14.4；未设置 `SING_BOX` 时集成测试提前返回，不能视为真实内核验证）：

```sh
SING_BOX=/absolute/path/to/sing-box cargo test --manifest-path rust/Cargo.toml
```

| 路径 | 内容 |
| --- | --- |
| `lib/` | Flutter 界面；`lib/src/rust/` 为 flutter_rust_bridge 生成绑定（勿手改） |
| `rust/` | 配置生成（`config.rs`）、订阅解析（`links.rs`）、内核进程监督（`process.rs`）、内核下载（`core_download.rs`）、对 Flutter 的 API（`api/`） |
| `windows/` | Windows 平台工程 |
| `.github/workflows/` | `windows.yml` 测试与构建；`publish-vXX.yml` 校验并发布 |

</details>

## 致谢

内核使用 [sing-box](https://github.com/SagerNet/sing-box)（SagerNet），面板使用 [zashboard](https://github.com/Zephyruso/zashboard)（Zephyruso），中间层绑定基于 [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge)。
