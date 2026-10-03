# CampusFlow Agent Service

运行和测试说明见仓库根目录的 `README.md`。服务启动后访问：

- 健康检查：`GET /health`
- 注册/登录：`POST /api/v1/auth/register`、`POST /api/v1/auth/login`
- 当前用户：`GET /api/v1/me`
- 用户设置/学习数据：`PUT /api/v1/me/settings`、`GET /api/v1/me/context`
- 管理员用户总览：`GET /api/v1/admin/users`
- 视觉导入：`POST /api/v1/onboarding/parse-timetable`、`POST /api/v1/onboarding/parse-map`
- 完成首次配置：`PUT /api/v1/onboarding`
- Swagger：`GET /docs`
- 对话：`POST /api/v1/chat`
- 工具清单：`GET /api/v1/tools`
- 历史：`GET /api/v1/sessions/{session_id}/history`
- 确认事务：`POST /api/v1/actions/{proposal_id}/confirm`

