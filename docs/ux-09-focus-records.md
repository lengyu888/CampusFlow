# UX09 · 给一件事留一段专心时间

从首页或计划中的具体待办开始专注，目标时长可留空。到达目标只提示，不会自动完成待办。结束后可另行标记任务完成，复用 UX08 的版本核对与完成回执。

## 计时与恢复

切换应用内页面继续计时，应用退到后台暂停。单调时钟每秒采样、约每5秒保存本机检查点；不按定时器调用次数累计。采样断档、系统时间异常、进程中断的未核实尾段单独提示，绝不按日期差补算。记录时长不代表有效学习。

联网开始/继续先取得操作回执并核对当前记录。明确选择“仅本机”后可以本机记录，再主动同步；本机模式不能保证其他设备没有同时记录。网络结果未知时保留原操作与内容，只查询原操作；确认未查到后才提供原请求重试。

服务端同账号最多一个进行中或暂停中的记录。操作使用独立 UUID、期望版本和原子回执；记录删除保留最少去重元数据，旧离线请求不能重建已删除记录。任务删除后已建专注历史仍可查，标题显示原任务已删除。

## 数据边界

记录、片段和操作均按账号隔离。服务端只保存任务ID，不重复保存任务标题或正文；读取时从当前任务关联标题。原始开机计时值仅用于本机锚点，网络只提交测得的经过时长、时间标注和随机会话ID。

本机独立 schema 1 文件，原子写入与作用域代次保护，容量4MiB，最多20条未结清记录/100笔待同步操作。开始/继续预留收尾容量。退出或更换服务地址需明确处理本机未同步记录；清理本机不等于取消已发往服务器的操作，已同步历史仍在服务器。

服务端每条记录最多2000个片段，非终结修订最多500次；账号记录上限10000，操作上限100000。达到容量仍保留结束、删除、查询原回执的路径。删除区间正文后仅保留UUID/归属/内容摘要防复用，不保留原计时正文。

## 代码与接口

- `agent-service/src/campusflow_agent/focus_service.py`：SQLite事务、活动记录唯一约束、CAS、回执、墓碑、稳定列表快照。
- `arkui-x-client/entry/src/main/ets/utils/FocusController.ets`、`FocusStore.ets`、`FocusTimer.ets`：本机计时、持久队列与结果核验。
- `FocusPage.ets` 与 `Index.ets`：同账号唯一控制器、具体任务入口、记录与任务完成分开反馈。
- `PlatformFocusClock.ets` 与现有原生桥：隔离三端时钟能力，不可用时不以系统日期模拟单调时钟。
- 鉴权接口：`POST /api/v1/focus-records/{id}/operations`；`GET /api/v1/focus-operations/{id}`；`GET /api/v1/focus-records/active`；`GET /api/v1/focus-records/{id}`；`GET /api/v1/focus-records`。

只读平台时钟分别使用 [OpenHarmony getUptime](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-basic-services-kit/js-apis-date-time.md)、[Android elapsedRealtime](https://developer.android.com/reference/android/os/SystemClock)、[Apple systemUptime](https://developer.apple.com/documentation/foundation/processinfo/systemuptime)。Apple秒值转换为毫秒，补入35F9.1计时用途声明；只同步事件间的经过时长，原始uptime不离开设备。[Apple用途说明](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)

## 验证范围

最终数量与具体记录见 `docs/evidence/ux-09-checks.json`。后端真实SQLite/ASGI检查、客户端实际纯逻辑与页面方法检查、浏览器合成演示、源代码和资源配置检查分列。

本轮不安装原生环境、不做三端编译或实机验收。平台时钟实际可用性、前后台生命周期、持久文件在设备上的行为、大字/键盘与三端视觉效果均留给已有设备环境验证。浏览器演示不是原生应用截图。
