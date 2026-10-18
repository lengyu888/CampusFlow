# PR #30：43 处原生编译诊断的源码修复

本轮只修复学长在提交 `4b759f88dd0de0507a999954a4da51a8b400284c` 上复现的 ArkTS 错误及直接关联的同类调用，不增加功能或改变配色。两个仓库仍在各自的 `dev/haohao` 追加提交，使用现有 PR；没有修改 main、安装或执行原生环境。

## 原始结果与本轮边界

- [原生审查与 43 条完整诊断](https://github.com/lengyu888/CampusFlow/pull/30#pullrequestreview-5562007111)：Windows / DevEco 6.1.1 / HarmonyOS SDK 6.1.1.125 API24 / ArkUI-X API24，构建退出码 1；汇总 `ERROR:44 WARN:61`，列出了 43 处具体位置，没有生成本次 HAP。
- [学长补测结果](https://github.com/lengyu888/CampusFlow/pull/30#pullrequestreview-5562018742)：同一旧提交的 Windows 后端 947 通过、1 跳过、2 项真实模型测试排除；客户端 1156 通过、1 跳过；连续离线流程 14 步通过。它们不能抵消原生编译失败。
- 以下“修复”指源码中的报错原因已逐项处理并做离线回归，**不表示新的 CompileArkTS、PackageHap 或模拟器验收已经通过**。原生复编仍由学长在新提交上完成。

## 全部诊断的处理

编号沿用原生审查，不因修复后的行号变化重编号。[逐条记录](evidence/arkts-review-43-repair.json) 保留原路径、行列号和原语句，便于核对。

| 原诊断编号 | 位置／原因 | 修复方式及保留行为 |
| --- | --- | --- |
| 1、2 | DraftStore 的持久化操作与输入类型同形异名 | `DraftOperation extends DraftOperationInput`；保留存储字段、指纹、复制和校验。 |
| 3、13 | 已收窄的请求异常再传给仅接受 Error 的 helper | helper 明确接受 `Error \| CampusFlowRequestError`，保留错误码分类、删除会话阻断和未知结果核对。 |
| 4–12、35、36 | 候选、已保存任务和计划缺少共同具名类型 | 候选任务复用 `PlanningTaskDraft`，已保存任务／计划显式继承其字段类型；不改运行期格式、回执和课内许可验证。 |
| 14 | TaskStatus 的嵌套持久化对象没有明确类型 | 按完成／恢复种类构造 `DraftTaskStatusRequest`，再构造 `DraftTaskStatusOperation`；原操作 ID、版本及完成回执保持不变。 |
| 15、18、19 | 原生错误对象在回调中依赖结构兼容 | 拒绝回调明确接收 `NativeBridgeError`，语音错误转换明确接收两种实际错误类型；保留 `instanceof`、安全提示、一次终结与迟到事件清理。 |
| 16、17、20–22、24、25、37、39 | map 返回的对象没有具名上下文 | 返回类型明确为提醒项、课内确认、历史消息、会话条目、许可选择、日历日期或导航栈；继续复制字段／数组，避免快照共享。 |
| 23、30、31、34 | 草稿和 API／录课模型同形异名 | 草稿的运行请求、课程、导入问题、校园地图及地点、课内确认／许可复用其实际类型；持久化格式和逐字段验证保留。 |
| 26、27 | ready 源行的 entry 仍可能为 null | 先读取局部值并排除 null，再进行原字段和课程身份核对；非法行仍使整批预览失败。 |
| 28、29 | source_event_count 仍可能缺失 | 局部值先校验 number，再校验整数、1–500 范围及与完整行数一致；不采用部分结果。 |
| 32、38 | 可空 submission 内的对象缺少明确类型 | 分别构造具名 `OnboardingSubmission`／`TimetableSubmission` 后赋值；冻结请求和草稿恢复行为保留。 |
| 33 | Onboarding 已收窄的异常传入 Error helper | 传入状态码、错误码、消息等原始字段；未识别异常传安全缺省值，保留登录失效、422、导入错误及网络失败提示。 |
| 40、41 | FeedbackPanel helper 覆盖系统属性方法 | 改为 `panelBackground`／`panelBorderColor` 并同步调用；颜色及交互不变。 |
| 42 | CourseReviewPanel 的 enabled Prop 与系统方法冲突 | 改为 `reviewEnabled` 并更新全部两处调用；进行中及待核对时的禁用表达式不变。 |
| 43 | PlanCenterPage 使用 AgendaRow 但未导入 | 从已有 `DailyAgenda` 模块显式导入原类型。 |

类型改法参考[官方 ArkTS 适配规则](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/quick-start/typescript-to-arkts-migration-guide.md)。没有新增 `any`、强制断言、忽略检查或删除出错功能。测试加载器仅调整新增加的纯类型 import 的剥离，仍执行实际生产方法。

## 验证与重新编译

2026-10-18 本轮本地 Mac 回归：客户端 1163 项中 1159 通过、0 失败、4 跳过（本机缺 JDK 的辅助检查 1 项、仅 Windows 执行的夹具 3 项）；后端 948 通过、2 项真实模型测试排除；Ruff 通过；工程预检 92 个 ArkTS/TS、21 个配置通过；客户端与真实 ASGI/SQLite 的连续离线流程 14 步、89 次请求通过。模型使用脚本替身，不访问真实模型或校园账号。新增 6 项行为测试覆盖错误回调、非法导入、确认快照与忙碌保护、历史复制、首次配置失败保留草稿。

后端使用现有虚拟环境及 `PYTHONPATH=src` 验证本工作树；第一次未指定源码路径的调用读到了环境里早期安装的旧包，收集失败，未把它算为产品回归结果。没有通过重新安装原生环境或删测试绕过失败。

两个仓库各自的新提交号和 GitHub Windows／Linux 完整检查结果记录在现有 PR；检查必须对应各自的新提交，不把上一个提交的结果作为本轮结果。上述本机跳过项也不冒充 Windows 或原生验证。

请学长在 `lengyu888/CampusFlow` 已有工作副本保存自己的本地改动后，更新 `dev/haohao`，核对 PR 所列完整提交号，并用原来失败时的相同环境与 `assembleHap` 命令重新编译。编译日志需保留完整上下文、退出码和当前 SHA；成功时记录本次生成 HAP 的路径和 SHA256，再进行安装与 UI 流程验证。报错时直接提供完整日志，继续在同一分支修复。

当前 PR 保持 Draft；原生复编结果回来前不合入 main。后端、Node 逻辑测试、网页预览和旧版模拟器画面都不能替代本提交的原生结果。
