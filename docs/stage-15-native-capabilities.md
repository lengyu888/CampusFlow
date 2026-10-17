# 第十五阶段：语音、系统提醒与三端构建入口

基线：第十四阶段 `feat/stage-14-data-evidence`。本阶段只在独立分支修改，原作者历史及两个仓库的 main 保留。

## 具体用途

- Agent 的同一套语音入口、识别草稿、取消、发送、播报及停止交互，接入鸿蒙 Core Speech、Android SpeechRecognizer/TextToSpeech、iOS Speech/AVSpeechSynthesizer。识别先成为可编辑草稿，由用户发送；页面离开、后台或音频中断停止当前语音，迟到回调不能改新会话。
- 个人设置可明确启用、核对或关闭本机提醒。只使用服务端已确认且有时间与提醒设置的任务；改期重排，完成/删除撤销，删除计划后保留的独立任务继续提醒。全天/无日期任务不擅自猜提醒时间。
- 系统提醒使用真正的系统调度 API。鸿蒙安排近期最多 30 项，Android/iOS 本阶段最多 60 项，超过容量明确显示限制，重新打开应用核对。Android 为非精确提醒，可能被延迟；系统受理不等于实际送达。
- 网络失败或不完整任务快照不会被当作空列表清空提醒。账号切换先清原账号提醒；退出立即清登录状态，系统清理失败单独提示并允许重试。持久账本保留未完成操作的归属，重启后先恢复清理。

## 实现边界

共享 ArkTS 状态机负责业务。Android/iOS 通过 ArkUI-X Bridge 的 `CampusFlowPlatform` 通道交换有版本、请求 ID 与操作 ID 的 JSON；`dispatch` 只确认收件，最终结果由 `onEvent` 回传。权限只在用户明确使用语音或启用通知时申请，能力探测不弹权限。平台适配全部使用系统 API，不保存音频，不把凭据送入原生桥；系统识别服务本身可能联网，不宣称完全离线。

通知锁屏内容固定为“CampusFlow 提醒 / 你有一项安排即将开始，打开应用查看。”，不含任务正文或账号。账本仅保留本地账号作用域、任务 ID、触发时间、系统 ID 和清理状态。点击通知打开应用，不承诺定位单项详情。Android 常规重启恢复未来提醒；强行停止、厂商后台策略及通知授权影响仍需设备检查。iOS 用串行队列与清理屏障防止授权/添加的迟到回调恢复已退出账号的提醒。

## 构建交接

在 `arkui-x-client` 中：

```sh
npm run build:plan:all        # 只打印/检查构建计划，不启动原生工具
npm run build:harmony        # 已有完整原生环境时才执行
npm run build:android
npm run build:ios            # macOS，ace build ios --debug --nosign
```

`build-native.mjs` 默认 dry-run，只有 `--execute` 调用已存在的 ACE，可用 `CAMPUSFLOW_ACE_BIN` 指定路径。它不会安装 SDK、创建/覆盖工程或启动设备；实际执行已有构建工具仍可能解析或下载构建依赖。本轮未执行上述三个实际构建命令。成功构建的本地记录 `.native-build-*.local.json` 被 Git 忽略，且明确 `device_verified: false`。

工程当前声明 Harmony SDK 6.1.1/API24、Android min26/target33、iOS最低10；iOS识别按可用性判断。Bridge 适配按官方 API11 manager 构造形式编写，现有 ArkUI-X 引擎版本没有在本机验证，需在学长准备好的工具链核对。iOS 已移除旧团队签名/profile硬编码；本地配置自己的团队签名，鸿蒙也需本地签名配置。保留既有 Windows HAP 脚本与工程结构。

## 本轮检查与待验

检查包含共享语音/提醒状态机、真实 ArkTS 源码提取执行、模拟系统提醒和文件系统、Android/iOS 源码协议检查、XML/plist工程语法与构建 dry-run。完整客户端检查 567 项：566 通过、1 项明确跳过、0 失败；静态检查 52 个 ArkTS/TS 文件与 17 个配置通过。Android 11 项源码契约与 iOS 20 项源码契约检查包含在该总数中；plist/Xcode 工程、XML、三端构建 dry-run 与 diff 检查通过。Android 纯 Java 辅助类测试因本机无 JDK 明确跳过。服务端本阶段未改动，复用第十四阶段 497 项离线测试证据。

未安装原生 SDK、JDK、模拟器；没有三端原生编译、签名、安装或设备验证。因此本阶段结论是“原生适配源码、接线和离线检查已完成”，不是“三端已验证可用”。设备验收需覆盖首次/拒绝/撤销权限、识别最终结果、TTS停止与中断、后台与重启提醒、改期/完成/删除、退出/换账号和系统省电限制；使用真实云模型的整条 ASR→Agent→TTS 仍需已配置账号。按最新指示不开展第十七阶段和真实模型评测。

## 官方依据

- [ArkUI-X Bridge API](https://github.com/arkui-x/docs/blob/master/zh-cn/application-dev/reference/apis/js-apis-bridge.md)、[Android 接线](https://github.com/arkui-x/docs/blob/master/zh-cn/application-dev/tutorial/how-to-use-bridge-on-android.md)、[iOS 接线](https://github.com/arkui-x/docs/blob/master/zh-cn/application-dev/tutorial/how-to-use-bridge-on-ios.md)
- [Android SpeechRecognizer](https://developer.android.com/reference/android/speech/SpeechRecognizer)、[TextToSpeech](https://developer.android.com/reference/android/speech/tts/TextToSpeech)、[AlarmManager](https://developer.android.com/develop/background-work/services/alarms)
- [Apple Speech](https://developer.apple.com/documentation/speech/sfspeechrecognizer)、[AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer)、[UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)
- [鸿蒙提醒代理与容量](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/task-management/agent-powered-reminder.md)、[notificationManager](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-notification-kit/js-apis-notificationManager.md)
- [ACE 构建命令](https://github.com/arkui-x/cli)
