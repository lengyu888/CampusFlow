# CampusFlow Agent Service

运行和测试说明见仓库根目录的 `README.md`。服务启动后访问：

- 健康检查：`GET /health`
- Swagger：`GET /docs`
- 对话：`POST /api/v1/chat`
- 工具清单：`GET /api/v1/tools`
- 历史：`GET /api/v1/sessions/{session_id}/history`
- 确认事务：`POST /api/v1/actions/{proposal_id}/confirm`

