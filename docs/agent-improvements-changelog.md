# Agent 改进分支与累计变更

固定协作分支：`codex/agent-improvements`。后续 Agent 相关本地改进继续提交到这一分支，并在本文件追加日期、修改内容和实际验证结果，便于组员持续审查。

## 基线与归属

- 本轮以已确认的组员分支 `feat/ux-07-campus-forms`（`e475d35`）为基线；它相对原本地 `main`（`471864c`）累计包含 23 个提交、304 个文件变化。
- 模型目录、持久运行、账号范围会话与草稿、工具卡片、提案、语音和提醒等新版功能来自组员基线。下文记录的是在此基础上保留、整合或修复的本地成果，不把组员全部功能归为本轮新增。
- 最新获取到的 UX08、UX09 分支尚未纳入本轮发布内容。
- 详细修改报告继续保存在本地忽略目录，不上传 GitHub；本文件提供仓库内可读的累计摘要。密钥、个人数据库、本机配置和构建产物不属于提交内容。

## 2026-10-18：保留本地改进并整合 UX07

### 消息排版与历史展示

- 原生客户端新增 Markdown 解析与消息组件；实时回复和历史详情共用展示路径，支持标题、列表、引用、代码及表格，宽表和长代码可在消息内部横向滚动。用户输入保留原文，未支持或异常内容回退为可读原文。
- 在新版 `MessageContent` 中接入 Markdown，保留组员已有的运行状态、工具、提案和原文切换能力；历史页接入共用消息组件。
- Web 调试页使用随仓库提供的 Marked、DOMPurify 渲染并净化助手回复；原始 HTML 显示为文本，图片显示说明文字，链接限制协议。新增解析、安全性与排版回归用例。
- 入口：[Markdown 支持说明](markdown-rendering.md)、[原生解析器](../arkui-x-client/entry/src/main/ets/utils/MarkdownParser.ets)、[Web 渲染器](../agent-service/src/campusflow_agent/web/markdown.js)。

### 会话状态与聊天滚动

- 保留早期会话 `pending`/`active` 状态与幂等数据库迁移：旧调用先保存用户问题，失败或取消时补充收尾消息；Web 提问后立即显示本地待完成会话，再刷新服务端目录。
- HTTP 会话仍由新版 `SessionService` 校验上下文版本后成对写入，提交成功恢复 `active`；没有将旧持久化逻辑移入新版 `RunService`。
- 修复回答后聊天上翻被拉回底部：只在内容高度变化且允许跟随时贴底；用户上翻暂停跟随，触底或主动发送后恢复。保留新版账号隔离、草稿和运行恢复机制，并适配实际控制器与 UI 回调测试。
- 入口：[会话服务](../agent-service/src/campusflow_agent/session_service.py)、[聊天页面](../arkui-x-client/entry/src/main/ets/pages/AgentPage.ets)、[会话与滚动回归](../arkui-x-client/scripts/test-agent-session.mjs)。

### Windows、ArkUI-X 与 ArkTS 兼容

- 后端声明 `tzdata` 依赖，使 Windows 可用 `Asia/Shanghai`；修正离线测试的事件循环与禁网 fixture 生命周期、Windows 时区切换和巨型参数测试 ID。
- 客户端测试使用 stdin 传递长脚本，兼容 CRLF 导入处理，并用 `fileURLToPath` 转换文件 URL，解决 Windows 子进程长度和路径问题。
- 将 `ignoreCrossPlatform` 移至 SDK 要求的 `buildOption`；处理实际编译检出的 62 项 ArkTS 错误，包括显式接口、命名返回类型、逐字段复制、空值检查、组件成员命名和缺失类型导入，未降低类型检查要求。
- 更新相关类型、页面、偏好与草稿工具、提醒协调和测试脚本；保留构建缓存、预览输出、本机配置与本地修改日志的忽略规则。

### 协作文档

- 保留并整理 Markdown 说明、Agent 架构快照、体系升级方案、会议与任务分工、问题清单及项目协作规则。
- 架构快照和方案带有各自整理日期，方案中的目标与验收要求不代表已实现；以当前源码及本文件的实际变更、验证边界为准。

## 已完成的验证

以下为本轮整合后的实际结果，时间为 2026-10-18（Asia/Shanghai）。

| 检查 | 结果 |
| --- | --- |
| 后端完整离线 pytest | 763 passed，2 deselected；排除的真实服务集成测试未执行 |
| 客户端完整回归 `node scripts/test.mjs` | 961 passed，1 skipped，0 failed；跳过项为宿主缺少 plist 解析器 |
| Web Markdown 回归 | 8 passed |
| 客户端静态检查 | 76 个 ArkTS/TS 文件、24 个配置文件通过 |
| Ruff / pip 依赖检查 | All checks passed / No broken requirements found |
| 鸿蒙 HAP 构建 | BUILD SUCCESSFUL，13.492 秒；unsigned HAP 为 19,028,373 字节 |
| 差异及冲突检查 | `git diff --check`、暂存区检查通过，无未解决冲突；已有 LF/CRLF 提示；仅 DOMPurify 原始 MPL 许可证的行尾空格按精确路径豁免，保留上游文件原文 |

## 尚未验收与已知边界

- 代理未执行模拟器或真机安装、手势与排版验收；未验收 Android/iOS 构建与设备行为、真实语音权限/识别/播报、系统提醒送达。HAP 未签名，仍有语音与提醒跨平台能力等 SDK 告警。
- 代理未调用真实模型、天气或 HDUHelp 服务，未验证个人数据库的运行迁移；离线测试和构建结果不代表这些能力已经验收。
- 旧 Web 调试页仍固定两种 DeepSeek 模型，未接入新版动态模型目录；需要逐项课程重叠确认的提案应通过支持该流程的原生客户端处理。
- 旧调用失败后若历史收尾再次发生数据库异常，仍可能覆盖原模型异常；新版 HTTP 和运行入口不走该路径。
- 回滚时按本分支对应提交逐项撤回并保留后续工作；本地备份和修改报告继续保留，不使用整库重置覆盖既有成果。
