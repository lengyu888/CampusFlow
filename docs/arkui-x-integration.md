# ArkUI-X 与 Agent 服务联调说明

## 参考的官方样例组织方式

ArkUI-X 官方 Samples 将共享 ArkTS 页面放在 `entry/src/main/ets`，Android 和 iOS 平台工程放在 `.arkui-x/android` 与 `.arkui-x/ios`。本项目的文本 Agent 不需要原生 Bridge，ArkTS 可以直接调用 FastAPI；语音、原生日历和通知等能力再参考 `SuperFeature/PlatformBridge` 进行平台桥接。

- Samples：https://gitcode.com/arkui-x/samples/tree/master
- PlatformBridge：https://gitcode.com/arkui-x/samples/tree/master/SuperFeature/PlatformBridge

## API 契约

### 对话

`POST /api/v1/chat`

```json
{
  "user_id": "demo-student",
  "session_id": "session-001",
  "api_key": "用户在客户端填写的 DeepSeek API Key",
  "model": "deepseek-v4-pro",
  "message": "明天下午帮我安排两小时复习高数"
}
```

响应：

```json
{
  "session_id": "session-001",
  "message": "我需要先确认你明天下午可用的具体时间范围。",
  "tool_traces": [],
  "pending_actions": []
}
```

### 确认事务操作

`POST /api/v1/actions/{proposal_id}/confirm?user_id=demo-student`

只有用户点击客户端确认按钮后才调用该接口。

### 会话历史

`GET /api/v1/sessions/{session_id}/history?user_id=demo-student`

## ArkTS 请求示意

以下代码用于说明请求结构，具体 `http` API 导入方式需按团队锁定的 ArkUI-X SDK 版本调整。

```ts
interface ChatRequest {
  user_id: string
  session_id: string
  api_key: string
  model: 'deepseek-v4-pro' | 'deepseek-flash'
  message: string
}

interface ChatResponse {
  session_id: string
  message: string
  tool_traces: Object[]
  pending_actions: Object[]
}

// 将 JSON.stringify(request) 作为 POST body 发送至 /api/v1/chat
```

## 不同运行环境的服务地址

| 运行位置 | Agent 服务地址示例 |
|---|---|
| HarmonyOS 真机 | `http://开发电脑局域网IP:8000` |
| Android 模拟器 | `http://10.0.2.2:8000` |
| Android 真机 | `http://开发电脑局域网IP:8000` |
| iOS 模拟器 | `http://127.0.0.1:8000` |
| iOS 真机 | `http://开发电脑局域网IP:8000` |

真机与电脑需要位于同一局域网，并允许防火墙访问 8000 端口。生产环境必须使用 HTTPS。

## 推荐的客户端状态

```text
idle → sending → planning → calling_tool → waiting_confirm → completed
                                      └──→ failed / retry
```

客户端应显示 `tool_traces`，并把 `pending_actions` 渲染为确认卡片。不要根据模型自然语言直接执行日程写入。API Key 应保存在页面内存/输入控件中，禁止写入本地数据库、日志或版本库。

