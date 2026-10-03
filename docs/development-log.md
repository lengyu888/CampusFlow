# 开发日志

## 2026-10-03：请求级密钥与测试控制台

- 阅读新增开放命题说明，将 HarmonyOS + Android 作为硬性端，iOS 作为选做端。
- DeepSeek API Key 改为前端请求级输入，不写入浏览器存储、服务端 Store 或日志。
- 增加 `deepseek-v4-pro` 与 `deepseek-flash` 模型选择。
- 增加同源 Web 测试台，支持多轮对话、工具轨迹、事务确认和快捷场景。
- 更新 API 契约与自动化测试。

## 2026-09-28：Agent 服务初始骨架

- 初始化 Git 仓库，默认分支为 `main`。
- 根据 9 月 24 日会议纪要确定大学规划与执行场景。
- 建立 FastAPI + LangChain + DeepSeek Agent 服务结构。
- 增加课程、天气、校园通知、地点与事务提案工具。
- 采用“Agent 生成提案、客户端显式确认、API 执行写入”的安全流程。
- 增加离线 API/工具测试及可选真实 DeepSeek 集成测试。
- 补充 ArkUI-X HTTP 联调约定。

