# 模型目录与供应商接入

默认保留 `deepseek-v4-pro`、`deepseek-flash`，使用用户保存的 DeepSeek Key。额外模型由部署者明确配置，使用独立的服务端凭据。配置一个模型或通过离线协议测试，都不代表该供应商已经联网验证、取得权限或完成效果评测。

## 配置额外模型

`agent-service/.env` 可填写 `MODEL_CATALOG_JSON` 和 `MODEL_DEFAULT_ID`。下例为配置结构示例；`api_model` 必须换成供应商实际支持的模型名，能力值应由部署者核对后填写。代码默认 `[]`，没有新增模型费用。

```dotenv
MODEL_DEFAULT_ID=deepseek-v4-pro
MODEL_CATALOG_JSON='[{"id":"campus-standard","label":"部署者配置的模型","provider":"供应商名称","api_model":"replace-with-provider-model","base_url":"https://api.openai.com/v1","key_env":"CAMPUSFLOW_STANDARD_API_KEY","protocol":"openai","token_limit_parameter":"max_completion_tokens","supports_tools":true,"supports_streaming":true,"supports_reasoning":false}]'
```

`key_env` 指定的变量只能从**服务进程环境**读取，应通过服务的 secret/environment 配置注入。未知动态变量不会仅因写入 `.env` 就被自动加载。不要把真实密钥写入模型目录、Git、截图或命令日志。

- 内置 DeepSeek 继续使用个人凭据；额外模型忽略传入的个人 Key，缺少自己的环境变量时拒绝请求。不存在跨供应商回退。
- `base_url` 只允许不含 userinfo、查询参数、片段或控制字符的 HTTPS API 地址。管理员负责选择可信供应商；地址不能由客户端提供。
- 最多配置 20 个额外模型。ID 唯一且有长度/字符限制；未知字段、错误能力类型、重复 ID、未注册的默认模型使服务启动失败，并返回固定配置错误而不回显 JSON。
- `protocol` 当前只支持标准 OpenAI Chat Completions；不代表支持所有“OpenAI 兼容”扩展。`token_limit_parameter` 仅允许 `max_tokens` / `max_completion_tokens`，需按实际供应商协议选择。
- `supports_reasoning` 是能力声明，不会自动添加供应商私有参数、展示或保存思维过程。额外模型不会收到 DeepSeek 的 `thinking` / `reasoning_effort` / `reasoning_content`。
- 工具调用与流式输出是当前应用必需能力。任一未声明支持时，旧聊天和新运行接口都在执行前拒绝；新运行不会留下运行记录。目录的 `available` 仅表示能力声明与凭据存在，不是联网健康检查。

## 接口与恢复

登录后的 `GET /api/v1/models` 返回 `models` 和 `default_model`。每项只有 `id`、`label`、`provider`、三个能力布尔值、`available` 与 `unavailable_reason`。响应不含环境变量名、密钥或内部 API 地址。

| 错误码 | 含义 |
| --- | --- |
| `MODEL_NOT_FOUND` | 模型未注册或已移除，HTTP 400 |
| `MODEL_CAPABILITY_UNSUPPORTED` | 工具或流式能力未满足，HTTP 409 |
| `MODEL_KEY_REQUIRED` | 缺少个人 DeepSeek Key，HTTP 409 |
| `MODEL_PROVIDER_KEY_REQUIRED` | 缺少额外供应商服务端 Key，HTTP 503 |
| `MODEL_AUTH_INVALID` | 供应商拒绝模型凭据，不等于 CampusFlow 登录失效 |
| `MODEL_RATE_LIMITED` / `MODEL_UNAVAILABLE` | 供应商限流或不可用；不自动换供应商 |

已经受理的同 ID 运行仍先查回执，即使后来移除凭据，也不会因为重试触发新请求。旧历史保留原模型 ID；不因目录变化把历史改名，也不会因此允许选择已移除模型。

新运行保留原有整轮超时、调用数与内容预算、取消检查、幂等回执和成功历史事务。DeepSeek 的有工具思考模式在本轮内按协议回传私有上下文，不向前端发送、不持久化。旧 `/chat` 兼容链路显式关闭 DeepSeek 思考模式，因为当前 LangChain 的通用消息转换不会保留其私有续轮字段；新运行仍按 `DEEPSEEK_THINKING_ENABLED` 配置。旧链路通过 SDK `extra_body` 保留声明的 `max_tokens` 字段，防止 LangChain 自动改为 `max_completion_tokens`。

## 验证与外部条件

`tests/test_model_catalog.py` 使用合成密钥、隔离 SQLite、真实 SDK + `httpx.MockTransport`，覆盖目录校验、跨供应商凭据隔离、请求参数、流式工具续轮、旧聊天协议、请求前拒绝、回执查询和密钥不入库。没有调用真实模型或产生模型费用。

供应商账号权限、真实响应、延迟、额度、成本与效果仍需部署者在另行授权后验证；本阶段未做真实模型评测。视觉识别服务继续沿用现有配置，本目录只接 Agent 的文本/工具聊天入口。

实现核对资料（2026-10-18 查阅）：

- [DeepSeek Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode/)：思考开关和工具续轮私有字段。
- [OpenAI Chat Completions API](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)：标准消息、工具、流和 token 上限参数。
