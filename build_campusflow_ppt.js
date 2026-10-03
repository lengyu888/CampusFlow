const pptxgen = require('pptxgenjs');

const pptx = new pptxgen();
pptx.layout = 'LAYOUT_WIDE';
pptx.author = 'CampusFlow Team';
pptx.company = 'CampusFlow';
pptx.subject = '华为跨端 AI Agent 项目开发分析';
pptx.title = 'CampusFlow 跨端 AI Agent 项目开发分析';
pptx.lang = 'zh-CN';
pptx.theme = {
  headFontFace: 'Microsoft YaHei', bodyFontFace: 'Microsoft YaHei', lang: 'zh-CN'
};
pptx.defineLayout({ name: 'WIDE', width: 13.333, height: 7.5 });
pptx.layout = 'WIDE';
pptx.margin = 0;
pptx.layout = 'LAYOUT_WIDE';

const C = {
  navy: '0C1426', ink: '17243A', slate: '53627A', muted: '8490A3',
  fog: 'F5F7FB', white: 'FFFFFF', red: 'D81E3A', coral: 'FF6B6B',
  teal: '00A3A3', sky: 'E8F4F6', blue: '2E69D8', line: 'DCE3EE',
  green: '25A96A', amber: 'F3A83B', purple: '7457D9'
};
const S = pptx.ShapeType;
const W = 13.333, H = 7.5;

function rect(slide, x, y, w, h, fill, line = fill, radius = false, transparency = 0) {
  slide.addShape(radius ? S.roundRect : S.rect, {
    x, y, w, h, rectRadius: radius ? 0.08 : undefined,
    fill: { color: fill, transparency }, line: { color: line, transparency: line === fill ? 100 : 0, width: 0.6 }
  });
}
function text(slide, value, x, y, w, h, opt = {}) {
  const style = {
    x, y, w, h, fontFace: 'Microsoft YaHei', fontSize: 14, color: C.ink,
    margin: 0, breakLine: false, valign: 'mid', fit: 'shrink',
    paraSpaceAfterPt: 0, ...opt
  };
  slide.addText(value, style);
}
function line(slide, x1, y1, x2, y2, color = C.line, width = 1, dash = 'solid') {
  slide.addShape(S.line, { x: x1, y: y1, w: x2 - x1, h: y2 - y1, line: { color, width, dashType: dash } });
}
function circle(slide, x, y, d, fill, label, color = C.white, fs = 12) {
  slide.addShape(S.ellipse, { x, y, w: d, h: d, fill: { color: fill }, line: { color: fill, transparency: 100 } });
  if (label) text(slide, label, x, y + 0.01, d, d - 0.02, { fontSize: fs, color, bold: true, align: 'center', valign: 'mid' });
}
function header(slide, section, title, subtitle = '', dark = false) {
  const fg = dark ? C.white : C.ink;
  text(slide, section.toUpperCase(), 0.55, 0.35, 3.5, 0.2, { fontSize: 8.5, bold: true, color: dark ? 'F18A9B' : C.red, charSpacing: 1.7 });
  text(slide, title, 0.55, 0.62, 12.0, 0.48, { fontSize: 27, bold: true, color: fg });
  if (subtitle) text(slide, subtitle, 0.55, 1.16, 11.9, 0.28, { fontSize: 10.5, color: dark ? 'BFC9D8' : C.slate });
  if (!dark) circle(slide, 12.35, 0.43, 0.42, C.red, section.match(/\d+/)?.[0] || '', C.white, 9);
}
function footer(slide, page, dark = false) {
  const c = dark ? '91A0B7' : '8390A2';
  text(slide, 'CampusFlow · 华为跨端 AI Agent 参赛方案', 0.55, 7.1, 5.8, 0.18, { fontSize: 7.5, color: c });
  text(slide, String(page).padStart(2, '0'), 12.35, 7.08, 0.42, 0.18, { fontSize: 8, color: c, align: 'right' });
}
function tag(slide, t, x, y, w, fill, color = C.ink) {
  rect(slide, x, y, w, 0.28, fill, fill, true);
  text(slide, t, x + 0.1, y + 0.02, w - 0.2, 0.22, { fontSize: 8.5, bold: true, color, align: 'center' });
}
function card(slide, { x, y, w, h, title, body, n, accent = C.red, dark = false }) {
  rect(slide, x, y, w, h, dark ? '16233A' : C.white, dark ? '26344C' : C.line, true);
  if (n) circle(slide, x + 0.18, y + 0.18, 0.36, accent, n, C.white, 9);
  text(slide, title, x + (n ? 0.65 : 0.22), y + 0.18, w - (n ? 0.86 : 0.44), 0.28, { fontSize: 13.2, bold: true, color: dark ? C.white : C.ink });
  text(slide, body, x + 0.22, y + 0.62, w - 0.44, h - 0.76, { fontSize: 9.6, color: dark ? 'C3CDDB' : C.slate, breakLine: false, valign: 'top', paraSpaceAfterPt: 6, fit: 'shrink' });
}
function arrow(slide, x1, y1, x2, y2, color = C.red) {
  line(slide, x1, y1, x2, y2, color, 1.8);
  slide.addShape(S.chevron, { x: x2 - 0.14, y: y2 - 0.11, w: 0.22, h: 0.22, rotate: 0, fill: { color }, line: { color, transparency: 100 } });
}

// 01 Cover
{
  const s = pptx.addSlide(); s.background = { color: C.navy };
  // visual motif: layered agent execution tracks
  for (let i = 0; i < 7; i++) {
    const x = 7.55 + i * 0.53;
    s.addShape(S.arc, { x, y: 1.0 + (i % 2) * 0.22, w: 3.5 - i * 0.15, h: 3.5 - i * 0.15,
      adjustPoint: 0.22, line: { color: i % 3 === 0 ? C.red : '334663', transparency: i % 3 === 0 ? 15 : 20, width: 1.2 }, fill: { color: C.navy, transparency: 100 } });
  }
  circle(s, 9.85, 2.48, 1.08, C.red, 'AI', C.white, 25);
  circle(s, 8.2, 4.55, 0.52, C.teal, '', C.white);
  circle(s, 11.8, 4.18, 0.34, C.amber, '', C.white);
  text(s, '华为 · 跨端 AI AGENT 项目', 0.7, 0.7, 5.6, 0.25, { fontSize: 10, bold: true, color: 'F18A9B', charSpacing: 1.7 });
  text(s, 'CampusFlow', 0.7, 1.55, 6.2, 0.78, { fontSize: 44, bold: true, color: C.white });
  text(s, '校园生活规划 Agent\n一套代码，三端随行', 0.7, 2.42, 5.9, 1.0, { fontSize: 24, bold: true, color: 'D8E2F0', breakLine: false, valign: 'top' });
  text(s, '项目开发分析 · 技术路线 · 创新与交付方案', 0.72, 3.75, 5.5, 0.28, { fontSize: 12, color: 'AAB8CC' });
  tag(s, 'ArkUI-X', 0.72, 5.62, 1.25, '243653', 'D8E2F0');
  tag(s, 'Agent + Tools', 2.12, 5.62, 1.62, '243653', 'D8E2F0');
  tag(s, 'HarmonyOS / Android / iOS', 3.9, 5.62, 2.6, '243653', 'D8E2F0');
  text(s, '面向高校学生 · 2026', 0.72, 6.47, 3.6, 0.22, { fontSize: 9.5, color: '8EA0B9' });
  footer(s, 1, true);
}

// 02 Requirement mapping
{
  const s = pptx.addSlide(); s.background = { color: C.fog }; header(s, '01', '从竞赛约束倒推最小可验收产品', '每一项要求都对应可演示、可测试、可交付的工程证据');
  const rows = [
    ['跨端交付', 'ArkUI-X 一套 ArkTS 业务代码', 'HarmonyOS / Android / iOS 安装包与运行录屏'],
    ['Agent 能力', '多轮任务推进 + 4 类工具调用', '任务状态、工具调用卡片、执行日志'],
    ['云端模型', '可切换模型适配层', '真实流式对话与降级提示'],
    ['语音闭环', '鸿蒙：ASR → Agent → TTS', '语音输入、转写、播报的完整演示'],
    ['本地持久化', '会话、偏好、任务快照', '三端可回看、可续办、可清除']
  ];
  const xs = [0.68, 2.73, 6.52, 10.03], ws = [2.05, 3.79, 3.51, 2.64];
  ['竞赛要求', '设计决策', '可验证证据'].forEach((t, i) => { rect(s, xs[i], 1.75, ws[i], 0.44, i === 0 ? C.navy : 'E8ECF3'); text(s, t, xs[i] + 0.16, 1.85, ws[i] - 0.3, 0.18, { fontSize: 10.5, bold: true, color: i === 0 ? C.white : C.ink }); });
  rows.forEach((r, idx) => {
    const y = 2.2 + idx * 0.75; const fill = idx % 2 === 0 ? C.white : 'FAFBFD';
    rect(s, 0.68, y, 11.99, 0.75, fill, C.line);
    rect(s, 0.68, y, 0.07, 0.75, [C.red, C.teal, C.blue, C.amber, C.green][idx]);
    text(s, r[0], 0.92, y + 0.16, 1.5, 0.23, { fontSize: 12.2, bold: true });
    text(s, r[1], 2.9, y + 0.13, 3.25, 0.34, { fontSize: 10.8, color: C.slate });
    text(s, r[2], 6.7, y + 0.13, 5.6, 0.34, { fontSize: 10.8, color: C.slate });
    circle(s, 12.12, y + 0.21, 0.25, C.green, '✓', C.white, 9);
  });
  text(s, '验收策略：先完成“能跑通”的跨端闭环，再把体验、记忆、RAG 和端侧能力做成可独立展示的加分模块。', 0.72, 6.2, 11.9, 0.32, { fontSize: 11.5, color: C.ink, bold: true });
  footer(s, 2);
}

// 03 Problem & positioning
{
  const s = pptx.addSlide(); s.background = { color: C.white }; header(s, '02', '命题选择：从“问一句答一句”升级为“替我把事办下去”', '聚焦学生高频但碎片化的课程、活动、办事与时间管理场景');
  card(s, { x: 0.7, y: 1.9, w: 2.65, h: 3.7, title: '学生痛点', n: '01', accent: C.red, body: '日程、DDL、活动与办事入口分散\n\n信息会看，但难以形成可执行计划\n\n临时冲突发生时，不知道先改什么' });
  card(s, { x: 3.58, y: 1.9, w: 2.65, h: 3.7, title: '产品定位', n: '02', accent: C.teal, body: '校园生活“任务中枢”\n\n理解自然语言目标，分解、查询、提醒并协助确认\n\n不是知识问答，而是可追踪的任务协作' });
  card(s, { x: 6.46, y: 1.9, w: 2.65, h: 3.7, title: '首个 MVP', n: '03', accent: C.blue, body: '“明天下午有空吗？帮我安排完成实验报告，并提醒我预约图书馆。”\n\n输出：计划 + 冲突检查 + 工具执行 + 待确认事项' });
  rect(s, 9.46, 1.9, 3.15, 3.7, C.navy, C.navy, true);
  text(s, '核心价值', 9.75, 2.25, 2.5, 0.35, { fontSize: 13, bold: true, color: C.white });
  text(s, '一句话目标\n→ 一份可执行任务流\n\n“我已经替你查好、排好，关键动作等你确认。”', 9.75, 2.87, 2.3, 1.7, { fontSize: 16, bold: true, color: 'DDE7F5', valign: 'top' });
  tag(s, '高频', 9.75, 4.9, 0.6, '263B5D', 'DDE7F5'); tag(s, '可展示', 10.5, 4.9, 0.78, '263B5D', 'DDE7F5'); tag(s, '可扩展', 11.42, 4.9, 0.78, '263B5D', 'DDE7F5');
  footer(s, 3);
}

// 04 User journey
{
  const s = pptx.addSlide(); s.background = { color: C.fog }; header(s, '03', '演示主线：一个请求，跑出 Agent 的完整“思考—行动—反馈”', '用用户可感知的过程代替黑盒回答，突出工具调用与多轮推进');
  const steps = [
    ['01', '表达目标', '“明天帮我安排\n完成实验报告”', C.red],
    ['02', '澄清约束', '追问截止时间、\n可用时段', C.purple],
    ['03', '调用工具', '查询日历 / 场地\n/ 截止事项', C.teal],
    ['04', '生成计划', '拆分任务、避开冲突\n给出候选方案', C.blue],
    ['05', '确认执行', '写入日程、设置提醒\n保留可撤销入口', C.green]
  ];
  steps.forEach((it, i) => {
    const x = 0.62 + i * 2.53;
    rect(s, x, 2.15, 2.1, 2.7, C.white, C.line, true);
    circle(s, x + 0.18, 2.36, 0.46, it[3], it[0], C.white, 9);
    text(s, it[1], x + 0.2, 3.06, 1.7, 0.25, { fontSize: 13, bold: true });
    text(s, it[2], x + 0.2, 3.54, 1.7, 0.62, { fontSize: 10.6, color: C.slate, valign: 'top' });
    if (i < steps.length - 1) arrow(s, x + 2.13, 3.5, x + 2.43, 3.5, 'A4B3C8');
  });
  rect(s, 0.73, 5.53, 11.87, 0.73, 'E9F3F7', 'CDE5E8', true);
  circle(s, 0.96, 5.73, 0.3, C.teal, 'i', C.white, 9);
  text(s, '可观测设计：每轮显示“正在查询 / 已找到冲突 / 等待确认”，工具调用失败时给出重试或人工接管选项。', 1.42, 5.75, 10.75, 0.2, { fontSize: 11.2, bold: true, color: C.ink });
  footer(s, 4);
}

// 05 Functions
{
  const s = pptx.addSlide(); s.background = { color: C.white }; header(s, '04', '功能蓝图：先用 4 个工具形成闭环，再按场景增量扩展', 'MVP 的边界明确，功能均可映射到演示、测试与数据模型');
  const features = [
    ['对话与任务', '流式多轮对话\n任务状态机 / 待确认清单', C.red],
    ['日程查询', '空闲时段 / 冲突检测\n本地日历与课程表', C.teal],
    ['计划生成', '任务拆解 / 时长估算\n优先级与备选方案', C.blue],
    ['提醒执行', '创建提醒 / 任务卡片\n可撤销、可续办', C.amber],
    ['记忆与回看', '会话历史 / 偏好摘要\n本地持久化与检索', C.purple],
    ['语音交互', 'HarmonyOS ASR → Agent → TTS\nAndroid/iOS 作为扩展', C.green]
  ];
  features.forEach((f, i) => {
    const col = i % 3, row = Math.floor(i / 3), x = 0.72 + col * 4.13, y = 1.86 + row * 2.2;
    rect(s, x, y, 3.72, 1.72, 'FAFBFE', C.line, true);
    circle(s, x + 0.25, y + 0.27, 0.45, f[2], String(i + 1).padStart(2, '0'), C.white, 8);
    text(s, f[0], x + 0.86, y + 0.27, 2.45, 0.26, { fontSize: 14, bold: true });
    text(s, f[1], x + 0.28, y + 0.84, 3.0, 0.5, { fontSize: 10.4, color: C.slate, valign: 'top' });
  });
  footer(s, 5);
}

// 06 Architecture
{
  const s = pptx.addSlide(); s.background = { color: C.fog }; header(s, '05', '一页架构：端侧体验统一，云端 Agent 可演进，数据边界清晰', '“跨端 UI + 平台适配 + Agent 编排 + 工具与模型”四层分离，降低换端与换模型成本');
  const layers = [
    { y: 1.75, label: '体验层', color: C.red, blocks: ['ArkUI-X UI\n对话 / 任务卡', 'HarmonyOS\n语音入口', 'Android / iOS\n文本与通知'] },
    { y: 2.85, label: '跨端服务层', color: C.teal, blocks: ['共享 ArkTS\n状态与业务逻辑', 'Platform Bridge\n语音 / 通知 / 存储'] },
    { y: 4.1, label: 'Agent 编排层', color: C.blue, blocks: ['Session & Memory\n会话 / 偏好摘要', 'Planner\n澄清 / 拆解 / 路由', 'Tool Executor\n鉴权 / 重试 / 审计'] },
    { y: 5.35, label: '云端与数据层', color: C.purple, blocks: ['LLM Adapter\n云端模型可切换', 'Tools\n日历 / 待办 / RAG', 'Data\nKV Store / 加密缓存'] }
  ];
  layers.forEach((l) => {
    rect(s, 0.7, l.y, 1.28, 0.78, l.color, l.color, true);
    text(s, l.label, 0.86, l.y + 0.24, 0.95, 0.25, { fontSize: 11.5, bold: true, color: C.white, align: 'center' });
    l.blocks.forEach((b, i) => {
      const x = 2.22 + i * 3.46;
      rect(s, x, l.y, 3.08, 0.78, C.white, C.line, true);
      text(s, b, x + 0.16, l.y + 0.13, 2.75, 0.45, { fontSize: 10.3, bold: i === 1 && l.y > 4 ? true : false, color: C.ink, align: 'center' });
    });
  });
  line(s, 2.22, 2.58, 11.95, 2.58, C.teal, 1.1, 'dash');
  text(s, '端侧统一代码边界', 10.8, 2.43, 1.3, 0.15, { fontSize: 7.7, bold: true, color: C.teal, align: 'right' });
  footer(s, 6);
}

// 07 Agent design
{
  const s = pptx.addSlide(); s.background = { color: C.white }; header(s, '06', 'Agent 设计：以状态机约束大模型，以工具协议保证可执行', '模型负责理解与规划，系统负责校验、权限、执行和可恢复性');
  const nodes = [
    ['输入理解', 1.15, 2.7, C.red], ['信息足够？', 3.2, 2.7, C.purple], ['规划 / 选工具', 5.5, 2.7, C.blue], ['执行与校验', 7.9, 2.7, C.teal], ['答复 / 待确认', 10.28, 2.7, C.green]
  ];
  nodes.forEach((n, i) => { circle(s, n[1], n[2], 1.22, n[3], '', C.white); text(s, n[0], n[1] + 0.08, n[2] + 0.33, 1.06, 0.45, { fontSize: 11, bold: true, color: C.white, align: 'center' }); if (i < nodes.length - 1) arrow(s, n[1] + 1.28, n[2] + 0.61, nodes[i + 1][1] - 0.1, n[2] + 0.61, 'A6B4C6'); });
  line(s, 4.1, 3.91, 4.1, 4.55, C.purple, 1.2); line(s, 4.1, 4.55, 1.76, 4.55, C.purple, 1.2); arrow(s, 1.76, 4.55, 1.76, 4.0, C.purple);
  text(s, '缺少时间 / 偏好 → 多轮澄清', 1.0, 4.72, 3.1, 0.25, { fontSize: 9.4, color: C.purple, bold: true, align: 'center' });
  const boxes = [
    ['Tool Schema', 'JSON 参数校验\n白名单工具与参数', C.red],
    ['Policy Guard', '高风险写操作\n必须显式确认', C.amber],
    ['Trace', '记录计划、调用、错误\n便于复盘与答辩', C.teal]
  ];
  boxes.forEach((b, i) => card(s, { x: 1.0 + i * 4.05, y: 5.32, w: 3.55, h: 1.18, title: b[0], body: b[1], accent: b[2] }));
  footer(s, 7);
}

// 08 Cross platform
{
  const s = pptx.addSlide(); s.background = { color: C.fog }; header(s, '07', '跨端工程路线：目标共享 ≥80% 业务代码，原生能力通过桥接按需增强', '以统一接口隔离平台差异；三端都能交付，鸿蒙端把语音链路做深');
  const columns = [
    ['Shared Core', 'ArkUI-X / ArkTS\nUI、状态管理、对话、任务、网络、模型适配', C.navy],
    ['HarmonyOS', 'ASR、TTS、通知、KV 存储\n重点演示：语音任务推进', C.red],
    ['Android', '安装包、文本对话、本地会话\n可选：语音与推送', C.green],
    ['iOS', '安装包、文本对话、本地会话\n可选：语音与推送', C.blue]
  ];
  columns.forEach((c, i) => {
    const x = 0.66 + i * 3.15;
    rect(s, x, 1.85, 2.72, 3.8, c[2], c[2], true);
    circle(s, x + 0.28, 2.15, 0.47, i === 0 ? C.red : C.white, String(i + 1).padStart(2, '0'), i === 0 ? C.white : c[2], 9);
    text(s, c[0], x + 0.28, 2.88, 2.05, 0.32, { fontSize: 16, bold: true, color: C.white });
    text(s, c[1], x + 0.28, 3.62, 2.08, 1.08, { fontSize: 11, color: 'E6EDF7', valign: 'top' });
    tag(s, i === 0 ? '共享层' : '平台实现', x + 0.28, 5.05, 0.92, i === 0 ? '263B5D' : C.white, i === 0 ? C.white : c[2]);
  });
  text(s, '工程约定：domain 不依赖平台 API；platform 只暴露 VoiceService、StorageService、NotificationService 三组能力；每组提供 mock 以支撑三端测试。', 0.75, 6.25, 11.8, 0.32, { fontSize: 10.8, color: C.ink, bold: true });
  footer(s, 8);
}

// 09 Data security
{
  const s = pptx.addSlide(); s.background = { color: C.white }; header(s, '08', '记忆与隐私：最小化存储、可解释调用、用户可控清除', '把“能记住”做成可控能力，而不是不可见的数据积累');
  const left = [
    ['会话历史', '本地 KV Store；按会话分区；可回看与删除'],
    ['偏好摘要', '仅保留用户确认的偏好；不上传原始敏感内容'],
    ['任务快照', '保存计划状态与工具结果；支持中断后继续办理']
  ];
  left.forEach((l, i) => {
    const y = 1.86 + i * 1.15; circle(s, 0.82, y + 0.05, 0.42, [C.red, C.teal, C.blue][i], String(i + 1), C.white, 9);
    text(s, l[0], 1.45, y, 1.55, 0.23, { fontSize: 13, bold: true }); text(s, l[1], 1.45, y + 0.36, 4.7, 0.38, { fontSize: 10.4, color: C.slate });
  });
  rect(s, 7.12, 1.75, 5.42, 3.75, C.navy, C.navy, true);
  text(s, '调用安全闸门', 7.5, 2.08, 2.3, 0.28, { fontSize: 16, bold: true, color: C.white });
  const gates = [
    ['01', '工具白名单', '仅允许日历、待办、知识检索等已注册工具'],
    ['02', '参数校验', '时间、任务内容、权限范围先校验再执行'],
    ['03', '显式确认', '创建日程、外部写入等操作需用户确认'],
    ['04', '调用审计', '记录请求、结果、错误码，答辩可追溯']
  ];
  gates.forEach((g, i) => { const y = 2.68 + i * 0.57; circle(s, 7.5, y, 0.27, C.red, g[0], C.white, 7); text(s, g[1], 7.93, y - 0.01, 1.0, 0.18, { fontSize: 10.3, bold: true, color: 'EDF2FB' }); text(s, g[2], 9.05, y - 0.01, 2.95, 0.19, { fontSize: 9.1, color: 'B7C4D6' }); });
  rect(s, 0.75, 5.92, 11.82, 0.48, 'FFF3E7', 'F7D4AB', true); text(s, '设计原则：模型看见的是完成任务所需的最少上下文；用户对“记住什么、执行什么、保留多久”拥有可见控制权。', 0.98, 6.07, 11.25, 0.18, { fontSize: 10.5, bold: true, color: '945B17', align: 'center' });
  footer(s, 9);
}

// 10 Innovations
{
  const s = pptx.addSlide(); s.background = { color: C.navy }; header(s, '09', '创新点：把竞赛加分项嵌入主链路，而不是附加装饰', '可在答辩中用“问题—设计—可见效果”逐项说明价值', true);
  const innovations = [
    ['01', '任务可视化推演', '将 Agent 的澄清、计划、调用与确认转换为任务卡与状态轨迹，用户随时知道系统在做什么。', C.red],
    ['02', '模型适配层', '统一 Chat / Stream / ToolCall 协议；可快速切换云端模型，避免业务逻辑绑定单一厂商。', C.teal],
    ['03', '轻量记忆 + RAG', '会话摘要保存长期偏好；校园 FAQ 建立可检索知识包，回答附带来源类别。', C.blue],
    ['04', '确认式执行安全', '把“建议”和“写入动作”隔离；高影响操作前以卡片呈现参数，支持取消与回滚。', C.amber]
  ];
  innovations.forEach((it, i) => {
    const x = 0.7 + (i % 2) * 6.1, y = 1.8 + Math.floor(i / 2) * 2.28;
    rect(s, x, y, 5.72, 1.82, '16233A', '31415D', true);
    circle(s, x + 0.28, y + 0.28, 0.52, it[3], it[0], C.white, 9);
    text(s, it[1], x + 1.02, y + 0.28, 4.2, 0.27, { fontSize: 14.5, bold: true, color: C.white });
    text(s, it[2], x + 0.3, y + 0.92, 5.0, 0.52, { fontSize: 10.3, color: 'C5D0DF', valign: 'top' });
  });
  text(s, '加分策略优先级：交互体验（必投入） → 语音闭环（鸿蒙必做） → 记忆/RAG → Android/iOS 语音 → 端侧能力深化。', 0.75, 6.6, 11.6, 0.22, { fontSize: 10.5, color: 'BFCBDB', align: 'center' });
  footer(s, 10, true);
}

// 11 Roadmap
{
  const s = pptx.addSlide(); s.background = { color: C.fog }; header(s, '10', '16 周开发节奏：以跨端闭环为里程碑，避免最后才集成', '每两周产出一个可演示版本；需求、代码、测试、视频同步沉淀');
  const phases = [
    ['W1–2', '定义与原型', '场景、用户旅程、UI 线框\n模型与工具协议 POC', C.red],
    ['W3–5', '跨端骨架', 'ArkUI-X 三端跑通\n对话、会话存储、模型接入', C.teal],
    ['W6–8', 'Agent MVP', '澄清、多轮状态机\n日历 / 待办 / 提醒工具', C.blue],
    ['W9–11', '鸿蒙深化', 'ASR → Agent → TTS\n动效、任务轨迹、异常恢复', C.purple],
    ['W12–14', '加分模块', '记忆 / RAG、模型适配\nAndroid/iOS 语音可选', C.amber],
    ['W15–16', '验收与答辩', '三端回归、录屏、文档\n架构图、演示脚本、PPT', C.green]
  ];
  line(s, 1.05, 3.48, 12.15, 3.48, 'B9C6D6', 2);
  phases.forEach((p, i) => {
    const x = 0.82 + i * 2.05; circle(s, x + 0.55, 3.14, 0.68, p[3], String(i + 1), C.white, 12);
    rect(s, x, i % 2 === 0 ? 1.62 : 4.05, 1.78, 1.15, C.white, C.line, true);
    text(s, p[0], x + 0.14, (i % 2 === 0 ? 1.78 : 4.2), 1.45, 0.2, { fontSize: 10, color: p[3], bold: true, align: 'center' });
    text(s, p[1], x + 0.14, (i % 2 === 0 ? 2.07 : 4.49), 1.45, 0.2, { fontSize: 11.6, bold: true, align: 'center' });
    text(s, p[2], x + 0.14, (i % 2 === 0 ? 2.38 : 4.8), 1.46, 0.32, { fontSize: 8.2, color: C.slate, align: 'center', valign: 'top' });
  });
  text(s, '关键 Gate：W5 三端可安装 · W8 可演示工具调用 · W11 鸿蒙语音闭环 · W14 加分项冻结 · W16 交付物齐套', 0.78, 6.45, 11.7, 0.2, { fontSize: 10.4, bold: true, color: C.ink, align: 'center' });
  footer(s, 11);
}

// 12 Test and acceptance
{
  const s = pptx.addSlide(); s.background = { color: C.white }; header(s, '11', '验收与测试：把“能演示”转化为可复现的验证清单', '三端真机回归 + Agent 工具回归 + 异常路径演练，避免只在开发机上成立');
  const sections = [
    ['跨端真机', ['三端安装、启动、登录', '三端多轮文本对话', '会话退出后可回看'], C.red],
    ['Agent 正确性', ['多轮澄清满足约束', '工具参数与结果可见', '失败重试与人工接管'], C.teal],
    ['语音与体验', ['鸿蒙 ASR / TTS 全链路', '流式状态与加载反馈', '关键操作二次确认'], C.blue]
  ];
  sections.forEach((sec, i) => {
    const x = 0.72 + i * 4.17;
    rect(s, x, 1.85, 3.72, 3.9, 'FAFBFE', C.line, true);
    rect(s, x, 1.85, 3.72, 0.65, sec[2], sec[2], true);
    text(s, sec[0], x + 0.25, 2.06, 2.4, 0.22, { fontSize: 15, bold: true, color: C.white });
    sec[1].forEach((it, j) => { circle(s, x + 0.28, 2.86 + j * 0.74, 0.28, 'E6EDF7', '✓', sec[2], 9); text(s, it, x + 0.72, 2.88 + j * 0.74, 2.55, 0.2, { fontSize: 10.8, color: C.ink }); });
  });
  rect(s, 0.75, 6.1, 11.85, 0.45, C.navy, C.navy, true); text(s, '演示口径：同一任务在三端均完成文本闭环；鸿蒙端额外展示“语音输入—澄清—工具执行—语音播报”；全程保留任务轨迹。', 0.98, 6.23, 11.3, 0.17, { fontSize: 10.1, color: C.white, align: 'center' });
  footer(s, 12);
}

// 13 Delivery
{
  const s = pptx.addSlide(); s.background = { color: C.fog }; header(s, '12', '工程交付包：让评委既能看懂，也能按文档复现', '交付物按“代码—安装—架构—演示—测试”闭环组织，工程信息透明');
  const items = [
    ['01', '源代码仓库', 'apps / shared / platform / docs\n清晰的模块边界与 README', C.red],
    ['02', '三端安装包', 'HarmonyOS、Android、iOS\n版本号、设备要求、安装说明', C.teal],
    ['03', '一页架构图', '跨端层、Agent 层、工具层\n数据流、权限流、异常流', C.blue],
    ['04', '演示材料', '3–5 分钟录屏、答辩 PPT\n脚本、任务案例与截图', C.purple],
    ['05', '测试证据', '真机清单、用例、日志摘要\n关键异常与处理说明', C.amber]
  ];
  items.forEach((it, i) => {
    const y = 1.7 + i * 0.92;
    rect(s, 0.75, y, 11.85, 0.7, C.white, C.line, true);
    circle(s, 0.98, y + 0.17, 0.36, it[3], it[0], C.white, 8);
    text(s, it[1], 1.63, y + 0.18, 1.85, 0.22, { fontSize: 12.2, bold: true });
    text(s, it[2], 3.5, y + 0.12, 7.6, 0.34, { fontSize: 10.1, color: C.slate, valign: 'top' });
    tag(s, i === 0 ? '必交' : i === 4 ? '加分保障' : '验收证据', 11.18, y + 0.2, 0.9, i === 0 ? 'FCE7EC' : 'EAF0F7', i === 0 ? C.red : C.slate);
  });
  footer(s, 13);
}

// 14 Risks
{
  const s = pptx.addSlide(); s.background = { color: C.white }; header(s, '13', '关键风险：提前做“可替换、可降级、可解释”的工程设计', '风险不回避，而是通过边界清晰的架构与演示预案把影响收敛');
  const risks = [
    ['跨端构建差异', 'W3 前先跑 Hello、网络、存储三项 POC；平台能力通过接口隔离。', C.red],
    ['模型网络不稳定', '流式超时、重试、错误态与备用模型；录屏准备可复现实例。', C.teal],
    ['工具调用不可靠', '参数 Schema 校验、幂等设计、失败说明与人工确认入口。', C.blue],
    ['语音链路延迟', '分段展示 ASR / 思考 / TTS 状态；文本输入始终作为保底路径。', C.purple],
    ['功能范围膨胀', 'MVP 工具锁定 4 个；加分模块独立开关，不影响主链路验收。', C.amber]
  ];
  risks.forEach((r, i) => {
    const y = 1.75 + i * 0.94;
    rect(s, 0.78, y, 2.6, 0.62, r[2], r[2], true); text(s, r[0], 1.02, y + 0.19, 2.1, 0.2, { fontSize: 11.8, bold: true, color: C.white, align: 'center' });
    rect(s, 3.55, y, 8.98, 0.62, 'F8FAFD', C.line, true); text(s, r[1], 3.85, y + 0.18, 8.35, 0.2, { fontSize: 10.7, color: C.ink });
  });
  rect(s, 0.78, 6.45, 11.75, 0.31, 'EDF5F4', 'D3EAE6', true); text(s, '控制原则：任何加分能力失败，都不应阻断“三端文本 + 鸿蒙语音 + 工具调用 + 本地会话”的主验收闭环。', 1.03, 6.52, 11.25, 0.15, { fontSize: 9.8, bold: true, color: '176B61', align: 'center' });
  footer(s, 14);
}

// 15 Closing
{
  const s = pptx.addSlide(); s.background = { color: C.navy };
  circle(s, 8.82, 1.1, 3.12, '162B49', '', C.white);
  circle(s, 9.6, 1.88, 1.56, C.red, 'AI', C.white, 34);
  line(s, 8.08, 4.98, 11.88, 4.98, '344869', 1.5);
  ['跨端', '可执行', '可验证'].forEach((t, i) => { circle(s, 8.2 + i * 1.47, 5.45, 0.58, [C.teal, C.red, C.amber][i], String(i + 1), C.white, 10); text(s, t, 8.0 + i * 1.47, 6.18, 1.0, 0.21, { fontSize: 10, color: 'D5E0EE', align: 'center', bold: true }); });
  text(s, 'CampusFlow', 0.75, 1.28, 5.7, 0.55, { fontSize: 34, color: C.white, bold: true });
  text(s, '用一套代码，交付三端可运行的\n校园任务协作 Agent', 0.75, 2.18, 5.8, 0.92, { fontSize: 22, color: 'D9E3F1', bold: true, valign: 'top' });
  text(s, '最短路径：先把主验收闭环跑稳，再把体验、语音、记忆与 RAG 做成看得见的创新。', 0.75, 3.68, 5.65, 0.42, { fontSize: 12, color: 'AEBFD4', valign: 'top' });
  tag(s, '跨端', 0.78, 5.25, 0.7, '263B5D', 'D9E3F1'); tag(s, '工具调用', 1.62, 5.25, 1.0, '263B5D', 'D9E3F1'); tag(s, '鸿蒙语音', 2.76, 5.25, 1.0, '263B5D', 'D9E3F1'); tag(s, '工程交付', 3.9, 5.25, 1.0, '263B5D', 'D9E3F1');
  text(s, '谢谢', 0.78, 6.48, 1.2, 0.25, { fontSize: 13, color: 'F18A9B', bold: true });
  footer(s, 15, true);
}

pptx.writeFile({ fileName: 'CampusFlow_跨端AI_Agent项目开发分析.pptx' });
