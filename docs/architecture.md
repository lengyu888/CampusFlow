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

官方 Skills 是工具之上的用户级治理层：目录声明版本、能力和最小权限，`SkillStore` 保存安装与启停状态，并把已安装 Skill 对应的工具调用写入审计记录。Skill 的写权限只允许生成待确认提案，不能绕过现有确认 API。

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
- 会话目录和消息历史写入 SQLite；每次 Agent 调用会重新装载该会话历史，因此刷新页面或重启服务后仍可继续对话。
- 正式环境应将 SQLite 会话表替换为 MySQL/PostgreSQL，并对长会话增加摘要和上下文裁剪。
- 课表和地图原图只用于当次视觉解析，不在服务端持久化；确认后的结构化结果写入 SQLite。
- 写操作通过独立确认 API 完成，模型没有直接提交写操作的工具。
- 已接入 PBKDF2 密码存储、HttpOnly Web Cookie 与 Bearer Token；所有个人数据和提案均从登录身份确定归属。
- DeepSeek API Key 在注册或用户设置中提交，使用 Fernet 加密后写入 SQLite；主密钥与数据库分离，API/管理员界面只返回配置状态和尾号，不返回明文。
- 首个注册账户为管理员；管理员可查看全部用户的角色、校园、数据规模和凭据配置状态，普通用户无权访问用户目录。
- 官方 Skill 的安装状态、权限同意与审计记录按用户隔离保存；停用后不再记录该 Skill 的工具运行事件。

## 视觉导入安全边界

- 仅接受最大 16 MiB 的 PNG、JPEG、GIF 或 WebP base64 data URL，不接受服务端主动抓取的任意 URL。
- 课表和地图交给 `deepseek-flash` 生成候选 JSON，Pydantic 校验后才返回客户端。
- 图片被视为不可信数据；提示词明确忽略图中指令、二维码和行为要求。
- 用户可以修改或删除识别结果，只有显式完成首次配置后才写入账户上下文。

## 后续演进

1. 把 `CampusStore` 替换为 MySQL Repository。
2. 为长会话增加持久化 Checkpointer、摘要压缩和 Token 预算管理。
3. 接入教务、天气、地图、图书馆和教室预约 API。
4. 增加 SSE 流式返回和工具执行事件。
5. 增加用户偏好记忆与校园通知 RAG。
6. 增加限流、审计、令牌轮换和脱敏日志。

