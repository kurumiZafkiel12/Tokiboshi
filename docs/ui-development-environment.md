# Tokiboshi UI 开发环境

记录日期 2026-11-22 JST。基线为 Windows v0.1.3 候选 `feat/windows-v013` 的 `e4ccefa`。Flutter 3.50.0（`ab2912035e`）和 Dart 3.14.0 与现有 CI 一致。当前项目的 Windows 和 Android 内核为 sing-box 1.14.4，配置仅涉及 UI 开发工具和依赖。

## 项目级技能

每行中的技能均位于仓库根目录 `.agents/skills/<技能名>/SKILL.md`。同目录的上游脚本、参考文档、组件文档、数据和测试夹具随 Git 保存。`.agents/skills-lock.json` 记录各技能的完整上游提交、原路径、文件数及 SHA-256。`.agents/skill-licenses/` 保存原始许可证。已有仓库检出即可使用，云端初始化无需运行 npm 安装器。

| 技能 | 用途 | 来源 |
| --- | --- | --- |
| `ui-ux-pro-max` | 视觉规范、配色、字型、信息密度和 Flutter 指南查询 | [Next Level Builder · f76d165](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/tree/f76d1653d7467fc11fb9d9d79295a421c92ab958/.claude/skills/ui-ux-pro-max) |
| `flutter-build-responsive-layout` | 按可用宽度调整组件和导航 | [Flutter 官方 · ff6d472](https://github.com/flutter/agent-plugins/tree/ff6d472ee66dbed566c4500edee460c94fde0a02/skills) |
| `flutter-fix-layout-issues` | 诊断约束、溢出及滚动布局 | 同上 |
| `flutter-add-widget-preview` | 为组件添加独立预览 | 同上 |
| `flutter-add-widget-test` | 编写组件测试 | 同上 |
| `flutter-add-integration-test` | 增补端到端测试指导 | 同上 |
| `dart-run-static-analysis` | Dart/Flutter 静态分析 | 同上 |
| `dart-resolve-package-conflicts` | 依赖求解和冲突诊断 | 同上 |
| `flutter-theming-apps` | 主题、颜色和排版 | [Flutter 官方归档 · 44685e8](https://github.com/flutter/agent-plugins/tree/44685e80869e5e0304075974c7f9c598f5a3a967/skills) |
| `flutter-animating-apps` | 动画、转场及物理曲线 | 同上 |
| `flutter-building-layouts` | 约束系统和布局组件 | 同上 |
| `flutter-improving-accessibility` | 语义、读屏和无障碍验收 | 同上 |
| `flutter-testing-apps` | 单元、组件、集成测试策略 | 同上 |
| `flutter-reducing-app-size` | 测量和优化应用体积 | 同上 |
| `flutter-design` | Flutter 界面设计流程 | [Flutter Design Engineer · 9355c1a](https://github.com/musabekisakov-imj/flutter-design-engineer/tree/9355c1ab90ed870250fb3ba979321456ff7addda/skills) |
| `flutter-audit` | 审查现有 UI 的细节与一致性 | 同上 |
| `flutter-design-system` | 主题和设计令牌 | 同上 |
| `flutter-implementation` | Flutter 组件实现与组合 | 同上 |
| `flutter-motion` | 转场和交互动效，含减少动效模式 | 同上 |
| `flutter-accessibility` | 键盘、焦点、语义和对比度 | 同上 |
| `flutter-visual-qa` | 预览、截图与视觉验收 | 同上 |
| `shadcn-flutter` | 主组件库的 API、主题及组件说明 | [shadcn_flutter · 611caaf](https://github.com/sunarya-thito/shadcn_flutter/tree/611caafcdfa0da659924c7a7679083714b917d17/packages/shadcn_flutter/skills/shadcn-flutter) |
| `shadcn-ui-flutter` | 候选库的组件和使用参考 | [shadcn_ui · 548324d](https://github.com/nank1ro/flutter-shadcn-ui/tree/548324d212834fae8955bcef16fb889bc0a66b63/skills/shadcn-ui-flutter) |
| `shad-overview` | 候选库的组件和主题参考 | [shad · f122003](https://github.com/serverpod/shad/tree/f122003f3a4a4056f5cda2141f2eafbeb932c5b0/skills/shad-overview) |

Flutter 官方历史中的 6 个技能由 [130378c](https://github.com/flutter/agent-plugins/commit/130378c2e7f847749664a236a150465453f046b9) 移除。新任务的布局与测试以当前官方技能为主，主题、动效与无障碍可用 Flutter Design Engineer，体积分析用 Flutter SDK 的 `--analyze-size`。已检查各候选库和辅助库的上游技能目录。Forui 的仓库技能用于维护测试基线和发布 Forui，其余未列库的默认上游目录未发现供组件使用者调用的 `SKILL.md`。[Flutter 体积分析](https://docs.flutter.dev/tools/devtools/app-size) · [Forui 维护技能](https://github.com/duobaseio/forui/tree/main/.agents/skills)

Flutter 官方与 shadcn_flutter 技能采用 BSD-3-Clause，其他来源采用 MIT。已核对 Git 树均为普通文件，检查了 26 个 Python 文件的语法与进程、网络、写盘调用。UI UX Pro Max 查询入口用 Python 标准库。其可选持久化功能会写设计文件，部分上游自测会启动本地子进程或依赖上游整个项目的维护工具。项目检出后可离线查询和验证文件，维护者全仓测试另在上游运行。部署及依赖安装流程均无技能自动执行步骤。

```sh
python3 tool/verify_ui_skills.py
python3 -B .agents/skills/ui-ux-pro-max/scripts/search.py "compact desktop dashboard" --stack flutter
```

## 组件库评估与选择

对每个候选单独在同一基线的锁文件上，使用表中参考版本执行 Flutter 3.50.0 的 `flutter pub get`。16 个单库组合均完成求解。最终选择的依赖组合也通过带锁文件校验的安装。单独求解表示版本约束相容，组件的视觉和平台交互仍需在后续试用时验证。

| 库 | 参考版本 | 项目配置与取舍 |
| --- | --- | --- |
| [shadcn_flutter](https://pub.dev/packages/shadcn_flutter) | 0.0.55 | **主组件库，锁定 0.0.55**。主题、表单、弹层和密集桌面组件统一。先在现有 Material 壳中用 `ShadcnLayer` 验证主题及浮层上下文，随后按页面迁移。 |
| [shadcn_ui](https://pub.dev/packages/shadcn_ui) | 0.61.2 | 组件可定制且文档丰富，与主库覆盖重叠，保留参考。 |
| [forui](https://pub.dev/packages/forui) | 0.28.0 | 首选备选，主题和跨平台组件完整。最低 Flutter 3.50、Dart 3.14，适合在主库试做评估后再决定。 |
| [fluent_ui](https://pub.dev/packages/fluent_ui) | 4.17.0 | 参考 Windows 的菜单、焦点、键盘与交互细节，共用组件继续用主库。 |
| [shad](https://pub.dev/packages/shad) | 1.0.2 | 参考 Serverpod 维护的主题及组件 API，主库已覆盖此用途。 |
| [macos_ui](https://pub.dev/packages/macos_ui) | 2.2.2 | 圆角与侧栏视觉参考，目标平台是 Windows 和 Android。 |
| [fl_chart](https://pub.dev/packages/fl_chart) | 1.3.1 | 锁定 1.3.1，实时流量曲线及统计。后续限制窗口样本和重绘频率。 |
| [lucide_icons_flutter](https://pub.dev/packages/lucide_icons_flutter) | 4.0.3 | 锁定 4.0.3，产品线性图标。通过一个项目级图标入口统一尺寸及笔画，以 release 构建验证字体裁剪。 |
| [flutter_animate](https://pub.dev/packages/flutter_animate) | 4.5.2 | 锁定 4.5.2，用于入屏和交互，接入项目的减少动效档位。 |
| [window_manager](https://pub.dev/packages/window_manager) | 0.7.0 | 已安装 0.5.2，保持现有原生窗口接口和生命周期。 |
| [bitsdojo_window](https://pub.dev/packages/bitsdojo_window) | 0.1.6 | 与现有窗口和标题栏能力重叠，留作专项候选。 |
| [flutter_acrylic](https://pub.dev/packages/flutter_acrylic) | 1.1.4 | 可做 Windows 材质效果。待测试高对比度、GPU/系统回退与 Android 平台隔离后再决定。 |
| [super_sliver_list](https://pub.dev/packages/super_sliver_list) | 0.4.1 | 节点和日志使用现有惰性列表，等基准确认跳转、变高或滚动瓶颈再引入。 |
| [flutter_staggered_grid_view](https://pub.dev/packages/flutter_staggered_grid_view) | 0.7.0 | 当前 SDK 求解成功，包声明仍标旧 Dart 上限。确定仪表盘确实需要错列布局和滚动能力后再评估。 |
| [data_table_2](https://pub.dev/packages/data_table_2) | 3.0.0 | 锁定 **2.8.0**。3.0.0 可求解，但它要求 `material_ui` 的 DataRow/DataColumn，与现有 Flutter Material 类型混用时编译失败。2.8.0 在现有 Material 环境中通过渲染试验。用于固定表头、高密度连接记录。 |
| [tray_manager](https://pub.dev/packages/tray_manager) | 0.9.0 | 已安装 0.5.3，维持现有 Windows 托盘和退出行为。 |

新锁定 5 个直接依赖及 9 个传递依赖，原锁定依赖版本无变动，Flutter SDK 区间与现有锁文件一致。新库均无需注册平台原生插件，现有 Windows 窗口与托盘仍由既有代码管理。后续 Windows 的窗口、托盘、材质 API 通过桌面平台入口接线，Android 继续使用自身的窗口生命周期和导航。新库当前没有页面调用，Windows 和 Android 可先独立验证依赖、打包与字体资源，再验证实际新组件的行为。

## 后续设计约定

- 保持 Windows 桌面和 Android 手机共用语义令牌。本次工作分支仍采用现有酒红／粉色主题。深绿色圆角方案按本次需求记为下一轮视觉方向，先完成深绿表面、文字、品牌色与状态色的对比度试板。
- 桌面采用可缩放的高密度工作区。侧栏支持收起，标题栏和状态栏对齐内容，运行状态与当前出口常驻。仪表盘把当前链路、上下行和出口质量放到首屏。节点列表和设置按密度、扫描顺序和键盘可达性验收。
- 建议以 `A = 56` 逻辑像素作为卡片纵向模块。三档基准高度为 `2A`、`3A`、`4A`，宽度为 `A` 的整数倍并允许按栏伸缩，内部间距使用 4/8/12/16/24 的级差。字体缩放及翻译拉长时允许卡片增高。大操作区先以缩小 20%–30% 为试做目标，保留阅读字号、触控区和有效空白。
- 国旗渐变保留在出口状态卡的小范围内，国家文字提供独立可访问名称。圆角按输入控件、容器和弹层分级。边界用低对比细线组织，键盘焦点和重要状态使用独立的高对比提示。
- 页面转场和微交互先试 120–220 ms。为选中、悬停、按下、加载、空列表、失败和减少动效分别定义反馈。减少动效时保留状态变化。实时图表批量更新，减少离屏绘制。
- 以窗口可用宽度和内容条件确定布局切换，验收 Windows 窄窗与常见高 DPI、键盘顺序，以及 Android 触控、安全区和文字缩放。后续先做一组可预览组件与一张代表性仪表盘，再扩到节点、连接记录和设置。

## 验证及 Git 范围

- 项目技能离线校验通过，共 24 个技能、374 个文件，另附 7 份上游许可证。UI UX Pro Max 本地 Flutter 查询与 39 个核心自测通过。
- `flutter pub get` 与 `flutter pub get --enforce-lockfile` 均通过。`flutter analyze --no-fatal-infos` 通过。默认 `flutter analyze` 返回 1，因为 216 条 info 参与退出码。与同一 SDK、同一命令下的基线分析逐条对照，新增诊断、warning 和 error 均为 0。
- 临时组件试验通过 2 项，覆盖 shadcn_flutter 按钮点击，以及 fl_chart、Lucide、flutter_animate、data_table_2 在现有 Material 上下文的渲染。
- Linux 下显式设置 sing-box 1.14.4 和 CJK 测试字体后，增加本地 TLS 测试夹具后，现有 Flutter 测试 127 项通过，3 项 Windows 原生测试跳过。Windows 原生窗口、系统代理、TUN 及 Android VPN 真机行为需分别验收。
- 变更范围为 `.agents/skills/`、`.agents/skill-licenses/`、`.agents/skills-lock.json`、`.gitattributes`、`AGENTS.md`、`tool/verify_ui_skills.py`、本报告、`pubspec.yaml` 与 `pubspec.lock`。现有页面、自定义组件、代理逻辑、核心、系统接线和发布流程均保持源文件原样。
