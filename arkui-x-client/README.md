# 行简（CampusFlow）ArkUI-X 客户端

累计功能整合后，以 `main` 为已验证基线。当前功能与验收范围见 [全分支整合记录](../docs/project-documents/branch-integration-2026-10-23.md)，分支操作以 [协作开发流程](../CONTRIBUTING.md) 为准。[兼容修复说明](../docs/compatibility-repair.md)和 [旧分支约定](../docs/haohao-collaboration.md)保留为历史资料，不要求重新创建已完成的分支。

这是行简的 ArkUI-X/ArkTS 客户端。仓库保留 HarmonyOS、Android、iOS 宿主工程及 ArkUI-X 6.1.1 / API 24 配置；包名和路径继续使用 CampusFlow。2026-10-23 整合候选已完成 API24 clean HAP 编译、Phone 安装与启动，并进行真实模拟器触屏验收；已验证首次课表保存、重装后的草稿恢复和日期／时间选择回显，其他验收结果以整合记录为准。Android/iOS 构建与真实外部服务仍待独立验收，不以工程配置、自动化逻辑测试或模拟器启动代替。历史交接见[UX12入口](../docs/ux-12-handoff.md)与[设备验收表](../docs/ux-12-competition-acceptance.md)。共享代码覆盖以下核心流程：

- 登录与注册、HarmonyOS 安全保持登录及匿名连接自检（无需模型密钥也可录课、管理任务与查看回看）
- 首次学校、校区、学期配置，手动连续录课和逐行导入预览；订阅是可选路径
- 今日课程和 Agent 快捷入口
- DeepSeek V4 Pro / Flash 多轮对话与操作确认
- 基于杭电校园数据包的原生 Canvas 路线图
- 待办创建、完成状态和进度概览
- 官方 Skills 安装、权限展示与启停
- 个人设置、API Key 更新和课表同步
- HDUHelp OAuth 授权、个人校园数据同步与断开清理
- HDUHelp 空闲教室、教室占用详情与寝室电费实时查询
- 校园服务四入口：空闲教室、寝室电费、图书馆、校园卡；数据时效以页面来源为准，“我的校园档案”保留账户、学籍与成绩
- 行简纸页／清透 iOS 两套本机持久主题、校园插图与轻量交互；今日、助手、计划、校园四个主入口共用业务与草稿、日历和浏览状态
- 按任务选择允许课内完成，提示课程重叠并绑定本次版本；课表变化后重新核对与改期
- 完成与预览恢复、本机专注片段及同步、按可靠记录生成日周回看

从头像进入个人设置，可切换主题，并使用“减少动态效果”开关关闭页面切换与选择动画；偏好仅保存在本机。

本地文字会话与登录页提供只读离线入口：成功对话及在线打开的历史会话会保存到应用私有目录，最多保留最近 20 个完整会话并受容量限制。只保留最近登录账号，换账号/服务范围时替换，退出时清除；不保存登录令牌或恢复可执行提案。缓存没有另加 PIN/生物识别，解锁此设备的人可回看。本轮已在 Phone 覆盖安装后、后端停止时实际打开缓存 Markdown 对话；Android/iOS 原生读写仍待验收，见[第四阶段说明](../docs/project-documents/stage-4-local-history.md)。

## 工程结构

```text
arkui-x-client/
├── .arkui-x/                  # 跨端声明及 ACE 生成的 Android/iOS 宿主工程
├── AppScope/                  # 应用级资源与包信息
├── entry/
│   └── src/main/
│       ├── ets/
│       │   ├── components/   # 路线图等共享组件
│       │   ├── model/        # FastAPI JSON 类型
│       │   ├── pages/        # 四主入口、二级页面、登录和首次配置
│       │   └── services/     # 统一 HTTP/Bearer 请求层
│       └── resources/
└── scripts/                  # 静态验收与可复现 HAP 构建脚本
```

## 已有原生环境的队友运行指引

以下是仓库已有工具链的操作参考，由负责设备验收的队友在已有环境使用；本轮交付不要求当前用户下载这些环境。

1. 安装 DevEco Studio 6.1.1 Release，并配置 ArkUI-X SDK 6.1.1 / API 24。
2. 在 DevEco Studio 中打开本目录，等待 Hvigor 同步。
3. Android、iOS 宿主工程已由官方 ACE Tools 生成并纳入版本管理；修改模块或平台配置后再运行 `ace modify --project` 同步。
4. 先按仓库根目录 README 启动 FastAPI 服务，再运行 `entry`。

登录页可直接修改服务地址：

- HarmonyOS/Android 真机：`http://<开发电脑局域网 IP>:8000`
- Android 模拟器：`http://10.0.2.2:8000`
- iOS 模拟器与本机预览：`http://127.0.0.1:8000`

Android/iOS 宿主为本地联调保留 HTTP 明文配置；正式发布需结合实际部署使用 HTTPS 并收紧相应配置，本轮没有执行部署。

HarmonyOS 登录页可选择“保持登录”：会话令牌与原服务地址、用户编号共同保存在系统 Asset 安全存储中，不保存密码，不写入本机历史或草稿，不同步到云端，卸载应用不保留。冷启动先匿名核对原服务，再由原服务验证同一账号；网络失败保留候选供明确重试，过期或撤销后要求重新登录。退出先持久停用恢复，再清理安全资产及已有本机缓存，避免清理失败后重新登录旧账号。当前 Android/iOS 没有安全会话存储适配，保持登录不可用时只进行本次手动登录，不降级为明文保存。

登录页和“个人设置 → 历史与本机数据”提供“检查连接”，只发送匿名健康检查。地址无效、响应不符合行简格式、HTTP 异常与网络不可达分别显示；网络不可达无法单独区分后端停机、网络或模拟器映射失效。新增探针与恢复验证禁用重定向和 HTTP 缓存，连接与读取分别限制为 5 秒；普通业务继续使用原有超时，登录请求使用较短超时。提醒协调器和三端能力适配代码已存在，权限、受理和实际送达仍需设备核验。

## 命令行构建与验收

可先运行跨平台的只读前置检查：

```sh
npm run check:native
# 如需机器可读结果：node scripts/check-native-env.mjs --json
```

该命令不安装、不修复环境，也不执行构建；缺少已探测工具时退出码为 1。`present` 只代表找到工具或文件，不能当作原生编译通过。

项目在 Windows 上提供可复现的 HAP 构建脚本。默认查找：

- DevEco Studio：`C:\Program Files\Huawei\DevEco Studio`
- ArkUI-X SDK：`%LOCALAPPDATA%\ArkUI-X\Sdk`

路径不同时，可先设置 `DEVECO_STUDIO_HOME` 和 `ARKUIX_SDK_HOME`。然后运行：

```powershell
cd arkui-x-client
npm run check
npm run build:hap
```

如果 DevEco Studio 报 `Unable to find 'arkui-x.dir'`，先确认
`local.properties` 中存在 `arkui-x.dir=C:/Users/<用户名>/AppData/Local/ArkUI-X/Sdk`，并把
`ARKUIX_SDK_HOME` 设置为同一 SDK 根目录。修改 Windows 用户环境变量后必须完整退出并重开
DevEco Studio；已经运行的 IDE 进程不会自动读取新变量。项目提供一键修复命令，它会验证
SDK、重建 `local.properties`、持久化环境变量，并停止持有旧环境的 Hvigor daemon：

```powershell
npm run fix:deveco
```

也可以在 DevEco Studio 的 `文件 > 设置 > ArkUI-X` 页面点击安装路径右侧的“编辑”，选择
ArkUI-X SDK 根目录。该目录应直接包含版本子目录，例如：

```text
C:\Users\<用户名>\AppData\Local\ArkUI-X\Sdk\24\arkui-x\sdkConfig.json
```

页面中应选择到 `...\ArkUI-X\Sdk`，不要选择到 `24` 或 `arkui-x`。脚本会依次从命令行参数、
当前进程环境变量、Windows 用户环境变量、`local.properties`、DevEco 页面配置和默认目录中
自动发现 SDK。路径位于其他磁盘时可显式指定：

```powershell
npm run fix:deveco -- -SdkPath "D:\Huawei\ArkUI-X\Sdk"
```

如果 IDE 仍在运行，先保存工作并从“文件 > 退出”完全关闭（任务管理器中不再有
`devecostudio64.exe`），再重新打开项目。不要直接复用报错前启动的 Hvigor daemon。

Phone 模拟器访问电脑端 `127.0.0.1:8000` 前，需要建立一次反向端口映射（模拟器重启后重做）：

```powershell
hdc rport tcp:8000 tcp:8000
```

可用 `hdc fport ls` 同时查看正向和反向映射；不是 `hdc rport ls`。列表为空时重新建立映射，已有对应 `[Reverse]` 时不必重复添加。后端 `/health` 正常但 Phone 连接失败，应先核对映射、服务地址和设备是否重启，不要删除用户或修改密码。

随后在 DevEco Studio 顶部选择 `entry` 和已启动的 Phone 模拟器，点击运行；登录页服务地址
填写 `http://127.0.0.1:8000`。如果构建成功但列表中没有设备，请先在设备管理器下载对应系统
镜像并启动模拟器，等设备状态变为在线后再回到运行配置。

调试 HAP 输出到 `entry/build/default/outputs/default/`。未配置签名证书时会生成 `entry-default-unsigned.hap`，可以完成编译验收，但真机安装前仍需在 DevEco Studio 中配置自动签名。

已有 ACE 开发环境可用 `ace check -v` 检查。2026-10-23 的 HAP 构建证据仅覆盖本次 HarmonyOS 候选；Android 与 iOS 仍分别由具有对应工具链的队友构建验收，保存对应提交和实际日志。

## 逻辑回归与静态验收

```powershell
cd arkui-x-client
npm ci --ignore-scripts --audit=false --fund=false
npm test
npm run check
```

先用 `npm ci --ignore-scripts --audit=false --fund=false` 安装锁定的 TypeScript 测试编译器；逻辑测试不需要 DevEco SDK。Agent 会话测试保留 AST 回调解析，Markdown 测试保留完整严格类型诊断，不以去除类型代替类型检查。需刻意对比本机编译器时可设置 `CAMPUSFLOW_TYPESCRIPT_PATH`，默认只使用仓库声明的依赖。

`npm test` 使用已有 Node.js 24 LTS 执行共享逻辑和实际页面控制器方法测试，本身不安装依赖、不启动原生应用。不要使用 DevEco 内置的 Node 18 执行这些测试；它仍可用于其自带的 Hvigor 构建。

现有后端测试 Python 可通过 `CAMPUSFLOW_TEST_PYTHON=/path/to/python npm run test:journey` 运行 UX11 连续旅程。它经实际 API 访问同一进程 FastAPI/SQLite，模型供应商和系统能力明确使用替身；缺依赖时失败，不自动安装。最终结果和复现边界见[UX11说明](../docs/ux-11-experience-polish.md)。

静态检查脚本检查工程必需文件、JSON/JSON5 语法、ArkTS 相对导入、密钥泄漏、网络权限，以及客户端与 FastAPI 的关键接口契约。依赖目录和构建产物会被排除。它不能替代 DevEco Studio 的 ArkTS 类型检查和真机安装测试。

## Agent 回复排版

助手回复和历史详情共用原生 Markdown 消息组件，支持标题、列表、粗体、引用、代码块和表格。宽表格与长代码在气泡内横向滚动，用户输入仍原样显示；已有历史无需迁移。

解析测试：`node --test scripts/test-markdown-parser.mjs`。静态排版可通过 `entry/src/main/ets/components/MarkdownPreview.ets` 的 Previewer 检查，详细支持范围及 Web 验证方式见 [Markdown 显示说明](../docs/project-documents/markdown-rendering.md)。
