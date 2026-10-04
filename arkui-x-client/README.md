# CampusFlow ArkUI-X 客户端

这是 CampusFlow 阶段 6 的 ArkUI-X/ArkTS 客户端骨架，工程结构对齐 ArkUI-X 官方 Stage 模型样例。共享 ArkTS 代码覆盖以下核心流程：

- 登录与注册（注册时提交 DeepSeek API Key，后续登录不再填写）
- 首次学校、校区、学期和 HDUHelp 课表订阅配置
- 今日课程和 Agent 快捷入口
- DeepSeek V4 Pro / Flash 多轮对话与操作确认
- 基于杭电校园数据包的原生 Canvas 路线图
- 待办创建、完成状态和进度概览
- 官方 Skills 安装、权限展示与启停
- 个人设置、API Key 更新和课表同步

## 工程结构

```text
arkui-x-client/
├── .arkui-x/                  # 跨端模块声明；Android/iOS 工程由 ArkUI-X 工具生成
├── AppScope/                  # 应用级资源与包信息
├── entry/
│   └── src/main/
│       ├── ets/
│       │   ├── components/   # 路线图等共享组件
│       │   ├── model/        # FastAPI JSON 类型
│       │   ├── pages/        # 五入口、登录和首次配置
│       │   └── services/     # 统一 HTTP/Bearer 请求层
│       └── resources/
└── scripts/static-check.mjs  # 无 SDK 环境也可运行的结构与契约检查
```

## 本机运行准备

1. 安装 DevEco Studio 5.0.0 Release 或更新版本，并配置 ArkUI-X SDK 5.0.0 Release 或更新版本。
2. 在 DevEco Studio 中打开本目录，等待 Hvigor 同步。
3. 使用 ArkUI-X 工具生成/同步 Android、iOS 平台工程；这些生成目录不在当前提交中维护。
4. 先启动仓库中的 FastAPI 服务，再运行 `entry`。

登录页可直接修改服务地址：

- HarmonyOS/Android 真机：`http://<开发电脑局域网 IP>:8000`
- Android 模拟器：`http://10.0.2.2:8000`
- iOS 模拟器与本机预览：`http://127.0.0.1:8000`

HTTP 明文只用于本地开发；发布版本应使用 HTTPS。当前阶段 Token 只保存在进程内存，重启 App 后需要重新登录，不会明文写入文件。下一子阶段会接入各平台安全凭据存储与本地通知。

## 无 ArkUI-X SDK 时的验收

```powershell
cd arkui-x-client
npm run check
```

该脚本检查工程必需文件、JSON/JSON5 语法、ArkTS 相对导入、密钥泄漏、网络权限，以及客户端与 FastAPI 的关键接口契约。它不能替代 DevEco Studio 的 ArkTS 类型检查和真机安装测试。
