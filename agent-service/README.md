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

