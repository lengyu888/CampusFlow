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

## Agent 运行与思考模式限制

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
当前工具链的参数、思考协议内容与硬性限制不被裁剪或放宽；其他查询结果的范围与缺失提示保持原规则。

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

