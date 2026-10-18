# 累计版本编译配置与 Windows 兼容修复

当前代码入口为两个仓库各自的 `dev/haohao`，不再按阶段选择分支。完整范围见 [协作说明](haohao-collaboration.md)及 [48 个历史 PR 的祖先覆盖记录](evidence/collaboration-pr-coverage.json)。本分支保留历史功能与原作者提交；修复集中在当前完整版本。

**最新进展：** 学长已对上一版 `4b759f8` 执行真实原生编译，配置校验通过，但 CompileArkTS 仍失败。本轮 43 处诊断的源码处理及复编交接见 [PR #30 原生诊断修复](arkts-review-repair.md)；新的原生结果仍待复编，不能将下方早期预检记录解释为已通过原生编译。

## 学长建议与对应处理

| 来源 | 问题 | 修复与保留的语义 |
| --- | --- | --- |
| [#5](https://github.com/lengyu888/CampusFlow/pull/5#discussion_r4305506859) | HistoryPage 未知 catch 值直接 throw，触发 10605087 | 在 catch 内生成明确的 Error 后抛出。404 仍可清理已消失会话；其他失败中止删除，保留本机内容。 |
| 同类审查 | AgentPage 切换会话、FocusController 清缓存也直接抛未知值 | 复用带错误码的请求异常；未知值转换为 Error。失败继续阻断切换/清理流程，不把异常吞掉或伪装成功。 |
| [#7](https://github.com/lengyu888/CampusFlow/pull/7#discussion_r4305505046) | 顶层 ignoreCrossPlatform 不符合工程所用插件 schema，触发 00303038 | 将字段移入 buildOption。保持 crossplatform:true、语音驱动和 Android/iOS Bridge，不通过删除功能规避检查。 |
| [#15](https://github.com/lengyu888/CampusFlow/pull/15#discussion_r4305505209) | 缺少系统时区数据库时后端导入失败 | 正式运行依赖声明 tzdata；保留真实 IANA 时区规则，不用默认 UTC 或全局固定 UTC+8 掩盖缺库。 |
| [#29](https://github.com/lengyu888/CampusFlow/pull/29#pullrequestreview-5561208616) | Windows 下测试脚本和夹具失败 | 修复 CRLF、文件 URL 转路径、超长命令参数、pytest 超长 ID、Unix 专用 tzset 和禁网夹具误伤内部 socketpair。保留原测试断言和禁止外网规则。 |
| 新增 ArkTS 定向复核 | 对象展开、缺少明确接口关系、Builder 可空参数 | 显式复制学习偏好与提醒快照；API 实现 8 个 Gateway；平台接口统一具名类型；校园图标与插图入口分离。保留隔离、惰性加载和点击行为。 |
| 全部累计脚本关联检查 | Windows 工具探测/启动、中文空格路径和编码 | 识别 PATHEXT 中的 cmd/bat，通过固定参数的受控启动调用已有工具；支持 Windows venv 路径；Java 源明确 UTF-8；PowerShell 构建回到项目目录。 |

## 配置修复依据

仅查阅官方 registry 包元数据和归档，没有安装或执行原生工具链：

- 工程固定 `@ohos/hvigor-ohos-arkui-x-plugin:4.24.2`。
- 此插件声明的开发配套为 `@ohos/hvigor-ohos-plugin:6.24.2`、Hvigor 6.24.2。
- 配套包的 `package/res/schemas/arkui-x-config-schema.json`、`ArkUIXConfigJson.ConfigObj` 类型声明与 `CoreModuleModelImpl.isIgnoreCrossPlatformCheckModule` 实现都读取 `buildOption.ignoreCrossPlatform`。
- 完整包 hash、schema、读取代码片段见 [配置核查证据](evidence/hvigor-schema-verification.json)。它证明修复位置，不能代替学长机器上实际解析到的包版本及编译结果。

`npm run check` 现在会拒绝旧的顶层字段、错误类型和未经核对的插件版本变化。输出明确为“工程文件与契约预检”，不再把这种轻量检查叫做原生验收。

## 安装依赖与已有环境验证

本次增加一个 Python 正式依赖。已有环境拉取后需要重新安装项目声明依赖，单纯 git pull 不会安装 tzdata：

```sh
python -m pip install -e "./agent-service[dev]"
cd agent-service
python -m ruff check src tests
python -m pytest -q -m "not integration"
cd ../arkui-x-client
npm test
npm run check
npm run test:journey
```

最后一条通过本机 Python 子进程执行真实 ASGI/SQLite 与客户端方法的合成流程，模型返回由脚本控制，不访问真实云模型或校园账号。若已有 Python 环境不在默认路径，可用 `CAMPUSFLOW_TEST_PYTHON` 指定其可执行文件；Windows 可使用 `Scripts/python.exe`。

跨平台 CI 运行相同检查，并且记录实际提交号。Windows 上仅 Unix 进程 TZ 切换专用检查按平台跳过，普通时间解析和缺系统时区库回归仍必须通过。只有确实缺少工具的原生源码辅助检查允许明确跳过，不能通过禁用失败测试取得绿灯。

## 原生编译交接

当前用户不下载 DevEco、SDK、模拟器，不执行原生构建。请学长使用已经配置的 DevEco 6.1.1 / ArkUI-X API24，在 `dev/haohao` 的明确 commit 上：

1. 记录 `git rev-parse HEAD` 与实际插件/SDK 版本，确认工作区没有混入其他分支文件。
2. 先运行配置预检，再按现有 `npm run build:hap` 执行完整 assembleHap，保留完整日志和生成的 HAP 文件信息。构建脚本使用已有工具，不代表本次已在这里运行。
3. 若还有新的 CompileArkTS 错误，按首个错误继续在同一协作分支修复；不要混用旧阶段快照。
4. Android、iOS 构建及 ASR/TTS、存储等设备行为另行验证。鸿蒙 HAP 成功不能代替其他平台或设备结果。

### main 合入条件

本分支修复尚未进入 main。2026-10-18 核对时，个人仓库 main `3043f0c6a65f4aa60fdb81dcee1c55426ba75888` 仍含上述两项已知配置/异常抛出问题；学长仓库 main `41955b068ec150197faf04bdc8341f7306f45b54` 未包含这两项问题。学长较早版本构建成功也不能作为本次累计新功能的编译证据。

合入前，当前提交的 Windows/Linux 检查须全部通过，并由已有环境的同学对与最新 main 合并后的候选执行真实原生构建。记录精确 commit、实际工具和 SDK 版本、完整日志、退出码 0 以及该次生成 HAP 的路径和 SHA256。原生失败仍在 `dev/haohao` 修复；保持 PR 为 Draft，不能把轻量预检绿灯当作允许合入的充分条件。main 或修复代码变动后重新验证对应候选，合入后对最终 main 提交执行构建确认。工作流也在未来 main 提交上运行离线兼容检查，但本工作流没有原生编译步骤。

本次没有改变 UI 配色、计划规则、课程重叠确认规则、数据格式或数据库迁移，也没有部署服务。

## 上一轮验证记录（4b759f8；保留历史证据）

2026-10-18 本地 Mac 实际执行结果：后端 947 passed、2 项真实模型 integration 排除；Ruff 通过。补充 ArkTS 修复后的客户端 1157 项，1153 passed、0 failed、4 skipped（本机无 JDK 的既有检查 1 项、仅 Windows 执行的测试 3 项）。补充修复后工程预检覆盖 92 个 ArkTS/TS、21 个配置文件。连续客户端/后端流程 14 步通过，最初 89 次、补充修复后 88 次 ASGI 请求（含轮询，次数可随调度变化），全程合成账号和脚本模型。

另在中文和空格隔离路径，将全部客户端文本转为 CRLF，运行当时完整 1152 项客户端测试：1150 passed、0 failed、2 skipped；随后新增的两项 Windows 专用测试不在该次结果内。本机模拟不是 Windows 实跑。

补充修复后共 92 个 ArkTS/TS（新增一个仅类型声明的共享文件），定向同类风险检查见 [源码核查记录](evidence/arkts-source-risk-audit.json)，它不检查全部 ArkUI 编译规则。补充的对象复制、类型关系与 Builder 参数依据官方规则，详见同一证据文件；原生编译仍待学长执行。

首轮 GitHub Windows 实跑发现旧超时测试假设 25ms 内一定已开始工具，在较慢磁盘上实际可以先正常到期。已将该测试改为在工具开始后控制真实 asyncio.Timeout 的到期时刻，并新增工具开始前到期的检查；不改变产品超时，也不删除失败断言。修订后结果以新提交的 CI 为准。

本段随本协作 PR 更新。完整 Windows/Linux CI 结果和最终提交号以 PR 检查及发布回执为准；在结果回来前不声称跨平台全绿或可原生编译。
