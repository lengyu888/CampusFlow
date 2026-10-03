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
- SQLite 账户、登录会话与首次配置状态
- DeepSeek Flash 课表/校园地图视觉解析与人工确认
- 将确认后的个人课表和校园地点注入 Agent 工具

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

打开 `http://127.0.0.1:8000/` 注册账户并完成三步首次配置：学校/校区、课表图片识别、校园地图识别。图片由 DeepSeek Flash 解析，保存前可人工修改或删除错误记录；原图和 API Key 不写入 CampusFlow 数据库。`http://127.0.0.1:8000/docs` 可使用 Swagger 调试接口。

## 最小调用示例

```powershell
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$register = @{
  email = "student@example.com"
  password = "至少八位密码"
  display_name = "小航"
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/api/v1/auth/register" `
  -ContentType "application/json" -Body $register -WebSession $session
```

完成首次配置后，使用同一个会话对象调用 Agent。多轮对话保持相同的 `session_id`；用户身份由 HttpOnly Cookie 或 Bearer Token 确定，不接受客户端伪造 `user_id`：

```powershell
$body = @{
  session_id = "demo-session"
  api_key = "你的 DeepSeek API Key"
  model = "deepseek-v4-pro"
  message = "请结合我的课表和校园地图安排两个小时复习"
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/api/v1/chat" `
  -ContentType "application/json" -Body $body -WebSession $session
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

