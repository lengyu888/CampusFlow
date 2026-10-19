# Session Context Memory Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 同一会话早期显式学习约束在裁剪后仍可用，修改与撤回不会复活旧值。

**Architecture:** 从冻结用户原文重建最多四个字段的不可变投影，仅序列化规范化值、状态和来源编号。
共享完整回合预算选择器；新运行循环每步检查，旧 LangChain 入口由模型请求 middleware 每步检查。

**Tech Stack:** 现有 Python、LangChain、pytest；无新增依赖、数据库表、模型调用或前端改动。

**Spec:** [已确认设计](../specs/2026-10-18-session-context-memory-design.md)

## Global Constraints

- 在当前 `codex/agent-improvements` 工作区修改，保留已有未提交文件；不创建提交或推送。
- 原始历史、冻结快照、取消、身份隔离、提案人工确认继续沿用现有契约。
- 每日和单次时长为 1–1440 分钟；时段限上午、下午、晚上；歧义不猜测。
- 字符预算包含系统提示、约束资料、工具 schema、当前工具交互和历史；必需内容超限明确失败。
- 原始用户文字不得作为系统指令拼入投影；跨会话记忆和通用摘要不在范围内。

## Review Focus

- 撤回后近期原文仍包含旧值：投影保留撤回状态，模型规则不得从旧回合重新采用该值。
- 条件、引述和临时日期的数值：保守跳过，不转成无期限约束。
- 多轮工具调用后历史已被裁剪：投影从最初冻结历史建立并保持，不重复从后缀提取。
- 兼容入口内部工具续轮：每次实际模型请求都检查预算，完整保留当前工具交换。
- 同一服务实例顺序/并发请求：不共享可变投影，持久历史重载不改变来源顺序。

## Task 1：约束投影与完整回合预算

**Files:** 新增 `agent-service/src/campusflow_agent/conversation_context.py`、`agent-service/tests/test_conversation_context.py`。

**Interfaces:** `project_constraints(history, message) -> tuple[Constraint, ...]`；
`memory_prompt(constraints) -> str`；`dialogue_pairs(history) -> list[list[dict]]`；
`bounded_context(system, history, turn, tools, limit) -> list[dict]`；共享 `AgentBudgetExceeded`。

- [x] 先写测试：四字段创建/替换/撤回/全清、中文时长、歧义、排除资料、序列化与预算完整性。
- [x] 运行测试，确认新模块缺失导致失败；实现有限完整句匹配与按时间投影，不使用模糊关键词猜测。
- [x] 验证所有专项通过；原始历史不变，投影最多四个字段，规范化输入不包含任意原文。

## Task 2：两个入口接入

**Files:** 修改 `agent-service/src/campusflow_agent/agent.py`；新增
`agent-service/src/campusflow_agent/context_middleware.py` 与 `agent-service/tests/test_context_integration.py`；
更新 `agent-service/tests/test_baseline_context.py`。

**Consumes:** Task 1 的投影、提示及预算选择接口。
**Produces:** 新 run 与旧 chat 同一历史得到相同投影；旧入口模型续轮受相同预算限制。

- [x] 将旧约束丢失检查改成正向保留断言并运行，证明接入前失败。
- [x] 写实际供应商请求边界检查：替换、撤回、多次工具续轮、账户/会话隔离、冻结输入与持久重载。
- [x] 接入一次性投影；兼容 `_build_graph` 增加可选系统提示；middleware 只改传往模型的消息后缀，不改图状态或持久历史。
- [x] 用实际 LangChain + 离线 HTTP transport 验证旧入口参数与工具续轮预算；必要内容超限时停止下一次请求。
- [x] 运行专项及已有模型、偏好、运行、会话和提案回归。

## Task 3：固定基线与交付

**Files:** 修改场景清单、基线说明、累计摘要；新增本地修改日志。

- [x] CF-28 改为约束保留目标，增加修改/撤回及隔离场景；保留既有 v1 报告，生成新版本文件。
- [x] 完整离线 pytest、相关 Ruff、基线运行器、`git diff --check`；检查新增未跟踪文件的空白。
- [x] 依据 requesting-code-review 技能请求独立只读审查，处理有效的重要问题并复验。
- [x] 写实际结果与未执行检查；日志列出所有实际文件和风险，不把离线输入检查称为真实回答质量通过。

## 执行记录

用户已明确要求“按照你的设计进行代码修改”，据此在本聊天连续实施，不再重复申请同一修改授权。
采用当前固定优化分支，避免新工作树遗漏上一任务尚未提交的基线文件。
任务结果与设计细节裁决将在此追加；提交/推送步骤不执行。

- Task 1：先观测模块缺失失败，再实现；最终解析与预算专项 66 项通过。
- Task 2：先观测接入前 10 项失败，接入后通过；最终包含 11 项入口检查和 2 项基线输入检查。
- Ruling：旧 chat 使用真实 LangChain 模型请求 middleware 检查每轮预算，避免只裁剪首次输入；超长活跃工具结果明确失败，保留新 run 已有摘录规则。
- Ruling：临时范围在句内向后传播，条件/第三方来源保留完整句作用域；问句设置不保存，独立撤回可以后接无关规划问句，确认性“可以吗”不当作已撤回。
- Review：独立代理复现撤回被吞、条件/来源误识别和作用域回归；逐项增加失败测试后修正，复核具体发现已解决，专项 79 passed。
- 基线 v2：38 个场景、94 项检查通过；模型质量仍未评测。
- Task 3：完整后端离线回归 855 passed、2 deselected，89.28 秒；相关 Ruff 与差异检查通过，13 个任务文件空白检查通过。本地独立报告按修改日志规则新增，未提交或推送。
