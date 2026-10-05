# CampusFlow Agent Service

运行和测试说明见仓库根目录的 `README.md`。服务启动后访问：

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
- HDUHelp OAuth 连接状态：`GET /api/v1/hduhelp/status`
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
- 确认事务：`POST /api/v1/actions/{proposal_id}/confirm`

## HDUHelp Connect

正式接入使用 OAuth2 Authorization Code + PKCE，不接收或保存杭电密码。向 HDUHelp
申请应用后，在 `.env` 设置 `HDUHELP_APP_ID`、`HDUHELP_APP_SECRET` 和已登记的
`HDUHELP_REDIRECT_URI`。默认只申请本人学籍、成绩、考试、校园卡和图书馆预约的只读
scope；令牌与同步缓存均使用 `APP_SECRET_KEY` 对应的 Fernet 密钥加密后写入 SQLite。

未配置应用凭据时，页面仍可查看连接入口，但发起连接会返回明确的 503 配置提示；离线
测试通过 Fake HDUHelp 服务覆盖授权、同步、一次性 state 和断开删除流程。

