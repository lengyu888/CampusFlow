# CampusFlow 初步架构

## 目标

第一阶段以会议纪要中的“大学规划与执行 Agent”为目标，先打通 ArkUI-X 客户端与 Python Agent 服务之间的文本对话和工具调用链路。

```text
HarmonyOS / Android / iOS
        ArkUI-X + ArkTS
              │
          HTTP + JSON
              │
        FastAPI API Layer
        ┌─────┴──────────┐
   AccountStore     Vision Import
     SQLite        DeepSeek Flash
        └─────┬──────────┘
              │
       LangChain Agent Graph
        ┌─────┼─────────┐
        │     │         │
   DeepSeek  Tools   Conversation
    V4 Pro          / Proposal Store
              │
   ┌──────────┼──────────────┐
   │          │              │
课程/日程   天气/通知      地点/事务提案
```

## Agent 决策流程

1. 理解用户目标和约束。
2. 缺少关键时间、时长或地点时先追问。
3. 查询课程、天气、通知和地点等只读工具。
4. 生成可执行计划，检查时间冲突并提供备选方案。
5. 创建、修改、删除事务时只生成提案，不直接写入。
6. 客户端展示提案，用户显式确认后调用确认 API。
7. 服务端从登录会话确定 `user_id`，客户端保持同一 `session_id` 继续多轮对话。

## 初版边界

- 账户、学校、课表和地图结构化结果保存到本地 SQLite；天气和校园通知仍使用演示数据。
- 多轮上下文使用 LangGraph `InMemorySaver`，服务重启后上下文会丢失。
- API 历史由当前进程记录，正式环境应替换为 MySQL/PostgreSQL。
- 课表和地图原图只用于当次视觉解析，不在服务端持久化；确认后的结构化结果写入 SQLite。
- 写操作通过独立确认 API 完成，模型没有直接提交写操作的工具。
- 已接入 PBKDF2 密码存储、HttpOnly Web Cookie 与 Bearer Token；所有个人数据和提案均从登录身份确定归属。
- DeepSeek API Key 在注册或用户设置中提交，使用 Fernet 加密后写入 SQLite；主密钥与数据库分离，API/管理员界面只返回配置状态和尾号，不返回明文。
- 首个注册账户为管理员；管理员可查看全部用户的角色、校园、数据规模和凭据配置状态，普通用户无权访问用户目录。

## 视觉导入安全边界

- 仅接受最大 16 MiB 的 PNG、JPEG、GIF 或 WebP base64 data URL，不接受服务端主动抓取的任意 URL。
- 课表和地图交给 `deepseek-flash` 生成候选 JSON，Pydantic 校验后才返回客户端。
- 图片被视为不可信数据；提示词明确忽略图中指令、二维码和行为要求。
- 用户可以修改或删除识别结果，只有显式完成首次配置后才写入账户上下文。

## 后续演进

1. 把 `CampusStore` 替换为 MySQL Repository。
2. 把内存 Checkpointer 替换为持久化 LangGraph Checkpointer。
3. 接入教务、天气、地图、图书馆和教室预约 API。
4. 增加 SSE 流式返回和工具执行事件。
5. 增加用户偏好记忆与校园通知 RAG。
6. 增加限流、审计、令牌轮换和脱敏日志。

