# 第六阶段：Agent 语音输入与回答播报

基于第五阶段 `2cddc3209211dff86cd848d02a6ea7f0f114b3e9`，在独立分支 `feat/agent-voice-interaction` 实现。此阶段交付客户端代码与模拟测试，**未安装原生环境，未执行 SDK 编译、设备录音或实际播报验收**。

## 具体作用

- 在 Agent 输入区点「语音输入」，允许麦克风权限后说出目标，点「完成录音」。
- 识别文字会出现在可编辑框中。点「填入输入框」会追加到已有草稿，检查后仍需手动发送。
- Agent 返回回答后，可点该回答的「播报」。原位置和底部输入区均可停止播报。
- 权限拒绝、无识别结果、服务不可用、超时均有提示，原文字草稿保留，可继续打字。
- 切换底部页面或退到后台会停止语音；已识别文字保留在编辑区，返回不会自动录音或自动播报。销毁页面时释放引擎。

语音识别和播报使用鸿蒙系统能力；真实对话继续调用原有云端 Agent 接口。没有新增后端接口或模型密钥。Android / iOS 当前保留文字对话，点击语音入口会说明当前设备不支持；本阶段不宣称两端具备语音能力。

## 交互与边界

| 状态 | 页面行为 |
| --- | --- |
| 准备中 | 显示麦克风授权/引擎准备提示，可取消；30 秒超时退出 |
| 录音中 | 显示实时识别文字，可完成或取消；最长 60 秒后请求结束录音 |
| 整理结果 | 显示进度，可取消；15 秒超时后保留已有文字供核对 |
| 核对文字 | 可编辑、放弃或追加到原输入；按 Unicode 字符检查合并后 8000 字限制，超限不截断双方内容 |
| 准备播报 / 播报中 | 仅用户点击后开始；可随时停止；切换回答会停止上一条 |
| 错误 | 展示安全的中文提示，不显示原生诊断、账户或凭据信息；文字输入仍可用 |

录音过程中、识别结果尚未使用或放弃时，发送按钮暂停，防止误发不完整内容。语音不会自动发送消息或确认计划。开始新请求会停止上一条回答的播报；新回答不会自动播放。

识别区在可滚动的会话内容中，文字输入和取消/停止入口留在底部；按钮至少 48vp，并提供可访问性标签。键盘、大字体、安全区等实际布局仍需设备验收。

CampusFlow 不保存原始录音；识别文字在手动发送前只保留为页面草稿，发送后的文字按既有对话和本地历史规则保存。适配器明确使用离线引擎参数，不在离线服务不可用时自动切换云端 ASR/TTS。

## 实现位置

| 文件 | 职责 |
| --- | --- |
| `entry/src/main/ets/pages/AgentPage.ets` | 语音入口、转写编辑、追加草稿、回答播报和停止按钮；沿用原发送/提案确认流程 |
| `entry/src/main/ets/utils/VoiceInteraction.ets` | 平台无关状态机、超时、取消、暂停保留文字、迟到回调隔离、朗读文本转换 |
| `entry/src/main/ets/services/PlatformVoiceDriver.ets` | 先检查操作系统与能力，再延迟加载鸿蒙适配器；非鸿蒙端不执行语音模块初始化 |
| `entry/src/main/ets/services/HarmonyVoiceDriver.ets` | 麦克风权限、ASR/TTS 引擎调用、回调处理与释放 |
| `Index.ets` / `EntryAbility.ets` | 将页面是否选中、应用是否在前台传给语音交互 |
| `module.json5` / `string.json` | 声明按需申请的麦克风权限及中文用途说明 |

以上路径以 `arkui-x-client/` 为根。`AppIcon` 增加麦克风、扬声器、停止图形，沿用第五阶段样式。

ASR partial 结果替换当前句，final 才累加；`isFinal && isLast` 或 `onComplete` 结束本轮。TTS 只在 `CompleteResponse.type === 1`（播放完成）后推进下一段，不能把合成完成误判成播放完成。回答按每段 500 个 Unicode 字符串行播报，不截断长回答；Markdown 代码块、链接地址等不适合朗读的内容会过滤。引擎启动迟到、旧请求回调、取消触发同步回调均有操作标识隔离。

### 跨端构建注意

按 ArkUI-X 官方平台差异化方案，在 `.arkui-x/arkui-x-config.json5` 增加 `ignoreCrossPlatform: true`，允许工程包含鸿蒙专有 API；仅 `HarmonyVoiceDriver` 引用 `@kit.CoreSpeechKit`。共享页面通过平台判定后的相对动态导入接入。

**动态导入仍是编译依赖，配置也不会把鸿蒙 API 变成跨端 API。** 项目目标 SDK 为 `6.1.1(24)`，本次核对到的语音核心接口参考为官方 V13 文档，尚未使用 API 24 SDK 检查声明与构建。学长需确认该 SDK 的 CoreSpeechKit 类型、配置接受情况及 Android/iOS 冷启动；不能以 Node 测试通过替代这些验收。设备缺少离线语音服务时应保持明确失败提示与文字回退，不自动下载系统资源。

接口依据：

- [华为 ASR 接口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V13/hms-ai-speechrecognizer-V13)：`online: 1` 为离线；`recognitionMode: 0` 为系统麦克风录音；结束录音使用 `finish`，取消使用 `cancel`。
- [华为 TTS 接口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V13/hms-ai-texttospeech-V13)：系统自动播放模式及合成/播放完成回调。
- [ArkUI-X 平台差异化](https://github.com/arkui-x/docs/blob/master/zh-cn/application-dev/quick-start/platform-different-introduction.md)、[ArkTS 动态导入](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/arkts-utils/arkts-dynamic-import.md)。
- [申请用户授权](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/request-user-authorization.md)。

## 已执行检查

在 `arkui-x-client/` 执行：

```sh
node --test scripts/test-*.mjs
npm run check
git diff --check
```

- 客户端测试 **166 项通过**：原有 104 项 + 语音控制器 23 项 + 鸿蒙适配器 16 项 + 平台/生命周期 11 项 + 页面语音集成 12 项。
- 静态检查通过：32 个 ArkTS/TS 文件、17 个配置文件，检查工程配置、导入和既有 API 契约等；不是原生编译器。
- 新测试执行真实控制器、驱动和页面非 UI 方法，以模拟权限、引擎、时钟和网络边界。覆盖原草稿保留、禁止自动发送/确认、权限拒绝、迟到授权、取消、后台停止、整段文字播报及错误清理。

## 学长接手验收

1. 在已有原生环境检查目标 SDK 下的 ASR/TTS 类型，编译鸿蒙、Android、iOS；确认后两端冷启动和文字对话不因语音模块受影响。
2. 鸿蒙首次授权、拒绝授权、系统撤回授权后重试；录音取消、静音无结果、麦克风被占用、短句自动结束及手动结束。
3. 原输入已有文字时说话，修改识别结果后追加，再手动发送；确认真正完成 ASR → 云端 Agent → 手动 TTS。
4. 验证长回答多段播报、播放完成/停止、快速切换回答、播报时发送新问题、系统音频打断。
5. 录音/播报时切换底部页面、进入历史/路线、退后台及退出账号；应立即停止，返回不自动恢复，旧回调不得写入新会话。
6. 竖屏小尺寸、大字体和键盘弹出时，检查识别编辑框可滚动、下方原输入可编辑、发送/取消/停止按钮可触达；检查原始录音未落盘。

以上均为**待执行**，PR 保持 Draft。验收后再由仓库维护者决定合并。

## 分支与后续

此分支顺序继承前五阶段。它们尚未合并时，面向 `main` 的 PR 包含累计差异；单看本阶段请查看第六阶段提交或与 `2cddc32` 对比，避免重复挑选前序改动。只推送新分支，不推送主分支、覆盖其他分支或自动合并。

本阶段完成后停止。下一步可依据学长的原生验收反馈修复适配问题，再完善语音演示流程；等待用户说「继续」后开展。
