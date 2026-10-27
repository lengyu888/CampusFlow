# CampusFlow 大学规划与执行 Agent

CampusFlow 是面向高校学生的跨端 AI Agent。客户端采用 ArkUI-X/ArkTS，以一套主代码构建 HarmonyOS、Android 和 iOS 应用；服务端采用 Python、FastAPI、LangChain 和 DeepSeek。

日常使用流程见 [行简使用指南](docs/project-documents/user-journey.md)：准备课表 → 安排待办 → 今日执行 → 按需专注 → 回顾调整。应用内也可从今日、助手空会话或个人设置打开“使用指南”。

> **全分支整合（2026-10-23）**：整合累计业务分支与 Agent 增强，包括安全完成／恢复、专注记录、日／周回看、Markdown 和会话约束。保留清透 iOS、行简纸页两套可切换主题。功能来源、修复和实际验收状态见 [全分支功能清单](docs/project-documents/branch-integration-2026-10-23.md)。历史阶段文档不是本次设备或真实模型验收证明。


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
- 今日 / 助手 / 计划 / 校园四主入口，头像进入用户设置；校园中进入能力管理及校园服务
- SQLite 持久历史会话、搜索、改名与跨重启续聊
- SQLite 持久目标、里程碑、待办、提醒与完成进度
- 课程/既有待办时间冲突检测
- Agent 完整计划提案与用户确认写入
- 四个首批官方校园 Skills，支持分类搜索、详情与版本展示
- 用户级 Skill 安装、启停、升级、卸载与逐项权限确认
- Skill 安装/状态/工具运行审计，Agent Tool Calling 自动关联运行记录
- ArkUI-X Stage 模型客户端、类型化 FastAPI 请求层和四主入口原生页面
- ArkTS 原生校园路线图、课表订阅、规划和官方 Skills 操作界面
- 今日页计划进展、带日期/时间的手动待办，以及完成状态即时刷新
- 带核对回执的待办完成与恢复、关联任务的专注记录、每日和每周回看
- 实时回复和历史共用 Markdown；上翻阅读时暂停自动跟随，回到底部可恢复
- 同会话显式学习约束重建、完整旧问答对预算裁剪及当前工具调用链保留
- 两套本机持久主题，切换不重置账号、输入草稿或导航

## 目录

```text
.
├── agent-service/                 # Python Agent 与 API 服务
│   ├── src/campusflow_agent/
│   └── tests/
├── arkui-x-client/                # ArkUI-X/ArkTS 跨端客户端
├── docs/
│   ├── project-documents/         # 项目文档：集中存放 Markdown 与分类索引
│   ├── previews/                  # 浏览器原型与验证脚本
│   └── evidence/                  # 验证记录与合成数据
├── 9.24晚 会议内容.md
└── 校企合作创新实践课题汇总.xlsx
```

主要项目说明放在 **`docs/project-documents/`（项目文档）**；UX08–UX12 的累计记录仍保留在 `docs/`。统一入口见[项目文档索引](docs/project-documents/README.md)。

## 快速开始

### 环境要求

- Windows 10/11
- Python 3.11 或更高版本
- Node.js 24 LTS（客户端离线测试使用 `node:module.stripTypeScriptTypes`；本轮 Windows 验证为 24.22.1，不使用 DevEco 内置 Node 18 跑测试）
- DevEco Studio 6.1.1 Release
- ArkUI-X SDK 6.1.1 / API 24
- HarmonyOS Phone 模拟器（运行原生客户端时需要）

DeepSeek API Key 不写入源码或 `.env`。可在注册或用户设置中填写，由后端加密保存；没有
API Key 仍可维护课程、手动待办并运行离线测试，但不能发起真实模型对话。

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

首次使用请注册账户，再确认学校/校区、学期及至少一门课程。DeepSeek API Key 可在注册时
添加，也可稍后从用户设置补充；没有 Key 仍可维护课表、手动待办和查看已同步数据。
原图不持久化；API Key 使用 Fernet 加密后写入 SQLite，后续登录无需再次填写。生产环境必须
通过 `APP_SECRET_KEY` 注入独立主密钥，并使用 HTTPS。

如果出现 `ModuleNotFoundError: campusflow_agent`，请确认当前目录是 `agent-service`，激活虚拟
环境后重新执行 `python -m pip install -e ".[dev]"`。如果提示端口 8000 已被占用，先访问
`http://127.0.0.1:8000/health` 核对是否为 CampusFlow；也可能是其他进程。不要重复启动或盲目终止占用进程。

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

如需连接更多 HDUHelp 本人数据，可从头像进入用户设置，在 HDUHelp 连接中填写用户自己的
`hduhelp_pat_…` 个人访问令牌；令牌仅提交给 CampusFlow 后端，以 Fernet 密文保存，页面只
显示末四位。系统会按令牌实际权限同步可访问资源，单项未授权不会阻断其他数据。也可向
HDUHelp 申请应用并在 `agent-service/.env` 配置 App ID、Secret 与 Redirect URI，启用可选的
OAuth2 + PKCE 流程。两种方式都不收集杭电密码。

连接校园档案后，“校园 → 校园实时服务”可按教学楼与课节查询空闲教室、查看单间教室的
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

详细测试方式见本文末尾的“测试”以及 [ArkUI-X 联调说明](docs/project-documents/arkui-x-integration.md)。
完整开发顺序和阶段验收条件见 [分阶段开发计划](docs/project-documents/development-phases.md)。
协作者提交代码前请阅读 [协作开发流程](CONTRIBUTING.md)；普通协作者必须通过 PR，由仓库
拥有者审查后合并。拥有者保留直接推送权限，但仍应执行与变更风险相称的检查。

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

客户端自动化与连续业务旅程（Node.js 24 LTS）：

```powershell
cd arkui-x-client
npm ci --ignore-scripts --audit=false --fund=false
npm test
npm run check
# Python 路径不同，可设置 CAMPUSFLOW_TEST_PYTHON 指向已安装后端依赖的解释器。
npm run test:journey
```

连续旅程执行实际客户端方法、FastAPI 与 SQLite；模型供应商和平台能力使用明确的替身。
Web 的 Markdown、主题和安全任务恢复回归可在 `agent-service/tests/web` 安装其锁定的开发依赖后
运行 `pnpm test`。这些自动化不需要人工逐页点击，但不等同于原生触屏、系统权限、提醒送达或真实模型效果验收。

ArkUI-X 静态检查与 HAP 构建：

```powershell
cd arkui-x-client
npm run check
npm run build:hap
```

`entry-default-unsigned.hap` 会生成在 `arkui-x-client/entry/build/default/outputs/default/`。
模拟器可用于调试；真机安装前需要在 DevEco Studio 配置签名。


## Agent 优化分支历史说明（2026-10-19，归档）

以下保留 2026-10-19 当时的 Agent 分支记录，并非当前分支协作或本轮验收状态。
当前整合与验证请读[全分支清单](docs/project-documents/branch-integration-2026-10-23.md)，协作规则以 [CONTRIBUTING](CONTRIBUTING.md) 为准。

### 当时的固定分支与代码基线

- 当时个人 Agent 优化分支使用 **`codex/agent-improvements`**，只向既有 PR 累积；本轮全分支整合已取代这项旧约定。
- 当时本地 Agent 代码基于组员 UX07（`e475d35`），在此之上保留本地改动。模型目录、持久运行、账号范围会话、工具卡片、提案、语音和提醒等属于组员已有基线。
- 当时的审查基线为远端 `main` `41955b0`、`dev/haohao` `56ccfb7`；后者包含 UX08～UX12 和后续兼容修复，当时尚未整合到本地 Agent 分支。该差异由本轮全分支整合处理，当前验收状态见顶部清单。
- 当时目录整理前已保存下文列出的四次本地提交，Markdown 补充为工作区草稿；这项历史记录不要求继续向已完成分支推送。

### 在组员基线上的本地改动

| 范围 | 本地增加或修复的内容 |
| --- | --- |
| 消息展示 | 增强原生 Markdown 解析与共用消息组件；Web 使用本地 Marked、DOMPurify 渲染并净化内容，保留原文回退及表格、代码的横向滚动。 |
| 聊天交互与历史 | 修复回答后上翻被自动拉回底部；手动上翻暂停跟随，触底恢复。旧调用及 Web 保留提问提前保存、会话 `pending/active` 状态；新版 HTTP 入口仍按版本校验后成对提交。 |
| 会话约束记忆 | 从同一会话的用户历史重建每日/单次学习时长上限、偏好/禁止时段，支持修改、撤回和全清；旧问答裁剪后，支持的约束仍作为有来源的资料进入模型输入。 |
| 上下文预算 | run/chat 共用字符预算和完整问答对裁剪；兼容 LangChain 工具续轮。HTTP 聊天超限明确返回 413 和 `CONTEXT_BUDGET_EXCEEDED`。 |
| 验证与兼容 | 新增 38 场景离线基线及运行器，修复环境筛选造成的伪通过；补齐问句、代码/引用误记忆回归，并保留 Windows 时区、测试和 ArkTS 编译兼容修复。 |

约束记忆只识别明确的有限句式，不是通用或跨会话长期记忆；资料进入模型输入不等于真实模型一定遵守。
校园知识检索扩展目前是[待实施方案](docs/project-documents/campus-knowledge-retrieval-upgrade-plan.md)，未导入新资料、建立全文索引或实现向量检索。

### 最近一次已完成的验证

以下结果来自 **2026-10-19 提交前审查**；本次 Markdown 整理没有重新运行功能测试。

| 检查 | 实际结果 |
| --- | --- |
| 完整后端离线回归 | 872 passed，2 deselected；真实模型集成测试未执行。 |
| 固定 Agent 基线 | 38 个场景关联的 94 项检查通过；模型质量为 `not_evaluated`。 |
| 客户端 Node 离线回归 | 961 passed，1 skipped；跳过项为宿主缺少 plist 解析器。 |
| Web Markdown | 8 passed。 |
| 静态与依赖 | 76 个源码、24 个配置检查通过；Ruff、pip check 通过。 |

HarmonyOS unsigned HAP 的成功构建记录来自 **2026-10-18**，本轮没有重新构建。
真实模型效果、外部校园服务、模拟器/真机及 Android/iOS 构建和设备行为仍未完成本地验收。

### 组员查看入口

- [累计变更说明与分支现状](docs/project-documents/agent-improvements-changelog.md)：完整记录组员基线、本地增量、分阶段验证和待验收事项。
- [会话约束记忆说明](docs/project-documents/session-context-memory.md)：支持句式、来源、撤回、删除和预算边界。
- [Agent 固定验收基线](docs/project-documents/agent-evaluation-baseline.md)：场景、离线运行命令和未执行的真实模型评审。
- [Markdown 显示说明](docs/project-documents/markdown-rendering.md)：原生和 Web 的支持范围。

已有本地提交按目的分开：`483a781` 保留 UX07 整合与本地交互/展示改进，`6f85057` 记录协作说明，
`524cd21` 实现会话约束记忆与离线基线，`a471095` 同步审查、验证及检索方案。
当时待办是整合 `dev/haohao` 并逐项保留本地增强与远端新功能。本轮正在完成该整合；实际状态见顶部整合清单，不将历史文字作为本轮验收结论。
