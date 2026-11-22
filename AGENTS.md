# Tokiboshi 协作约定

- 默认中文。保留用户已有改动，区分已实现、已验证和待完成。
- 用户于 2026-11-15 JST 明确要求：每次完成工作或记录项目笔记，都同步到 https://github.com/kurumiZafkiel12/AI-Workspace 的 `projects/tokiboshi/`；个人核实笔记可进 `columns/codex/notes/`。先阅读该仓库 `AGENTS.md`、相关项目入口和最新状态。无法访问或推送时明确报告，不声称已同步。
- 不在源码仓库、共享笔记或日志中写入真实订阅 URL、令牌、节点凭据。
- 本项目支持 Windows，以及用户于 2026-11-17 明确委托适配的 Android（Flutter + Rust + sing-box/libbox）。Linux 测试不能替代 Windows GUI/系统代理/TUN 或 Android VPN/后台服务与各 ABI 发布构建验证。Android 模拟器通过也不等于所有真机/OEM通过。
- Rust 测试使用锁文件；真实内核集成测试需要显式设置 `SING_BOX`，测试提前返回不算真实内核验证。

## UI 开发技能

- UI 任务先从项目根目录的 `.agents/skills/<名称>/SKILL.md` 读取所需技能。视觉方向、排版和设计规范用 `ui-ux-pro-max` 与 `flutter-design-system`。组件落地、响应式和动效用 `flutter-implementation`、`flutter-build-responsive-layout` 与 `flutter-motion`。验收用 `flutter-visual-qa` 和 `flutter-add-widget-test`，再按任务选用可访问性或集成测试技能。
- 采用 `shadcn_flutter` 时读取 `shadcn-flutter`。组件 API 以锁定版本为准。主题和布局设计规范见 [UI 开发环境](docs/ui-development-environment.md)。
- `.agents/skills-lock.json` 记录上游源码提交、许可证和文件树校验值。标记为 `flutter-archive` 的技能是 Flutter 官方历史参考，优先使用当前技能与官方文档。查询 UI UX Pro Max 可在仓库根目录执行 `python3 .agents/skills/ui-ux-pro-max/scripts/search.py "<关键词>" --stack flutter`。
- 技能更新时审查来源、脚本和许可证，保留完整技能目录，并运行 `python3 tool/verify_ui_skills.py`。初次检出即可读取技能。
