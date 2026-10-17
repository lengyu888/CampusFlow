export interface QuickCaptureIssue {
  field: string;
  code: string;
  message: string;
}

export interface QuickCaptureCandidate {
  originalText: string;
  title: string;
  date: string;
  time: string;
  durationMinutes: number | null;
  anchorDate: string;
  timezone: string;
  issues: QuickCaptureIssue[];
  unsupported: string[];
  requiresReview: boolean;
}

interface CaptureSpan { start: number; end: number; value: string; }
interface CaptureUnsupportedRule { pattern: RegExp; label: string; }

export const QUICK_CAPTURE_SUPPORTED: string[] = [
  '今天、明天、后天及 YYYY-MM-DD 日期',
  '周几取从输入基准日起最近一次（含当天）；本周、下周按周一开始',
  '24 小时时刻，或上午/下午/晚上加几点、几点半',
  '明确分钟或小时（含半小时），最多 24 小时',
  '例如：明晚八点复习一小时；无日期的事项也可手动保存'
];

export const QUICK_CAPTURE_UNSUPPORTED: string[] = [
  '循环安排、节假日、下课后等相对事件',
  '下午、晚点、有空时等没有明确时刻的描述',
  '一句多项、多个竞争日期或时刻',
  '没有上午/晚上说明的一至十二点，或八九点等大概时间',
  '按课程、教室、通勤位置推算时间'
];

const DAY_MS: number = 86400000;

function validDate(value: string): boolean {
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)) { return false; }
  const year = Number(value.substring(0, 4));
  const month = Number(value.substring(5, 7));
  const day = Number(value.substring(8, 10));
  if (year < 1 || year > 9999 || month < 1 || month > 12 || day < 1) { return false; }
  const leap = year % 400 === 0 || (year % 4 === 0 && year % 100 !== 0);
  const lengths: number[] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= lengths[month - 1];
}

function dateAt(value: number): string {
  const date = new Date(value);
  return `${date.getUTCFullYear()}`.padStart(4, '0') + '-' +
    `${date.getUTCMonth() + 1}`.padStart(2, '0') + '-' + `${date.getUTCDate()}`.padStart(2, '0');
}

function shiftDate(anchor: string, days: number): string {
  const value = dateAt(Date.parse(`${anchor}T00:00:00Z`) + days * DAY_MS);
  return validDate(value) ? value : '';
}

function numberWord(value: string): number | null {
  if (/^[0-9]+(?:\.[0-9]+)?$/.test(value)) { return Number(value); }
  if (value === '半') { return 0.5; }
  const digits: string = '零一二三四五六七八九';
  const word = value.replace(/两/g, '二').replace(/〇/g, '零');
  if (word.length === 1 && digits.indexOf(word) >= 0) { return digits.indexOf(word); }
  const tens = /^([一二三四五六七八九]?)十([一二三四五六七八九]?)$/.exec(word);
  if (tens !== null) { return (tens[1].length === 0 ? 1 : digits.indexOf(tens[1])) * 10 + (tens[2].length === 0 ? 0 : digits.indexOf(tens[2])); }
  return null;
}

function issue(result: QuickCaptureCandidate, field: string, code: string, message: string): void {
  if (!result.issues.some((item: QuickCaptureIssue) => item.code === code)) {
    result.issues.push({ field: field, code: code, message: message });
  }
}

function matches(text: string, pattern: RegExp): CaptureSpan[] {
  const values: CaptureSpan[] = [];
  let found = pattern.exec(text);
  while (found !== null) {
    values.push({ start: found.index, end: found.index + found[0].length, value: found[0] });
    found = pattern.exec(text);
  }
  return values;
}

function dateValue(token: string, anchor: string): string {
  if (/^[0-9]/.test(token)) { return validDate(token) ? token : ''; }
  if (/^(明天|明晚|明早|明晨)$/.test(token)) { return shiftDate(anchor, 1); }
  if (token === '后天') { return shiftDate(anchor, 2); }
  if (/^(今天|今日|今晚|今早|今晨|今夜)$/.test(token)) { return anchor; }
  const weekday = '一二三四五六日'.indexOf(token.substring(token.length - 1).replace('天', '日'));
  const day = new Date(`${anchor}T00:00:00Z`).getUTCDay();
  const mondayIndex = (day + 6) % 7;
  if (token.startsWith('下周')) { return shiftDate(anchor, 7 - mondayIndex + weekday); }
  if (token.startsWith('本周') || token.startsWith('这周')) { return shiftDate(anchor, weekday - mondayIndex); }
  return shiftDate(anchor, (weekday - mondayIndex + 7) % 7);
}

function timeValue(token: string): string {
  const colon = /^([0-9]{1,2}):([0-9]{2})$/.exec(token);
  if (colon !== null) {
    const hour = Number(colon[1]); const minute = Number(colon[2]);
    return hour <= 23 && minute <= 59 ? `${hour}`.padStart(2, '0') + ':' + colon[2] : '';
  }
  const words = /^(明|今)?(凌晨|早上|上午|中午|下午|晚上|早|晚)?([0-9]+|[零〇一二两三四五六七八九十百]+)点(半|([0-9]+|[零〇一二两三四五六七八九十百]+)分)?$/.exec(token);
  if (words === null) { return ''; }
  let hour = numberWord(words[3]);
  const minute = words[4] === '半' ? 30 : (words[5] === undefined ? 0 : numberWord(words[5]));
  const period = words[2] ?? '';
  if (hour === null || minute === null || !Number.isInteger(hour) || !Number.isInteger(minute) || minute > 59 || hour > 23) { return ''; }
  if (period.length === 0 && hour >= 1 && hour <= 12) { return ''; }
  if (period === '下午' || period === '晚上' || period === '晚') {
    if (hour < 1 || hour > 12) { return ''; }
    if (hour < 12) { hour += 12; }
    // 十二点晚上可能指次日零点；不悄悄选择日期。
    if ((period === '晚上' || period === '晚') && hour === 12) { return ''; }
  } else if (period === '中午') {
    if (hour !== 12) { return ''; }
  } else if (period.length > 0 && (hour > 11 || (period !== '凌晨' && hour === 0))) { return ''; }
  return `${hour}`.padStart(2, '0') + ':' + `${minute}`.padStart(2, '0');
}

export function captureEndAt(date: string, time: string, durationMinutes: number | null): string | null {
  if (!validDate(date) || !/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(time) || durationMinutes === null ||
    !Number.isInteger(durationMinutes) || durationMinutes <= 0 || durationMinutes > 1440) { return null; }
  const end = Date.parse(`${date}T${time}:00+08:00`) + durationMinutes * 60000;
  const shifted = new Date(end + 8 * 3600000);
  const endDate = dateAt(shifted.getTime());
  if (!validDate(endDate)) { return null; }
  return `${endDate}T${`${shifted.getUTCHours()}`.padStart(2, '0')}:${`${shifted.getUTCMinutes()}`.padStart(2, '0')}:00+08:00`;
}

export function parseQuickCapture(text: string, anchorDate: string): QuickCaptureCandidate {
  const result: QuickCaptureCandidate = { originalText: text, title: text.trim(), date: '', time: '',
    durationMinutes: null, anchorDate: anchorDate, timezone: 'Asia/Shanghai', issues: [], unsupported: [], requiresReview: false };
  if (!validDate(anchorDate)) {
    issue(result, 'date', 'ANCHOR_INVALID', '输入基准日期无效，请重新选择具体日期。'); result.requiresReview = true; return result;
  }
  if (Array.from(text).length > 2048) {
    issue(result, 'title', 'INPUT_TOO_LONG', '这句话过长，请缩短后再解析；原文仍保留。'); result.requiresReview = true; return result;
  }
  const remove: CaptureSpan[] = [];
  const unsupported: CaptureUnsupportedRule[] = [
    { pattern: /(每周|每天|每月|隔天|工作日|节假日|周末)/, label: '循环或范围日期请手动选择。' },
    { pattern: /(下课后|上课前|晚点|稍后|有空时|找一天|放学后)/, label: '相对事件或模糊时刻请手动填写。' },
    { pattern: /([一二三四五六七八九][一二三四五六七八九]点|[0-9]+[到至~～][0-9]+点)/, label: '大概时刻不自动换成某一个整点。' },
    { pattern: /(然后|以及|同时|；|;|\n)/, label: '一句多项暂不拆分，请一次记录一件事。' }
  ];
  unsupported.forEach((rule: CaptureUnsupportedRule, index: number) => {
    if (rule.pattern.test(text)) { result.unsupported.push(rule.label); issue(result, 'text', `UNSUPPORTED_${index}`, rule.label); }
  });
  const dates = matches(text, /[0-9]{4}-[0-9]{2}-[0-9]{2}|今天|今日|明天|后天|明晚|明早|明晨|今晚|今早|今晨|今夜|(?:本周|下周|这周|周|星期)[一二三四五六日天]/g);
  if (dates.length > 1) { issue(result, 'date', 'DATE_AMBIGUOUS', '发现多个日期，请选择本次事项的日期。'); }
  else if (dates.length === 1 && !/(每周|每天|每月|隔天|工作日|节假日|周末)/.test(text)) {
    result.date = dateValue(dates[0].value, anchorDate);
    if (/^[0-9]/.test(dates[0].value) && (/[0-9-]/.test(text.substring(Math.max(0, dates[0].start - 1), dates[0].start)) ||
      /[0-9-]/.test(text.substring(dates[0].end, dates[0].end + 1)))) { result.date = ''; }
    if (result.date.length === 0) { issue(result, 'date', 'DATE_INVALID', '日期不存在或超出范围，请手动核对。'); }
    else {
      remove.push(dates[0]);
      if (result.date < anchorDate) { issue(result, 'date', 'DATE_IN_PAST', '这个日期早于输入基准日，已保留原日期，请核对。'); }
    }
  }
  const times = matches(text, /[0-9]{1,2}:[0-9]{2}|(?:明|今)?(?:凌晨|早上|上午|中午|下午|晚上|早|晚)?(?:[0-9]+|[零〇一二两三四五六七八九十百]+)点(?:半|(?:[0-9]+|[零〇一二两三四五六七八九十百]+)分)?/g);
  if (times.length > 1) { issue(result, 'time', 'TIME_AMBIGUOUS', '发现多个时刻，请手动选择开始时间。'); }
  else if (times.length === 1) {
    const item = times[0];
    result.time = timeValue(item.value);
    const period = /(凌晨|早上|上午|中午|下午|晚上|早|晚)$/.exec(text.substring(0, item.start));
    if (item.value.includes(':') && period !== null && result.time.length > 0) {
      const hour = Number(result.time.substring(0, 2));
      const label = period[1];
      const consistent = /^(凌晨|早上|上午|早)$/.test(label) ? hour < 12 :
        (label === '中午' ? hour === 12 : (label === '下午' ? hour >= 12 && hour < 18 : hour >= 18));
      if (!consistent) { result.time = ''; issue(result, 'time', 'TIME_PERIOD_CONFLICT', '时段和 24 小时时刻不一致，请明确选择开始时间。'); }
      else { remove.push({ start: item.start - label.length, end: item.start, value: label }); }
    }
    if ((item.start > 0 && /[0-9:第约近负\-]/.test(text.substring(item.start - 1, item.start))) ||
      /[0-9:]/.test(text.substring(item.end, item.end + 1)) || text.substring(item.end, item.end + 2) === '左右') { result.time = ''; }
    if (result.time.length === 0) { issue(result, 'time', 'TIME_NEEDS_CLARIFICATION', '时刻不明确或无效，请填写 24 小时制时间。'); }
    else { remove.push(item); }
  } else if (/(下午|上午|晚上|中午|凌晨|早上|明晚|今晚)/.test(text)) {
    issue(result, 'time', 'TIME_REQUIRED', '只识别到时段，请填写明确时刻，或主动选择不指定时刻。');
  }
  const durations = matches(text, /(?:半|[0-9]+(?:\.[0-9]+)?|[零〇一二两三四五六七八九十百]+)(?:个)?(?:小时|分钟)/g);
  if (durations.length > 1) { issue(result, 'duration', 'DURATION_AMBIGUOUS', '发现多个时长，请合并后填写本次所需分钟数。'); }
  else if (durations.length === 1) {
    const item = durations[0];
    const parts = /^(半|[0-9]+(?:\.[0-9]+)?|[零〇一二两三四五六七八九十百]+)(?:个)?(小时|分钟)$/.exec(item.value);
    const value = parts === null ? null : numberWord(parts[1]);
    const minutes = value === null || parts === null ? 0 : value * (parts[2] === '小时' ? 60 : 1);
    const previous = text.substring(Math.max(0, item.start - 1), item.start);
    const adjacentField = remove.some((span: CaptureSpan) => span.end === item.start);
    if (minutes <= 0 || minutes > 1440 || !Number.isInteger(minutes) || /[第负约近.\-+]/.test(previous) ||
      (/[0-9]/.test(previous) && !adjacentField) ||
      text.substring(item.end, item.end + 2) === '左右') {
      issue(result, 'duration', 'DURATION_INVALID', '时长未能确定，请填写 1–1440 的整分钟数。');
    } else { result.durationMinutes = minutes; remove.push(item); }
  }
  if (result.time.length > 0 && result.date.length === 0) { issue(result, 'date', 'DATE_REQUIRED', '已有时刻，请补上日期；不会自动当作今天。'); }
  if (result.durationMinutes !== null && result.time.length === 0) { issue(result, 'time', 'TIME_REQUIRED', '已保留时长，请补上明确开始时间。'); }
  if (result.time === '23:59' && result.durationMinutes === null) {
    issue(result, 'time', 'TIME_PRECISION_REQUIRED', '23:59 未填写时长会与旧全天记录混淆，请补时长或明确选择全天。');
  }
  // Keep the original available; only recognized, unambiguous spans leave the editable title.
  let title = '';
  for (let index = 0; index < text.length; index++) {
    if (!remove.some((span: CaptureSpan) => index >= span.start && index < span.end)) { title += text.substring(index, index + 1); }
  }
  result.title = title.replace(/^[\s，,；;：:]+|[\s，,；;：:]+$/g, '').replace(/[ \t]{2,}/g, ' ');
  if (result.title.length === 0) { issue(result, 'title', 'TITLE_REQUIRED', '还没有事项名称，请补充要做什么。'); }
  if (Array.from(result.title).length > 120) { issue(result, 'title', 'TITLE_TOO_LONG', '事项名称请控制在 120 字以内，原文没有截断。'); }
  result.requiresReview = result.issues.length > 0 || result.unsupported.length > 0;
  return result;
}
