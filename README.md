# CampusFlow 大学规划与执行 Agent

CampusFlow 是面向高校学生的跨端 AI Agent。客户端计划采用 ArkUI-X/ArkTS，一套主代码构建 HarmonyOS、Android 和 iOS 应用；服务端采用 Python、FastAPI、LangChain 和 DeepSeek。

当前仓库处于第一阶段，重点完成 Agent 服务骨架：

- DeepSeek `deepseek-v4-pro` / `deepseek-flash` 模型接入
- LangChain Agent 调度与 Tool Calling
- 以 `session_id` 为线程标识的多轮对话
- 课程、天气、校园通知、地点查询工具
- 事务创建/修改/删除的“提案—确认”安全流程
- FastAPI HTTP+JSON 接口
- 不调用真实模型即可运行的单元测试

## 目录

```text
.
├── agent-service/                 # Python Agent 与 API 服务
│   ├── src/campusflow_agent/
│   └── tests/
├── docs/
│   ├── architecture.md            # 初步系统架构
│   ├── arkui-x-integration.md     # ArkUI-X 联调约定
│   └── development-log.md         # 开发日志
├── 9.24晚 会议内容.md
└── 校企合作创新实践课题汇总.xlsx
```

## 快速开始

以下命令在仓库根目录执行。

```powershell
cd agent-service
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -U pip
pip install -e ".[dev]"
Copy-Item .env.example .env
```

启动服务：

```powershell
uvicorn campusflow_agent.main:app --reload --host 0.0.0.0 --port 8000
```

打开 `http://127.0.0.1:8000/` 使用图形化测试台。API Key 由页面随请求提交，只保存在当前输入框中，不写入浏览器存储、会话历史或服务端存储。`http://127.0.0.1:8000/docs` 可使用 Swagger 调试接口。

## 最小调用示例

```powershell
$body = @{
  user_id = "demo-student"
  session_id = "demo-session"
  api_key = "你的 DeepSeek API Key"
  model = "deepseek-v4-pro"
  message = "请结合我明天的课程和天气，安排两个小时复习高数"
} | ConvertTo-Json

Invoke-RestMethod `
  -Method Post `
  -Uri "http://127.0.0.1:8000/api/v1/chat" `
  -ContentType "application/json" `
  -Body $body
```

多轮对话时保持相同的 `user_id` 和 `session_id`。当返回 `pending_actions` 时，客户端应展示确认卡片，再调用：

```powershell
Invoke-RestMethod `
  -Method Post `
  -Uri "http://127.0.0.1:8000/api/v1/actions/<proposal_id>/confirm?user_id=demo-student"
```

详细测试方式见本文末尾的“测试”以及 [ArkUI-X 联调说明](docs/arkui-x-integration.md)。
完整开发顺序和阶段验收条件见 [分阶段开发计划](docs/development-phases.md)。

## 测试

离线单元测试不需要 `DEEPSEEK_API_KEY`：

```powershell
cd agent-service
pytest -q
```

真实 DeepSeek 冒烟测试需要 API Key：

```powershell
$env:DEEPSEEK_API_KEY="你的密钥"
pytest -q -m integration
```

默认测试会跳过所有标记为 `integration` 的真实模型调用，避免产生费用。

