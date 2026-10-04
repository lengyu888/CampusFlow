# CampusFlow 大学规划与执行 Agent

CampusFlow 是面向高校学生的跨端 AI Agent。客户端计划采用 ArkUI-X/ArkTS，一套主代码构建 HarmonyOS、Android 和 iOS 应用；服务端采用 Python、FastAPI、LangChain 和 DeepSeek。

当前仓库已完成阶段 5 的校园数据体系，Agent 服务、账户、App 框架、执行中心、能力治理与校园上下文已贯通：

- DeepSeek `deepseek-v4-pro` / `deepseek-flash` 模型接入
- LangChain Agent 调度与 Tool Calling
- 以 `session_id` 为线程标识的多轮对话
- 课程、天气、校园通知、地点查询工具
- 事务创建/修改/删除的“提案—确认”安全流程
- FastAPI HTTP+JSON 接口
- 不调用真实模型即可运行的单元测试
- SQLite 账户、登录会话与首次配置状态
- DeepSeek Flash 课表/校园地图视觉解析与人工确认
- HDUHelp iCalendar 课表订阅、预览导入与一键同步
- 杭电下沙校区版本化数据包、建筑别名、开放时间与步行关系
- 带有效期的校园通知查询，以及用户级纠错待审核流程
- 将确认后的个人课表和校园地点注入 Agent 工具
- API Key 注册时加密保存，后续登录免重复配置
- 用户设置、学习数据视图与管理员用户总览
- 今日 / Agent / 规划 / Skills / 我的五入口 App 主框架
- SQLite 持久历史会话、搜索、改名与跨重启续聊
- SQLite 持久目标、里程碑、待办、提醒与完成进度
- 课程/既有待办时间冲突检测
- Agent 完整计划提案与用户确认写入
- 四个首批官方校园 Skills，支持分类搜索、详情与版本展示
- 用户级 Skill 安装、启停、升级、卸载与逐项权限确认
- Skill 安装/状态/工具运行审计，Agent Tool Calling 自动关联运行记录

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

打开 `http://127.0.0.1:8000/` 注册账户并填写 DeepSeek API Key，再完成三步首次配置：学校/校区、课表图片识别、校园地图识别。原图不持久化；API Key 使用 Fernet 加密后写入 SQLite，后续登录直接使用。开发环境会在 `data/.campusflow.key` 生成本机主密钥，生产环境必须通过 `APP_SECRET_KEY` 注入独立主密钥。`http://127.0.0.1:8000/docs` 可使用 Swagger 调试接口。

课表支持图片识别或 HDUHelp 订阅链接。订阅链接中的 token 会使用同一凭据保险库加密保存，API 与页面只返回服务域名、同步时间和事件数量，不回显完整链接。

## 最小调用示例

```powershell
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$register = @{
  email = "student@example.com"
  password = "至少八位密码"
  display_name = "小航"
  api_key = "你的 DeepSeek API Key"
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/api/v1/auth/register" `
  -ContentType "application/json" -Body $register -WebSession $session
```

完成首次配置后，使用同一个会话对象调用 Agent。多轮对话保持相同的 `session_id`；用户身份由 HttpOnly Cookie 或 Bearer Token 确定，不接受客户端伪造 `user_id`：

```powershell
$body = @{
  session_id = "demo-session"
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

