# Tokiboshi 协作约定

- 默认中文。保留用户已有改动，区分已实现、已验证和待完成。
- 用户于 2026-11-15 JST 明确要求：每次完成工作或记录项目笔记，都同步到 https://github.com/kurumiZafkiel12/AI-Workspace 的 `projects/tokiboshi/`；个人核实笔记可进 `columns/codex/notes/`。先阅读该仓库 `AGENTS.md`、相关项目入口和最新状态。无法访问或推送时明确报告，不声称已同步。
- 不在源码仓库、共享笔记或日志中写入真实订阅 URL、令牌、节点凭据。
- 本项目是 Windows 专用 Flutter + Rust + sing-box 客户端。Linux 测试不能替代 Windows GUI、系统代理、TUN 和发布构建验证。
- Rust 测试使用锁文件；真实内核集成测试需要显式设置 `SING_BOX`，测试提前返回不算真实内核验证。
