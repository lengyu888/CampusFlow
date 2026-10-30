# CampusFlow Agent Service

## 启动

在本目录执行：

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -U pip
python -m pip install -e ".[dev]"
Copy-Item .env.example .env
python -m uvicorn campusflow_agent.main:app --host 0.0.0.0 --port 8000
```

后续启动只需激活 `.venv` 并执行最后一行。详细环境变量、客户端联调和测试说明见仓库根目录
的 `README.md`。服务启动后访问：

- 健康检查：`GET /health`
- 注册/登录：`POST /api/v1/auth/register`、`POST /api/v1/auth/login`
- 当前用户：`GET /api/v1/me`
- 用户设置/学习数据：`PUT /api/v1/me/settings`、`GET /api/v1/me/context`
- 管理员用户总览：`GET /api/v1/admin/users`
- 视觉导入：`POST /api/v1/onboarding/parse-timetable`、`POST /api/v1/onboarding/parse-map`
- 完成首次配置：`PUT /api/v1/onboarding`
- 预览课表订阅：`POST /api/v1/schedule-subscriptions/preview`
- 连接/查看课表订阅：`PUT /api/v1/schedule-subscriptions`、`GET /api/v1/schedule-subscriptions`
- 同步/断开课表订阅：`POST /api/v1/schedule-subscriptions/sync`、`DELETE /api/v1/schedule-subscriptions`
- HDUHelp 连接状态：`GET /api/v1/hduhelp/status`
- 配置个人访问令牌并同步：`PUT /api/v1/hduhelp/pat`
- 发起/完成 HDUHelp OAuth：`POST /api/v1/hduhelp/connect`、`GET /api/v1/hduhelp/callback`
- 同步/读取 HDUHelp 数据：`POST /api/v1/hduhelp/sync`、`GET /api/v1/hduhelp/data`
- 断开并删除 HDUHelp 数据：`DELETE /api/v1/hduhelp/connection`
- 校园数据包快照：`GET /api/v1/campus-data`
- 地点/步行查询：`GET /api/v1/campus-data/places?query=&origin=`
- 校园路线图：`GET /api/v1/campus-data/route?origin=&destination=`
- 校园通知：`GET /api/v1/campus-data/notices?keyword=&active_only=`
- 用户纠错：`GET /api/v1/campus-data/corrections`、`POST /api/v1/campus-data/corrections`
- Swagger：`GET /docs`
- 对话：`POST /api/v1/chat`
- 工具清单：`GET /api/v1/tools`
- Skills 目录/筛选：`GET /api/v1/skills?query=&category=`
- Skill 详情/审计：`GET /api/v1/skills/{skill_id}`、`GET /api/v1/skills/audit`
- 安装 Skill：`POST /api/v1/skills/{skill_id}/install`
- 启用/停用 Skill：`PATCH /api/v1/skills/{skill_id}`
- 升级/卸载 Skill：`POST /api/v1/skills/{skill_id}/upgrade`、`DELETE /api/v1/skills/{skill_id}`
- 历史：`GET /api/v1/sessions/{session_id}/history`
- 会话目录/搜索：`GET /api/v1/sessions?query=`
- 会话改名：`PUT /api/v1/sessions/{session_id}`
- 已确认事务：`GET /api/v1/tasks`
- 规划总览：`GET /api/v1/planning`
- 快速待办：`POST /api/v1/tasks`
- 完成/恢复待办：`PATCH /api/v1/tasks/{task_id}`
- 删除待办：`DELETE /api/v1/tasks/{task_id}`
- 删除计划卡片并保留其待办：`DELETE /api/v1/plans/{plan_id}`
- 确认事务：`POST /api/v1/actions/{proposal_id}/confirm`

## HDUHelp 按资源精确查询

`get_hduhelp_academics` 与 `get_hduhelp_campus_life` 支持可选 `resource`、`semester`、
`start_date/end_date`、`keyword`、`limit/offset`。不传参数保留旧整组调用；使用筛选或分页时必须指定资源。
例如只查成绩可传 `{"resource":"grades","keyword":"计算机网络","limit":10,"offset":0}`，
只查校园卡传 `{"resource":"card_balance"}`，无需将图书馆和长跑记录一起带入模型。

在对话中，默认先按本轮实际使用的资源向 HDUHelp 自动刷新，再对本轮固定快照做精确查询；
即使原缓存尚未过期，新一轮也重新获取。同轮重复调用/分页共用一次结果，不跨轮复用。
普通闲聊、无关资源以及非法工具参数不会触发刷新。原生有界运行与兼容聊天入口均覆盖。
直接快照接口、手动同步及停用自动刷新时仍按原有效期策略使用缓存，过期资料不会作为当前事实。
先筛选后分页，默认每页 10 条、最多 20 条，结构化资料页另受 3200 字符限制。
检查 `query.status/filter_complete`、`matched_total`、`has_more/next_offset`；有下一页时按实际续读位置查询。
未知、缺失或冲突的日期/学期字段会明确提示筛选不完整，不等同于没有记录。计数只代表已同步快照，
`upstream_complete` 未知；GPA 摘要保留原快照范围，不按筛选条件重算为学期 GPA。
完整读取仍受运行次数与上下文预算约束，超大单条会明确拒绝，不能静默跳过或声称已经读完。

刷新参数默认 `HDUHELP_REFRESH_CONCURRENCY=3`、`HDUHELP_REFRESH_QUEUE_SECONDS=30`、
`HDUHELP_REFRESH_REQUEST_SECONDS=20`、`HDUHELP_REFRESH_TOTAL_SECONDS=60`。
排队有独立的 30 秒上限，获得名额后才开始 20 秒请求期限（包含令牌解析和 HTTP）。
同轮 60 秒只累计活跃刷新阶段的时间，包含该阶段排队；并行重叠区间只计一次，模型思考间隔不计入。
排队与请求仍受剩余活跃刷新额度、规划读取阶段额度及整轮工作期限约束，不保证每项都能用满 20 秒。
达到期限不再启动新的资源请求；刷新不新增模型调用或周期轮询。
同一批需要的资源并发请求，并复用后端 HTTP 连接；后台运行先返回回执，界面通过现有轮询显示
“正在更新校园资料 / 正在读取资料 / 正在分析 / 正在生成提案”，不等待客户端全量同步后才发聊天。

更新成功只加密替换对应资源；失败不推进旧资源同步时间，不清除其他资源的同步错误。
每轮结果与账号/连接凭据绑定；断开、重连或凭据变化时迟到结果不能回写新连接或继续读取。
网络超时、令牌失效和资源权限不足分别说明，不拿旧缓存作为本轮新数据。取消会回收未完成子请求。
刷新只保证本轮从上游获取，不保证上游内部数据实时或分页覆盖全量。课表、待办每轮读取最新本地确认版本，
课表订阅同步/预览确认规则不变，不自动覆盖人工课表。

需要停用时，设置 `AGENT_HDUHELP_AUTO_REFRESH_ENABLED=false` 并重启后端，可恢复 BUG2 修改前的快照读取方式；
BUG1 的分阶段规划开关独立保留。时间预算调整同步更新本机 `.env` 的 5 个时间键；凭据和正式规划不变。

## Agent 运行与思考模式限制

默认整轮 `AGENT_TIMEOUT_SECONDS=180`，其中 `AGENT_FINAL_RESPONSE_RESERVE_SECONDS=45` 用于最终回答，
普通模型处理与工具阶段最多 135 秒。预留值最多按整轮的 25% 折算，显式设为 0 可关闭时间预留。
接近工作期限时停止继续工具调用：已有完整只读回执且仍有模型额度时，以无工具、DeepSeek 非思考模式
整理一次最终回答（最多 45 秒并受整轮余量约束）；各入口共享绝对期限，默认额外留 2 秒用于本地回执与保存，
因此恰好用完 135 秒工作时间后，最终模型请求约有 43 秒。已有待确认提案、不完整工具链或整理仍超时时，
根据可信回执本地收尾，不伪造资料、补造工具结果或自动确认。模型/工具次数和内容上限继续生效，不额外增加调用额度。
规划候选阶段也遵守工作期限，最终卡片摘要本地生成；兼容聊天入口到工作期限后返回明确的不完整结果说明。
时间放宽不会加速上游或模型，只增加等待容忍；供应商错误、内容及次数预算仍可能独立导致失败。

明确要求新建学习计划，并提供 `YYYY-MM-DD 至 YYYY-MM-DD`（最多 32 天）或本周/下周时，
默认启用分阶段规划：先通过当前账号获准的真实工具读取完整范围课表与全部未完成待办，
保留关联目标/里程碑截止及课内复核状态；按需读取考试、图书馆预约、校园卡和参考地点，
再以单个 `propose_plan` 工具生成候选。校园明细仅展示新鲜且可核验的有限快照页，保留缺失及分页说明。
查询、修改/删除、否定及日期含义不明确的请求继续原运行流程；没有必需技能权限或课表时明确停止。

分阶段流程继续受上述整轮期限和现有工具次数、模型次数、输入及输出限制约束，不增加调用与 token 配额。
补充读取最多占用四分之一时间，始终保留一次提案调用；生成最多两次模型请求，第二次仅用于
纠正未执行的非法候选，不自动重试网络/供应商失败。DeepSeek 在此专用生成阶段关闭思考，
遵循原有非思考单次 token 配额；原普通运行思考配置不变。超过现有容量仍可能终止，不能保证任意复杂任务成功。
成功后直接根据真实提案回执汇总，不再额外调用模型；所有候选沿用服务端完整冲突、状态版本与人工确认机制。

运行快照新增可选 `phase` 与 `diagnostics`，旧记录默认空值，无需数据库迁移；
新增 `phase` 事件只保存固定阶段和数值计数（耗时、输入各组成大小、响应长度、请求工具数），
不保存私有思考、原始参数或密钥。客户端原有提案保留与错误展示兼容。

回退开关：设置 `AGENT_STAGED_PLANNING_ENABLED=false` 后重启后端，恢复原有对话执行路径。
只关闭新分支，不删除历史、课表、提案或正式规划；部署未更新后端时不会生效。

原生客户端使用可查询的有界运行接口。默认保持 DeepSeek 思考模式和 `high` 强度；
思考内容、正文与工具参数共享单次生成额度，因此思考请求默认采用独立的
`DEEPSEEK_THINKING_MAX_TOKENS=16384`，标准/非思考请求的 `AGENT_MAX_TOKENS` 仍默认 4096。
两项均限制在 256–16384。若已有部署显式设置 `AGENT_MAX_TOKENS`、未设置新参数，
思考请求继续遵循原有上限；明确设置新参数才覆盖该项。关闭思考时不发送 `reasoning_effort`。
机制依据见 [DeepSeek 思考模式](https://api-docs.deepseek.com/guides/thinking_mode/) 与
[Chat Completions 参数](https://api-docs.deepseek.com/api/create-chat-completion/)。

总时长（默认 90 秒）、模型次数（6）、工具次数（10）、上下文字符（24000）、
可见输出字符（16000）和响应缓冲上限继续生效，不自动重试或续写。
失败区分输入、上下文、输出、次数、模型截断等原因，并保留已发生的工具记录。
旧运行仅有通用预算错误码时，不能反推其确切原因；回答片段不作为完整结果或执行成功证明。
真实模型生成还可能达到上述其他限制，合成检查不能替代线上结果验收。

生成提案的工具只向模型回填结构化简明回执（候选编号、待确认状态、任务/里程碑与冲突数量），
完整候选仍保留给确认卡片，避免把生成参数和整份方案再次重复放进上下文。
当前工具链的参数、思考协议内容与硬性限制不被裁剪或放宽。

原生运行接口还会在每次上下文检查时计算系统提示、工具定义与当前工具链的合计大小。
单份超长只读结果先转为完整 JSON 节选，不再截出半截 JSON 字符串；课表优先保留日期、课程、
起止时间及地点等基础安排，省略的辅助字段明确记数。
仅在超限时，按预算将已成功且调用关联匹配的只读结果转为结构化 `context_excerpt` 节选；
原始工具结果、提案和历史记录不被改写。节选保留来源状态，明确省略范围，不能据此声称已读取全部资料。
精确资料页被再次节选时，不沿用原页末游标；需要缺失资料须按原调用范围重查本页，避免跳过省略记录。
错误、未知工具、写操作回执及必需协议内容不参与压缩；这些内容仍超限时继续按真实预算失败处理。
此控制用于原生的有界运行接口，旧兼容聊天接口未在此轮更改。
每轮还会告知模型剩余工具调用额度；概览或近期提醒按目标读取相关摘要，只有确需完整明细才继续分页。
全部只读调用已成功且整批结果配对完成后，若续轮仍超出上下文预算或工具额度已耗尽，
可在既有模型轮数内进入一次无工具最终汇总：保留原始工具链，只为该请求构建不含历史思考的副本，
基于已取得资料回答并明确缺项。该行为遵循 [DeepSeek 无 `tools` 时的思考上下文规则](https://api-docs.deepseek.com/guides/thinking_mode/)。
已有上述完整资料时，模型再申请超过余量的合法已授权只读批次，也会跳过该未执行批次并转入汇总，
不会把跳过的调用或伪造结果写入工具记录。
汇总请求会重新计算完整输入预算，仍使用原输出/时长限制；若模型返回额外工具调用则拒绝执行。
工具批未结束、存在写操作或工具失败时不使用该收尾路径，执行前的必要上下文检查保持生效。

运行快照新增兼容字段 `prepared_actions`（旧快照默认空数组）。它只记录本轮成功提案工具返回、
由服务端按当前账户查证的候选，供汇总失败、超时或中断后核对；运行仍保留真实失败状态，
不会自动改写为成功、执行候选或追加完整成功历史。客户端展示可确认卡片前必须再次查询
`GET /api/v1/actions/{proposal_id}`，核对同一候选及其最新状态；过期、已处理、改变或无法核对的候选不能恢复为可执行卡片。
旧运行未记录候选关联时，不按时间或“最近一条提案”猜测回填。

## 依赖更新与跨平台回归

拉取包含依赖变更的提交后，在现有虚拟环境重新执行 `python -m pip install -e ".[dev]"`。
项目已把 `tzdata` 声明为正式运行依赖：Windows 等没有系统 IANA 时区库的环境也能加载
`Asia/Shanghai`，启动天气与其他 API，并解析带时区的课表。只拉取代码不会自动补齐依赖。

离线回归运行 `python -m pytest`；默认排除会访问真实模型的 `integration` 用例。
`tests/test_platform_portability.py` 会在独立子进程关闭系统时区库，验证 API 健康检查与
命名时区课表解析；另用 loopback socketpair 模拟 Windows 的 asyncio 内部唤醒通道。
普通 localhost/TCP、DNS、UDP 请求仍被隔离器阻止，不会借此访问模型或校园服务。
真正修改进程时区的检查只在支持 `time.tzset` 的系统运行；课表时间语义仍在全部平台测试。
这些模拟测试不能代替干净 Windows 环境的运行结果，更不代表三端 App 原生编译通过。

## HDUHelp Connect

推荐由用户在客户端填写 HDUHelp 个人访问令牌（PAT）。`PUT /api/v1/hduhelp/pat` 会先向
HDUHelp 验证并同步可访问资源，再使用 `APP_SECRET_KEY` 对应的 Fernet 密钥加密令牌与
数据缓存；响应只返回末四位提示，不返回明文。服务按 PAT 实际权限工作，未授权资源作为
单项错误返回。OAuth2 Authorization Code + PKCE 仍作为可选方式，不接收杭电密码。

如启用 OAuth，请在 `.env` 设置 `HDUHELP_APP_ID`、`HDUHELP_APP_SECRET` 和已登记的
`HDUHELP_REDIRECT_URI`。断开连接会删除本地令牌与同步缓存；OAuth 模式还会尽力撤销
远端令牌，PAT 模式由用户在 HDUHelp 侧自行轮换或撤销。

未配置 OAuth 应用凭据时，PAT 模式仍可使用；离线测试通过 Fake HDUHelp 服务覆盖 PAT、
OAuth、同步、一次性 state、脱敏状态和断开删除流程。

