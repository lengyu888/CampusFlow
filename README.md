# CampusFlow 大学规划与执行 Agent

CampusFlow 是面向高校学生的跨端 AI Agent。客户端采用 ArkUI-X/ArkTS，以一套主代码构建 HarmonyOS、Android 和 iOS 应用；服务端采用 Python、FastAPI、LangChain 和 DeepSeek。

当前仓库已打通账户与首次配置、校园数据、Agent 对话、智能规划与执行、Skills、历史会话以及 ArkUI-X Phone 客户端。主要能力包括：

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
- HDUHelp PAT / OAuth2 + PKCE 校园档案连接（学籍、成绩、考试、校园卡、图书馆预约）
- HDUHelp 实时空闲教室、教室学期占用记录与寝室电费查询
- 杭电下沙校区版本化数据包、建筑别名、开放时间与步行关系
- 基于已确认杭电地图的最短步行路径、矢量路线图与分步导航
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
- ArkUI-X Stage 模型客户端骨架、类型化 FastAPI 请求层和五入口原生页面
- ArkTS 原生校园路线图、课表订阅、规划和官方 Skills 操作界面
- 今日页计划进展、带日期/时间的手动待办，以及完成状态即时刷新

## 目录

```text
.
├── agent-service/                 # Python Agent 与 API 服务
│   ├── src/campusflow_agent/
│   └── tests/
├── arkui-x-client/                # ArkUI-X/ArkTS 跨端客户端（阶段 6）
├── docs/
│   ├── architecture.md            # 初步系统架构
│   ├── arkui-x-integration.md     # ArkUI-X 联调约定
│   └── development-log.md         # 开发日志
├── 9.24晚 会议内容.md
└── 校企合作创新实践课题汇总.xlsx
```

## 快速开始

### 环境要求

- Windows 10/11
- Python 3.11 或更高版本
- DevEco Studio 6.1.1 Release
- ArkUI-X SDK 6.1.1 / API 24
- HarmonyOS Phone 模拟器（运行原生客户端时需要）

DeepSeek API Key 不写入源码或 `.env`。首次注册时由用户在客户端填写，后端加密保存；没有
API Key 仍可运行离线单元测试，但不能发起真实模型对话。

### 1. 首次安装后端

在仓库根目录打开 PowerShell：

```powershell
cd agent-service
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -U pip
python -m pip install -e ".[dev]"
Copy-Item .env.example .env
```

`.env` 中的 OAuth、LangSmith 和生产密钥均为可选配置。开发环境未设置
`APP_SECRET_KEY` 时会在 `agent-service/data/.campusflow.key` 生成仅供本机使用的密钥；
`data/` 和 `.env` 已被 Git 忽略。

### 2. 启动后端

以后每次启动只需要：

```powershell
cd agent-service
.\.venv\Scripts\Activate.ps1
python -m uvicorn campusflow_agent.main:app --host 0.0.0.0 --port 8000
```

看到 `Application startup complete` 后，访问：

- Web 调试页面：`http://127.0.0.1:8000/`
- 健康检查：`http://127.0.0.1:8000/health`
- Swagger API：`http://127.0.0.1:8000/docs`

首次使用请注册账户并填写 DeepSeek API Key，再完成学校/校区、课表和校园地图配置。
原图不持久化；API Key 使用 Fernet 加密后写入 SQLite，后续登录无需再次填写。生产环境必须
通过 `APP_SECRET_KEY` 注入独立主密钥，并使用 HTTPS。

如果出现 `ModuleNotFoundError: campusflow_agent`，请确认当前目录是 `agent-service`，激活虚拟
环境后重新执行 `python -m pip install -e ".[dev]"`。如果提示端口 8000 已被占用，说明已有
后端正在运行，不要重复启动。

### 3. 启动 HarmonyOS Phone 客户端

先保持后端运行，再打开新的 PowerShell：

```powershell
cd arkui-x-client
npm run fix:deveco
npm run check
npm run build:hap
```

如果 ArkUI-X SDK 不在默认目录，可显式指定：

```powershell
npm run fix:deveco -- -SdkPath "D:\Huawei\ArkUI-X\Sdk"
```

然后：

1. 使用 DevEco Studio 打开 `arkui-x-client` 目录，等待 Hvigor 同步完成。
2. 在设备管理器启动 API 24 的 Phone 模拟器。
3. 为模拟器建立到电脑后端的反向端口映射（模拟器重启后需重新执行）：

   ```powershell
   hdc rport tcp:8000 tcp:8000
   ```

4. 在 DevEco Studio 选择 `entry` 和已启动的 Phone，点击运行。
5. 登录页服务地址填写 `http://127.0.0.1:8000`。

若 DevEco Studio 报 `Unable to find 'arkui-x.dir'`，执行上述 `npm run fix:deveco` 后完整退出并
重开 DevEco Studio。更详细的 SDK 路径、Android/iOS 地址和签名说明见
[ArkUI-X 客户端 README](arkui-x-client/README.md)。

课表支持图片识别或 HDUHelp 订阅链接。订阅链接中的 token 会使用同一凭据保险库加密保存，API 与页面只返回服务域名、同步时间和事件数量，不回显完整链接。

如需连接更多 HDUHelp 本人数据，可直接在“我的 → HDUHelp 校园档案”填写用户自己的
`hduhelp_pat_…` 个人访问令牌；令牌仅提交给 CampusFlow 后端，以 Fernet 密文保存，页面只
显示末四位。系统会按令牌实际权限同步可访问资源，单项未授权不会阻断其他数据。也可向
HDUHelp 申请应用并在 `agent-service/.env` 配置 App ID、Secret 与 Redirect URI，启用可选的
OAuth2 + PKCE 流程。两种方式都不收集杭电密码。

连接校园档案后，“今日 → 校园实时服务”可按教学楼与课节查询空闲教室、查看单间教室的
本学期占用安排，并查看已绑定寝室的当前电费余额与近 14 天记录。Agent 也可按需调用同一组
只读工具；若 HDUHelp 账户尚未绑定电表或接口权限不足，页面会明确提示而不会猜测数据。

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
协作者提交代码前请阅读 [协作开发流程](CONTRIBUTING.md)；`main` 分支禁止直接推送，所有变更
必须通过 Pull Request 审查后合并。

## 测试

离线单元测试不需要 `DEEPSEEK_API_KEY`：

```powershell
cd agent-service
.\.venv\Scripts\Activate.ps1
python -m pytest -q
```

真实 DeepSeek 冒烟测试需要 API Key：

```powershell
$env:DEEPSEEK_API_KEY="你的密钥"
python -m pytest -q -m integration
```

默认测试会跳过所有标记为 `integration` 的真实模型调用，避免产生费用。

ArkUI-X 静态检查与 HAP 构建：

```powershell
cd arkui-x-client
npm run check
npm run build:hap
```

`entry-default-unsigned.hap` 会生成在 `arkui-x-client/entry/build/default/outputs/default/`。
模拟器可用于调试；真机安装前需要在 DevEco Studio 配置签名。

