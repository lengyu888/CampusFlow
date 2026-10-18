import { ReviewSnapshot, ReviewFacts } from '../model/ReviewModels';
import { validateReview } from './ReviewValidation';
import { reviewRange, reviewShiftAnchor } from './ReviewTime';

export function reviewSummary(snapshot: ReviewSnapshot, facts: ReviewFacts, includedNote: string = ''): string {
  if (!snapshot || !facts || typeof facts.completed !== 'boolean' || typeof facts.unscheduled !== 'boolean' || typeof facts.focus !== 'boolean' ||
    typeof includedNote !== 'string' || Array.from(includedNote).length > 500 ||
    !validateReview(snapshot, snapshot.user_id, snapshot.period, snapshot.anchor)) { return ''; }
  const note = includedNote.trim();
  if (!facts.completed && !facts.unscheduled && !facts.focus && note.length === 0) { return ''; }
  const range = reviewRange(snapshot.period, snapshot.anchor);
  if (range === null) { return ''; }
  const lastDay = reviewShiftAnchor(range.noteAnchor, snapshot.period === 'week' ? 6 : 0);
  const lines: string[] = [`请根据我选中的回看事实，帮我想一个可调整的小步；先提出建议，未经确认不要修改安排。`,
    `范围：${range.noteAnchor}${snapshot.period === 'week' ? ` 至 ${lastDay}` : ''}（校园时间 UTC+08:00）。`,
    `资料读取时间：${snapshot.as_of}。这是该时间读取的当前资料，不是历史状态的完整还原。`];
  if (facts.completed) { lines.push(`本期完成、当前仍完成的事项：${snapshot.totals.current_completed_count} 项。`); }
  if (facts.unscheduled) { lines.push(`当前尚未安排开始时间的待办：${snapshot.totals.current_unscheduled_count} 项；不是本期结束时的历史待办数。`); }
  if (facts.focus) {
    const ms = snapshot.totals.confirmed_elapsed_ms;
    lines.push(`本期已同步且有确认片段的专注记录时长：${ms} 毫秒（约 ${(ms / 60000).toFixed(1)} 分钟）；不等同于有效学习时间。`);
    lines.push(`本期开始的待核对区间：${snapshot.totals.unknown_gap_count} 段；未计入时长，也不包括本机待同步内容。`);
  }
  if (note.length > 0) { lines.push(`我主动选入的一句感受：\n${note}`); }
  return lines.join('\n');
}
