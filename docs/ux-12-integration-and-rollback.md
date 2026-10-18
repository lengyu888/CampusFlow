# 行简｜接口、存储与回滚交接

本说明核对的是 UX11 已发布基线 `fce0e1d2f46329d1d3552924be890ca0653866d3`，在 UX12 交接分支整理。前后端请使用配套阶段；中文名“行简”不要求修改原应用包名、数据库路径或本机文件名。

**本轮核对源码、既有离线证据和素材文件，没有执行真实数据库升级、备份还原、旧客户端降级或三端安装升级。** 下文的回滚步骤是交接建议，不是已通过的演练记录。设备操作另见[赛事与设备验收表](ux-12-competition-acceptance.md)。

## 1. 接入时保留的协议

下表路径统一以 `/api/v1` 为前缀，均按当前登录用户鉴权。请求和响应的完整字段以 [ApiModels](../arkui-x-client/entry/src/main/ets/model/ApiModels.ets)、[FocusModels](../arkui-x-client/entry/src/main/ets/model/FocusModels.ets)、[ReviewModels](../arkui-x-client/entry/src/main/ets/model/ReviewModels.ets) 及服务端 schema 为准，不按显示标题匹配业务对象。

| 流程 | 当前入口与关键字段 | 接入约束 |
| --- | --- | --- |
| 首次录课 | `GET /onboarding` 取得 `revision/user/timetable/campus_map`；`GET /onboarding/campus-data?school=&campus=` 只读预览支持校区的参考包；`PUT /onboarding` 带原 `operation_id`、`expected_revision`；`GET /onboarding/operations/{id}` 查回执 | 当前客户端提交前先持久化冻结课表和原操作。参考包入口不提前修改账号。省略操作字段的旧兼容路径仍存在，但没有当前恢复保证，不能用于新页面。 |
| 日常课表 | `GET/PUT /me/timetable`；PUT 为 `entries/expected_revision/operation_id/confirm_clear`；`GET /me/timetable/operations/{id}` | 课程是六字段的具体日期记录，最多 500 条，不是每周重复规则。空表需显式清空；恢复旧草稿保留旧基线，不能改绑当前 revision。 |
| 助手与续聊 | `POST /agent-runs`，原 `run_id/session_id/message/model`，可显式带 `session_mode` 与 `expected_context_revision`；`GET /sessions/{id}/context`；原 run 的 GET、events 和 cancel | `continue` 必须先读授权上下文和版本；旧四字段请求不加新默认字段，保留原幂等摘要。历史正文不恢复为可执行旧提案；删除会话的墓碑阻止旧请求复活。 |
| 任务与目标提案 | `POST /planning/actions`；`GET /actions/{proposal_id}`；POST 同 ID 的 `/confirm`、`/cancel` | 可执行候选需 `contract_version:2`、目标 ID、完整前后值、有效期与当前状态。确认按 receipt 的精确实体 ID 处理，状态查询或取消不证明“从未执行”。删除计划保留子任务为独立待办。 |
| 课内许可与重排 | 提案 `course_policy_version:1`、`course_reviews`、`state_version`；`POST /actions/{id}/course-permissions`；`GET /planning/conflicts`；POST/GET `/planning/replans` 及 `/{id}/confirm` | 课内同意绑定本候选和当前课程摘要，不能只存一个布尔值当永久许可。替换许可先查原提案的 `replacement_proposal_id`；课表变化后重排预览须重新确认，过期/版本变化不自动提交。 |
| 完成与恢复 | `POST /tasks/{task_id}/status-operations`；GET `/task-status-operations/{id}`；POST `/{id}/confirm`、`/{id}/cancel` | complete 带原操作 ID、任务版本；restore 另带 `source_operation_id`，生成待确认预览，必要时提供本次课内 ACK。receipt 记录这次变更，不代表任务此刻仍是该状态。旧 PATCH `completed:false` 返回 `TASK_RECOVERY_PREVIEW_REQUIRED`。 |
| 专注 | `POST /focus-records/{record_id}/operations`；GET `/focus-operations/{id}`、`/focus-records/active`、详情及列表 | request 带操作 ID、原 revision、device ID；暂停/结束上传已封存 intervals 与 unknown gaps。只上传墙钟时间和 `elapsed_ms` 差值，不上传原始 monotonic。未知结果先 GET，不自动换 ID、重发或改基线。列表只含已结束记录，并绑定完整分页快照。 |
| 日/周回看 | `GET /reviews?period=day\|week&anchor=YYYY-MM-DD` | `contract_version:1`，固定 `timezone_policy:fixed_utc_plus_08`；总量可从完成证据和微秒裁剪片段复算。当前仍完成、当前待安排与已确认专注分别说明。感受仅在本机，默认不放入助手摘要。 |

对应服务入口见 [api.py](../agent-service/src/campusflow_agent/api.py#L600)、[schemas.py](../agent-service/src/campusflow_agent/schemas.py)、[focus_schemas.py](../agent-service/src/campusflow_agent/focus_schemas.py)、[review_schemas.py](../agent-service/src/campusflow_agent/review_schemas.py)。无命中、权限不足、过期或无法核实的结果必须保留真实状态，不能补默认字段伪装成功。界面隐藏/换号后的旧回包不能写回新账号。

## 2. 数据库怎样变化

默认路径是 `data/campusflow.db`，相对于实际服务启动目录；交接时先确认部署配置，不能拿默认值当真实位置。[create_app](../agent-service/src/campusflow_agent/api.py#L258) 将该路径交给账号、规划及相关服务；[ActionService](../agent-service/src/campusflow_agent/action_service.py#L95) 要求账号和规划使用同一个真实 SQLite 文件。

当前采用启动时 `CREATE TABLE IF NOT EXISTS`、检查缺列再 `ALTER TABLE`、创建索引/触发器。源码未提供统一 schema 版本号、Alembic 迁移链或反向迁移命令。各模块分别提交，**不是整个应用初始化的一次原子迁移**；中途启动失败时可能已添加部分结构。

| 范围 | 启动行为及需保留的内容 |
| --- | --- |
| 账号与外部连接 | [accounts.py](../agent-service/src/campusflow_agent/accounts.py#L64) 补角色、加密凭据、课表来源时间等列，并保存引导/课表回执。无管理员时会将最早用户设为管理员，不能称启动绝不更改旧行。 |
| 规划版本与课内许可 | [course_policy.py](../agent-service/src/campusflow_agent/course_policy.py#L47) 在独立事务内补列/表并更新触发器：旧课表版本从 0 起，旧任务 `task_version` 从 1 起、课内许可默认为 false、完成来源为空。不会回填虚构完成回执。 |
| 提案与任务状态 | [action_service.py](../agent-service/src/campusflow_agent/action_service.py#L115) 保存快照摘要；[task_status_service.py](../agent-service/src/campusflow_agent/task_status_service.py#L32) 保存状态操作和回执。业务写入以版本校验和事务仲裁，不能删除操作表来消除未知状态。 |
| 会话和运行 | [run_service.py](../agent-service/src/campusflow_agent/run_service.py#L61) 保存运行、事件、worker 租约和 run 墓碑；[session_service.py](../agent-service/src/campusflow_agent/session_service.py#L42) 保存会话墓碑。失联工作在租约到期后标为 interrupted，不自动重新调用模型。 |
| 专注与回看 | [focus_service.py](../agent-service/src/campusflow_agent/focus_service.py#L77) 保存记录、片段、操作和删除墓碑，同账号只容许一个 running/paused 记录；[review_service.py](../agent-service/src/campusflow_agent/review_service.py#L146) 添加读取索引并从原始事实汇总，不迁移出一份虚构历史报告。 |

已有针对旧任务默认值、重复打开和触发器替换的离线用例，见 [test_course_overlap_policy.py](../agent-service/tests/test_course_overlap_policy.py#L534)、[test_task_status_operations.py](../agent-service/tests/test_task_status_operations.py#L747)。这些不是所有历史数据库的升级矩阵，也没有证明任意损坏结构可自动修复。

## 3. 本机文件不是跨账号备份库

三个文件都从 [EntryAbility 的 `context.filesDir`](../arkui-x-client/entry/src/main/ets/entryability/EntryAbility.ets#L28) 初始化。作用域为精确的 `[去掉首尾空白和末尾斜杠的服务 URL, user_id]`，不推断域名、端口或 HTTP/HTTPS 等价；改服务地址即换范围。

| 文件 | 当前格式与上限 | 使用和恢复规则 |
| --- | --- | --- |
| `campusflow-local-history-v1.json` | `version:1`；2 MiB 保守预算、最多 20 会话 | 文本历史白名单及删除墓碑，不存密钥、工具原始结果或可执行提案；按最近更新和容量保留缓存，不能保证所有历史一直离线可用。 |
| `campusflow-local-drafts-v1.json` | 文档 `version:1`、record `formatVersion:1`；总 4 MiB、单草稿 2 MiB、20 个共享槽；普通操作和状态操作各最多 40 | 助手、待办、录课、维护课表、回看感受，以及类型化未结操作。槽满不驱逐用户草稿；不存订阅 URL/未接受导入。助手使用 `session:<id>`，旧 main 槽需显式恢复。 |
| `campusflow-local-focus-v1.json` | `schemaVersion:1`；4 MiB、20 记录、100 操作 | 本机 device ID、原请求队列、封存片段和时钟锚点。跨进程只保留已持久的有证前缀，未知尾段写为 gap；不能用离开时长补计，也不能跨设备搬运原始 monotonic 后继续计时。 |

[LocalHistoryStore](../arkui-x-client/entry/src/main/ets/utils/LocalHistoryStore.ets)、[DraftStore](../arkui-x-client/entry/src/main/ets/utils/DraftStore.ets)、[FocusStore](../arkui-x-client/entry/src/main/ets/utils/FocusStore.ets) 遇坏 JSON/未知格式会拒绝并保留原文件。DraftStore 切账号先失效 lease，再持久化新范围；FocusStore 遇非空异账号范围要求明确清理。不要把“换号隐藏内容”当作仍有多账号完整存档。

三份 [LocalHistory](../arkui-x-client/entry/src/main/ets/services/LocalHistory.ets)、[LocalDrafts](../arkui-x-client/entry/src/main/ets/services/LocalDrafts.ets)、[LocalFocus](../arkui-x-client/entry/src/main/ets/services/LocalFocus.ets) 驱动分别使用同目录临时文件、完整写入检查、fsync 和 rename。它们是单文件替换，不是三文件或客户端与服务端的联合事务。现有 Node 文件 shim 证据不等于原生文件系统、系统备份或卸载重装验收。

退出/清理需先提示未发送草稿、未结操作和未同步专注；清除本机不会撤销已发往服务器的写入。若无法核对，不要为回退旧版而删除原 ID 指针或离线队列。

## 4. 已确认的降级风险

| 组合 | 源码核对结果 |
| --- | --- |
| UX05 `3e2f7a9` 客户端读最新草稿 | 旧 `DraftStore.cloneDocument` 只重建 records/operations，会遗漏后来新增的 `taskStatusOperations`。再次写盘可能丢失状态操作的本机恢复入口，即使文件仍叫 v1。 |
| UX08 `9d9743b` 客户端读含感受的草稿 | 旧 kind 白名单不认识 `review-note`，会拒绝整份文件；手工删除感受以使其启动不是无损降级。 |
| 最新客户端配旧服务 | session context、task-status、focus、review 或新引导参考包入口可能不存在。尤其 UX11 的 `/onboarding/campus-data` 修复新账号尚无学校时的首次保存闭环，不能退回预先修改账号资料绕过旧接口。 |
| 旧客户端继续写最新数据库 | 新版本已加强任务恢复、会话和版本校验。旧界面/端点调用与新状态规则并不等价，不能因数据库能打开就声称业务兼容。 |

因此只承诺当前配套版本的实现与已有证据。若只需撤回视觉调整，优先在当前协议/存储实现上回退具体 UI 改动，再验证该分支；不要直接换成旧客户端二进制并继续写最新本机文件。

## 5. 回退前的操作顺序（尚未演练）

1. 记录前后端 SHA、应用身份、实际数据库路径与配置。先按原 ID 查询未知操作；明确处理本机正在计时、未同步记录和未发送草稿，无法核对时保留现版本及原文件。
2. 停止业务写入和 worker，再制作一致性 SQLite 备份，或采用经运维验证的 SQLite 备份方式。不要在仍写入时只复制单个 `.db` 并假定完整；本文不假定部署启用了 WAL，也未提供已验证的备份脚本。
3. 单独受控保管对应密钥：[KeyVault](../agent-service/src/campusflow_agent/key_vault.py#L13) 生产使用 `APP_SECRET_KEY`，开发默认数据库旁的 `.campusflow.key`。只有数据库而缺原密钥，可能无法解密既有模型/外部连接凭据。密钥不进 Git、共享 ZIP、截图或报告。
4. 保留本机三份原文件；其提取和恢复方法需由已有设备环境验收。数据库备份、设备文件和密钥不是同一个恢复点，不能自动覆盖并重发未结请求。
5. 在副本上运行目标配套版本，核对精确 ID、课程 revision、任务版本、课内许可、操作回执、删除墓碑和专注队列。失败时保留副本及安全错误，不删新列、表、触发器或墓碑“修复”。
6. 仅在上述检查通过后决定切换。恢复升级前数据库会丢失备份之后的事实；这属于回到较早数据点，不是无损撤销代码。需要明确数据窗口，并核对各设备仍持有的原操作。

## 6. 队友可复用的验证入口

在已有依赖环境中，`arkui-x-client` 的 `npm test`、`npm run check` 是离线客户端与静态检查；`npm run test:journey` 另需配置已有 Python 环境 `CAMPUSFLOW_TEST_PYTHON`，运行真实 FastAPI/SQLite 与实际客户端逻辑的合成旅程。不要为通过交接而跳过依赖错误或把供应商替身称作真实云模型。

[UX11 旅程记录](evidence/ux-11-journey.json) 已保存 14 步、88 次 HTTP 的现版本闭环证据；原供应商流、订阅传输和系统能力边界有明确替身标识。它不覆盖真实升级/回滚。设备还需验证：安装升级后同范围历史/草稿、未知原 ID 查询、离线专注中断、退出清理失败和三端私有文件行为。

素材接入与原始生成记录见[七图清单](xingjian-illustrations.md)，本阶段文件解码、属性、SHA-256 和生产引用核验见[素材核验 JSON](evidence/ux-12-artwork-checks.json)。源码接入不等于原生加载/渲染通过。
