# 项目文档索引

文件夹名称：**项目文档（`docs/project-documents/`）**。

原 `docs/` 中的 46 份 Markdown 已集中到本目录，设计与实施方案保留原有子目录层级。
正文保留已有成果和历史记录，只跟随目录调整本地引用；图片、原型、证据和 JSON 清单仍放在 `docs/` 的原位置。

组员可先读 [Agent 累计变更说明](agent-improvements-changelog.md)、[会话约束记忆](session-context-memory.md)和[固定验收基线](agent-evaluation-baseline.md)。后续相关提交继续使用唯一分支 `codex/agent-improvements`。

## Agent 优化与记忆

- [Agent 固定验收基线](agent-evaluation-baseline.md)
- [Agent 改进分支与累计变更](agent-improvements-changelog.md)
- [CampusFlow Agent：RAG、MCP 与运行框架说明](agent-runtime-architecture.md)
- [CampusFlow 完整 Agent 体系改进方案](agent-system-upgrade-plan.md)
- [校园知识检索扩展与优化方案](campus-knowledge-retrieval-upgrade-plan.md)
- [Agent 回复的 Markdown 显示](markdown-rendering.md)
- [同一会话学习约束记忆](session-context-memory.md)
- [Session Context Memory Implementation Plan](superpowers/plans/2026-10-18-session-context-memory.md)
- [同一会话上下文与约束记忆设计](superpowers/specs/2026-10-18-session-context-memory-design.md)

## 工程与协作

- [CampusFlow 小组会议稿：现有 Agent 展示与下一轮优化分工](2026-10-16-小组会议稿与任务分工.md)
- [CampusFlow 架构（截至第十六阶段）](architecture.md)
- [ArkUI-X 与 Agent 服务联调说明](arkui-x-integration.md)
- [开发日志](development-log.md)
- [CampusFlow 分阶段开发与验收计划](development-phases.md)
- [模型目录与供应商接入](model-providers.md)
- [CampusFlow 第九至十六阶段](roadmap-9-16.md)

## 开发阶段记录

- [完整计划展示与验收](stage-1-plan-display.md)
- [第二阶段：真实工具摘要与失败恢复](stage-2-agent-feedback.md)
- [第三阶段：长内容、输入区与地图适配](stage-3-mobile-content-layout.md)
- [第四阶段：本地历史与三端构建前置核验](stage-4-local-history.md)
- [第五阶段：核心页面质感与内容层级](stage-5-core-page-polish.md)
- [第六阶段：Agent 语音输入与回答播报](stage-6-voice-interaction.md)
- [第七阶段：首次引导、手动课表与导入预览](stage-7-onboarding-timetable.md)
- [第八阶段：课表冲突提示与原任务改期](stage-8-timetable-replanning.md)
- [第九阶段：整体设计与可点击原型](stage-9-product-design.md)
- [第十阶段：三个核心页面落地](stage-10-core-pages.md)
- [第十一阶段：全应用体验与课表维护](stage-11-unified-experience.md)
- [第十二阶段：计划执行可靠性](stage-12-reliable-planning.md)
- [第十三阶段：可查询和恢复的 Agent 运行](stage-13-agent-runtime.md)
- [第十四阶段：真实数据与依据](stage-14-data-evidence.md)
- [第十五阶段：语音、系统提醒与三端构建入口](stage-15-native-capabilities.md)
- [第十六阶段：模型适配、主动偏好与有出处的校园资料](stage-16-selected-enhancements.md)

## 交互与视觉设计

- [CampusFlow 设计契约 v1](design-system.md)
- [UX01｜行简视觉方向与浏览器验收](ux-01-brand-directions.md)
- [UX01｜行简：官方参考、设计取舍与代码落点](ux-01-reference-notes.md)
- [UX02｜纸页主题、中文品牌与原创插图](ux-02-visual-foundation.md)
- [UX03：渐进引导与本机草稿恢复](ux-03-onboarding-drafts.md)
- [UX04：快速语句与课程路线](ux-04-capture-parser.md)
- [UX04：今日、轻记录、课程路线与课内安排](ux-04-today-capture.md)
- [UX05：会话接续、可解释提案与语音输入区](ux-05-assistant-flow.md)
- [UX06：计划检索、一周安排与课内提醒](ux-06-planning-overview.md)
- [UX07：连续录课、逐行导入和清楚的设置入口](ux-07-campus-forms.md)
- [课内任务：允许设置，保留提醒与确认](ux-course-overlap-policy.md)
- [行简：共享界面与交互契约](ux-design-contract.md)
- [行简体验升级：UX01–UX12](ux-roadmap.md)
- [行简原创插图记录](xingjian-illustrations.md)

## 配套资料

- [浏览器原型与验证脚本](../previews/)
- [验证记录与合成数据](../evidence/)
- [插图机器清单](../xingjian-illustrations.json)
- [仓库首页](../../README.md)

本文是分类索引，不将历史方案或离线验证解释为已完成的真实模型、设备或远端整合验收。
