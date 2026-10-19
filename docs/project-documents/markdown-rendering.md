# Agent 回复的 Markdown 显示

Agent 回复和 SQLite 历史继续保存原始文本。客户端在显示时解析 Markdown，实时回复和历史详情使用相同的渲染路径，无需迁移已有会话。

## 原生客户端

`ChatBubble.ets` 区分用户输入与助手回复：用户输入原样显示，助手回复由 `MarkdownMessage.ets` 渲染。历史列表的摘要仍采用简短纯文本。

首期支持：

- 段落、标题、有序和无序列表、缩进列表、引用、分隔线。
- 粗体、斜体、行内代码和围栏代码块。
- 管道表格、表头、列对齐、转义竖线与缺失单元格。
- 表格各行使用相同列宽，长单元格换行，宽表和长代码行在气泡内部横向滚动。

这是常见 Markdown 语法的原生实现，不是完整 CommonMark/GFM 引擎。链接、图片、HTML 及未支持的语法保留可读原文；不执行 HTML。异常表格、多余单元格和超过解析限制的内容回退为完整纯文本，避免丢失信息。

解析结果在消息内容变化时更新；代码块保留缩进、空行和原始符号，不再经过全局去符号处理。

### 验证

在 `arkui-x-client` 目录执行：

```powershell
node --test scripts/test-markdown-parser.mjs
node scripts/static-check.mjs
```

解析测试使用已有 DevEco Studio 自带的 TypeScript。若安装路径不同，先设置 `DEVECO_STUDIO_HOME`；路径发现失败时按测试脚本的提示配置 TypeScript 路径。

随后使用 DevEco Studio 构建并运行 `entry`。仅验证静态排版时，可打开 `entry/src/main/ets/components/MarkdownPreview.ets` 的 Previewer；该样例不加入产品路由，也不请求模型。

## Web 调试界面

`appendMessage()` 对助手回复调用同一个 Markdown 渲染入口，恢复历史时同样生效；用户输入保持原文。

Marked 与 DOMPurify 的固定版本文件随项目本地提供，页面无需从 CDN 下载。表格采用 HTML 表格与内部横向滚动容器，代码块保留原内容。模型回复中的原始 HTML 显示为文本，图片只显示说明文字，链接只允许 HTTP、HTTPS 和 mailto；生成的 HTML 经过净化后插入。

第三方版本、来源和许可证见 `agent-service/src/campusflow_agent/web/vendor/README.md`。

### 验证

Web 测试需要 Node.js `^22.22.2 || ^24.15.0 || >=26.0.0` 和 pnpm 11.19.0；这些依赖仅用于测试，不影响 Python 后端启动。

在仓库根目录执行：

```powershell
pnpm --dir agent-service/tests/web install --frozen-lockfile
pnpm --dir agent-service/tests/web test
```

开发排版样例位于 `agent-service/tests/web/preview.html`，使用本地 HTTP 服务打开。样例覆盖普通表格、多列宽表、长单元格、代码和危险 HTML，不调用真实模型。更多操作见该目录的 `README.md`。

## 验收重点

1. 表格表头与各行单元格对齐，宽表可左右滑动，页面本身不被横向撑开。
2. 代码中的 `#`、`**`、竖线、缩进与空行完整保留。
3. 用户输入原样显示，新回复与历史详情的格式一致。
4. 不完整或不支持的语法仍可阅读；HTML 和图片不会触发脚本或外部图片请求。
5. 鸿蒙 HAP 构建与实际排版分别验证；Android/iOS 未实际运行时，不将其记录为已验收。
