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
7. 使用同一 `user_id + session_id` 继续多轮对话。

## 初版边界

- 校园数据使用内存中的演示数据，后续由外部接口负责人替换。
- 多轮上下文使用 LangGraph `InMemorySaver`，服务重启后上下文会丢失。
- API 历史由当前进程记录，正式环境应替换为 MySQL/PostgreSQL。
- 客户端负责本地持久化敏感学生资料，服务端只接收完成任务所需的最小数据。
- 写操作通过独立确认 API 完成，模型没有直接提交写操作的工具。
- 当前尚未接入正式身份认证；提案确认已校验 `user_id` 归属，生产环境仍需使用登录令牌替代客户端自报的用户 ID。
- DeepSeek API Key 由客户端逐次提交，只用于创建该次模型调用，不写入 Store、Checkpointer 或日志；测试页面刷新后密钥丢失。

## 后续演进

1. 把 `CampusStore` 替换为 MySQL Repository。
2. 把内存 Checkpointer 替换为持久化 LangGraph Checkpointer。
3. 接入教务、天气、地图、图书馆和教室预约 API。
4. 增加 SSE 流式返回和工具执行事件。
5. 增加用户偏好记忆与校园通知 RAG。
6. 增加鉴权、限流、审计和脱敏日志。

