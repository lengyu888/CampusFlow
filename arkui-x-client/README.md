# CampusFlow ArkUI-X 客户端

这是 CampusFlow 的 ArkUI-X/ArkTS 原生客户端，工程已按官方 ACE Tools 转换为 HarmonyOS、Android、iOS 三端结构，并升级到 ArkUI-X 6.1.1 / API 24。共享 ArkTS 代码覆盖以下核心流程：

- 登录与注册（注册时提交 DeepSeek API Key，后续登录不再填写）
- 首次学校、校区、学期和 HDUHelp 课表订阅配置
- 今日课程和 Agent 快捷入口
- DeepSeek V4 Pro / Flash 多轮对话与操作确认
- 基于杭电校园数据包的原生 Canvas 路线图
- 待办创建、完成状态和进度概览
- 官方 Skills 安装、权限展示与启停
- 个人设置、API Key 更新和课表同步
- HDUHelp OAuth 授权、个人校园数据同步与断开清理

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
│       │   ├── pages/        # 五入口、登录和首次配置
│       │   └── services/     # 统一 HTTP/Bearer 请求层
│       └── resources/
└── scripts/                  # 静态验收与可复现 HAP 构建脚本
```

## 本机运行准备

1. 安装 DevEco Studio 6.1.1 Release，并配置 ArkUI-X SDK 6.1.1 / API 24。
2. 在 DevEco Studio 中打开本目录，等待 Hvigor 同步。
3. Android、iOS 宿主工程已由官方 ACE Tools 生成并纳入版本管理；修改模块或平台配置后再运行 `ace modify --project` 同步。
4. 先启动仓库中的 FastAPI 服务，再运行 `entry`。

登录页可直接修改服务地址：

- HarmonyOS/Android 真机：`http://<开发电脑局域网 IP>:8000`
- Android 模拟器：`http://10.0.2.2:8000`
- iOS 模拟器与本机预览：`http://127.0.0.1:8000`

Android/iOS 宿主目前仅为本地联调开启了 HTTP 明文访问；发布版本应改用 HTTPS，并移除 Android `usesCleartextTraffic` 与 iOS `NSAllowsArbitraryLoads`。当前阶段 Token 只保存在进程内存，重启 App 后需要重新登录，不会明文写入文件。下一子阶段会接入各平台安全凭据存储与本地通知。

## 命令行构建与验收

项目在 Windows 上提供可复现的 HAP 构建脚本。默认查找：

- DevEco Studio：`C:\Program Files\Huawei\DevEco Studio`
- ArkUI-X SDK：`%LOCALAPPDATA%\ArkUI-X\Sdk`

路径不同时，可先设置 `DEVECO_STUDIO_HOME` 和 `ARKUIX_SDK_HOME`。然后运行：

```powershell
cd arkui-x-client
npm run check
npm run build:hap
```

调试 HAP 输出到 `entry/build/default/outputs/default/`。未配置签名证书时会生成 `entry-default-unsigned.hap`，可以完成编译验收，但真机安装前仍需在 DevEco Studio 中配置自动签名。

ACE 开发环境可用 `ace check -v` 检查。当前 Windows 阶段已验证 HarmonyOS 与 ArkUI-X 工具链；构建 Android APK 还需安装 Android Studio/Android SDK，iOS 构建需在 macOS/Xcode 上进行。

## 仅做静态验收

```powershell
cd arkui-x-client
npm run check
```

该脚本检查工程必需文件、JSON/JSON5 语法、ArkTS 相对导入、密钥泄漏、网络权限，以及客户端与 FastAPI 的关键接口契约。依赖目录和构建产物会被排除。它不能替代 DevEco Studio 的 ArkTS 类型检查和真机安装测试。
