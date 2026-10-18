# 行简｜赛事要求与验收交接

核对基线：UX11 个人仓提交 `fce0e1d2f46329d1d3552924be890ca0653866d3`。UX12 是交付整理，后续发布提交以阶段发布表为准。

用户提供的赛题截图要求**鸿蒙、Android、iOS 三端必做**，包括三端文本多轮对话与本地会话回看；鸿蒙还须演示 ASR→Agent→TTS。早期 Markdown 写“iOS 选做”，本交接采用截图的更严格口径。不能以 Android/iOS 语音加分代替鸿蒙语音必做，也不能以界面截图代替安装运行。

当前已交付共享业务、页面和平台适配源码，完成离线逻辑与浏览器近似核验。**本轮未安装原生工具链，未编译、签名或运行三端应用，未调用真实云模型。** 历史文档中的其他环境构建记录不能证明此提交可构建；以下每项独立验收。

## 要求、实现与证据

| 赛事要求 | 当前源码实现 | 可复查的离线证据 | 仍需设备／在线验收 |
|---|---|---|---|
| 一套代码构建三端 App | [共享 ArkTS](../arkui-x-client/entry/src/main/ets/)、[三端配置](../arkui-x-client/.arkui-x/)、[构建入口](../arkui-x-client/scripts/build-native.mjs)；平台差异集中在语音、提醒、时钟与宿主适配 | [原生能力与构建边界](stage-15-native-capabilities.md)、[UX11 静态结果](evidence/ux-11-checks.json)；静态检查与 dry-run 不是编译 | 从同一源码版本分别构建、签名、安装鸿蒙／Android／iOS，保存工具版本、构建日志与实际运行证据 |
| 三端多轮文本与至少一种云模型真实对话 | [AgentPage](../arkui-x-client/entry/src/main/ets/pages/AgentPage.ets)、[会话上下文与版本核对](../agent-service/src/campusflow_agent/session_service.py)、[运行服务](../agent-service/src/campusflow_agent/run_service.py)、[模型适配](../agent-service/src/campusflow_agent/model_catalog.py) | [UX05 会话检查](evidence/ux-05-checks.json)、[真实工具旅程](evidence/ux-11-journey.json)：实际 API、运行循环、SQLite、历史成对保存；供应商流是明确的离线替身 | 三端分别进行至少两轮有上下文的真实对话。选定一种已配置供应商验证即可；“配置可用”不等于已真实评测，多模型不必全部作为赛事基线 |
| Agent 多轮任务推进或至少一个工具 | [Agent 循环](../agent-service/src/campusflow_agent/agent.py)、[工具](../agent-service/src/campusflow_agent/tools.py)、[原子提案服务](../agent-service/src/campusflow_agent/action_service.py)、[冲突与改期](../agent-service/src/campusflow_agent/replanning.py) | [UX11 旅程](evidence/ux-11-journey.json)贯通读课表→生成候选→显式确认→课表改变→改期确认；提案前无任务写入，确认丢响应后按原 ID 核对，重放不重复 | 真模型选对工具、工具进度与结果相符；展示准确候选、来源、冲突及确认回执，失败时不能宣称执行成功 |
| 鸿蒙 ASR→Agent→TTS | [共享语音状态机](../arkui-x-client/entry/src/main/ets/utils/VoiceInteraction.ets)、[鸿蒙驱动](../arkui-x-client/entry/src/main/ets/services/HarmonyVoiceDriver.ets)、[平台选择](../arkui-x-client/entry/src/main/ets/services/PlatformVoiceDriver.ets) | [语音接入说明](stage-6-voice-interaction.md)、[真实源码的模拟驱动检查](../arkui-x-client/scripts/test-harmony-voice-driver.mjs)：权限迟到、取消、结果归属、分段播报与清理 | 在目标 SDK 核对类型并用鸿蒙设备实际录音。识别先到可编辑草稿，用户发送到真实模型，再播报回答；验证拒绝权限、停止与后台中断 |
| Android／iOS 语音补充（加分） | [共享 Bridge 驱动](../arkui-x-client/entry/src/main/ets/services/NativeBridgeVoiceDriver.ets)、[Android 系统适配](../arkui-x-client/.arkui-x/android/app/src/main/java/com/campusflow/agent/CampusFlowPlatformBridge.java)、[iOS 系统适配](../arkui-x-client/.arkui-x/ios/app/CFPlatformBridge.m) | [原生能力说明](stage-15-native-capabilities.md)、[Android 源码契约](../arkui-x-client/scripts/test-native-android-contract.mjs)、[iOS 源码契约](../arkui-x-client/scripts/test-ios-native-contract.mjs) | 两端各自验证权限、系统识别服务可用性、播报／取消；源码检查不证明 Bridge ABI、系统语音服务或设备音频已可用 |
| 三端会话本地持久化、可回看 | [文件适配](../arkui-x-client/entry/src/main/ets/services/LocalHistory.ets)、[历史存储](../arkui-x-client/entry/src/main/ets/utils/LocalHistoryStore.ets)、[历史页面](../arkui-x-client/entry/src/main/ets/pages/HistoryPage.ets) | [UX03 草稿与首次配置](evidence/ux-03-checks.json)、[UX05 会话](evidence/ux-05-checks.json)、[历史存储专项](../arkui-x-client/scripts/test-local-history.mjs)；UX11 另验证实际文件驱动的草稿冷读取和账号隔离 | 三端先在线形成并缓存会话，关闭应用、断网重开，从登录页离线入口回看。缓存有容量上限；退出会清除本机内容，不能先退出再要求旧缓存仍存在 |
| 安装／运行说明、一页架构、演示 | [根 README](../README.md)、[当前结构一页](ux-12-handoff.md#当前结构一页)、[跨端接线](arkui-x-integration.md)、[本次演示脚本](ux-12-demo-script.md) | 独立阶段文档、来源明确的 Web 演示与 JSON 检查结果已入仓；安装包不在本次离线成果中 | 学长在已有环境完成构建步骤、设备安装说明及可重放录像；补实际环境和失败处理，不发布签名材料或凭据 |
| UI 美学、易用反馈与可选增强 | [统一主题](../arkui-x-client/entry/src/main/ets/theme/AppTheme.ets)、[专注记录](ux-09-focus-records.md)、[有依据的回看](ux-10-evidence-review.md)、[体验收口](ux-11-experience-polish.md) | [UX11 浏览器与逻辑记录](evidence/ux-11-checks.json)、[源码可访问性核对](evidence/ux-11-accessibility-audit.json)：窄屏、大字近似、未知结果、草稿保护；专注与回看用真实来源复算 | 原生键盘、安全区、字体缩放、读屏顺序、触区、音频、通知实际送达和设备性能；浏览器尺寸或耗时不能代替这些结果 |

## 给学长的设备操作表

使用专门的合成演示账号和课程，不导出真实学生资料。每行结果填写“通过／失败／未执行”，附平台、设备型号、系统及 SDK 版本、应用提交 SHA；同一项在三端分别记录，不能用一端代签。

| 项目与平台 | 可直接执行的操作 | 预期结果 | 保存的证据 |
|---|---|---|---|
| 构建、安装、冷启动：三端 | 按已有工具环境检查构建计划，再由设备负责人构建签名并安装；首次启动与重开各一次 | 同一共享源码能构建、打开；不因其他平台语音模块崩溃 | 三份构建日志、包名与版本、安装／启动短录像；本地签名秘密不入仓 |
| 文本与真实模型：三端 | 配置服务地址，登录合成账号；发送具体目标，再追问“保持该目标，把时长改成30分钟” | 上下文正确、可见输出与工具状态更新；须确认才写任务 | 每端两轮连续录像，所选模型 ID、脱敏运行状态／工具名；不拍 Key 或 Authorization |
| 离线历史与隔离：三端 | 在线打开会话后关闭应用；断网重开并回看。恢复网络登录，显式退出，再换另一账号 | 已缓存文字可读，无需重新请求模型；历史提案只读；退出后旧本机历史／草稿不向另一账号出现 | 每端断网重开、回看、退出后清理的连续录像；说明测试前哪些会话已缓存 |
| 鸿蒙语音必做 | 点“语音输入”，按说明授权；说一句目标，完成录音、改一个词、填入输入框，再手动发送；点回答“播报”并停止 | 识别不自动发送；能完成真实模型回答与播报；拒绝权限后仍可输入文字；离页／后台停止旧音频 | 录音与系统声音可辨的完整录像；拒绝／再次授权、停止操作分别留证 |
| Android／iOS 语音加分 | 在各自设备重复上一行；系统服务不可用时记录设备条件 | 能力可用时完成链路；不可用时给明确信息与文字回退，不假装识别成功 | 每端权限、服务版本及实际结果，未支持项记未验／失败 |
| 任务确认与课表变更：三端至少各走一次核心路径 | 先看候选再确认；增加一门与未完成任务重叠的课，查看改期预览后确认 | 只改对应 ID，预览不写；冲突、许可重叠与未核对项分开；不擅自移动已许可课内任务 | 原任务、课程重叠、改期前后及回执；对“未知”先核对原操作，不反复新建 |
| 通知与权限：声明支持的平台 | 在“个人设置”启用提醒，为未来任务设提醒；改期、完成、退出，检查旧通知是否撤销；重复一次权限拒绝 | 系统受理与真实送达分开；清理失败可重试；锁屏不含任务正文或账号 | 权限页、实际通知与触发时间、改期／退出后的结果；Android 非精确提醒允许系统延迟但须如实记录 |
| 专注、恢复与回看：三端 | 计时→暂停→继续→结束；再单独标记完成。另测后台／杀进程、恢复未完成和日期切换 | 未证明的尾段显示缺口，不补算；结束计时不自动完成任务；回看只计已确认时段与有效完成事实 | 连续操作录像，计时片段、缺口、完成回执和回看依据；设备可靠时钟不可用时不得假计时 |
| 新存储与布局：三端 | 从当前前一阶段版本保留数据升级；重开后恢复草稿／待核对操作。试大字、横屏、键盘和系统读屏 | 不丢旧数据、不重复提交；长文本完整，主要操作可达，键盘不遮挡输入与发送，读屏不重复装饰图 | 脱敏升级前后状态、每端屏幕／读屏录像；磁盘失败与容量场景若未测则单列 |

无需让用户本机安装 SDK；以上由已有工具链和设备的队友执行。只读 `build:plan:all`、Node 检查与测试替身不填作设备通过。数据库与本机存储迁移应先备份演示数据；当前新增账本没有承诺旧客户端／旧服务能安全继续写，回退源码不等于完成数据回滚。

本表不要求新部署、供应商对比评测或旧第十七阶段工程专项。验收后补证据与实际失败点，再由仓库维护者决定合并；未验项留在表内。
