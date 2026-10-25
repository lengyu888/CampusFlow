import { PlanningCourseConflict, ReplanChange, ReplanUnresolved, TimetableEntry } from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { PlanningReplanController, ReplanViewState, hasCourseClassification, conflictCourseOverlap } from '../utils/PlanningReplan';
import { formatPlanDateTime, formatPlanTimeRange } from '../utils/PlanPresentation';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { AppIcon } from './AppIcon';

@Component
export struct PlanningConflictsPanel {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Prop baseUrl: string;
  @Prop token: string;
  @Watch('refreshRequested') @Prop refreshKey: number = 0;
  @Watch('activityChanged') @Prop active: boolean = true;
  @Prop compact: boolean = false;
  @Prop writeBlocked: boolean = false;
  @Prop statusLockedTaskIds: string[] = [];
  onOpenStatus: (taskId: string) => void = () => {};
  onWriteStateChanged: (blocked: boolean) => void = () => {};
  onApplied: () => void = () => {};
  onOpenDetails: () => void = () => {};
  onOpenTask: (taskId: string) => void = () => {};
  @State private state: ReplanViewState = {
    phase: 'idle', report: null, preview: null, message: '', notice: ''
  };
  @State private detailsExpanded: boolean = false;
  @State private conflictPage: number = 0;
  @State private acceptedPage: number = 0;
  @State private reviewPage: number = 0;
  @State private uncheckedPage: number = 0;
  @State private changesPage: number = 0;
  @State private unresolvedPage: number = 0;
  @State private viewRevision: number = 0;
  private controller: PlanningReplanController | null = null;
  private pageActive: boolean = true;

  aboutToAppear(): void {
    this.pageActive = true;
    this.replanner().setActive(this.active);
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.controller?.dispose();
    this.controller = null;
  }

  private replanner(): PlanningReplanController {
    if (this.controller === null) {
      this.controller = new PlanningReplanController(new CampusFlowApi(this.baseUrl, this.token),
        (state: ReplanViewState) => {
          if (!this.pageActive) { return; }
          if (this.state.report?.checked_at !== state.report?.checked_at) {
            this.conflictPage = 0;
            this.acceptedPage = 0; this.reviewPage = 0;
            this.uncheckedPage = 0;
          }
          if (this.state.preview?.replan_id !== state.preview?.replan_id) {
            this.changesPage = 0;
            this.unresolvedPage = 0;
          }
          this.state = state;
          this.onWriteStateChanged(this.needsResultCheck());
          this.conflictPage = this.validPage(this.conflictPage, state.report?.conflicts.length ?? 0);
          this.acceptedPage = this.validPage(this.acceptedPage, state.report?.accepted_course_overlaps?.length ?? 0);
          this.reviewPage = this.validPage(this.reviewPage, state.report?.course_overlap_reviews?.length ?? 0);
          this.uncheckedPage = this.validPage(this.uncheckedPage, state.report?.unchecked.length ?? 0);
          this.changesPage = this.validPage(this.changesPage, state.preview?.changes.length ?? 0);
          this.unresolvedPage = this.validPage(this.unresolvedPage, state.preview?.unresolved.length ?? 0);
          // Results are ordinary data objects; rebuild rows when their content changes.
          this.viewRevision++;
        }, () => { if (this.pageActive) { this.onApplied(); } });
    }
    return this.controller;
  }

  private activityChanged(): void {
    if (this.pageActive) { this.replanner().setActive(this.active); }
  }

  private refreshRequested(): void {
    if (this.pageActive) { this.replanner().refresh(); }
  }

  private previewRequested(): void {
    if (this.active && !this.writeBlocked) { this.replanner().preview(); }
  }

  private lockedChangeId(): string {
    return this.state.preview?.changes.find((change: ReplanChange) => this.statusLockedTaskIds.includes(change.task_id))?.task_id ?? '';
  }

  private confirmRequested(): void {
    if (!this.active || this.writeBlocked) { return; }
    const locked = this.lockedChangeId();
    if (locked.length > 0) { this.onOpenStatus(locked); return; }
    this.replanner().confirm();
  }

  private busy(): boolean {
    return ['loading', 'previewing', 'confirming', 'checking'].includes(this.state.phase);
  }

  private needsResultCheck(): boolean {
    return ['confirming', 'uncertain', 'checking'].includes(this.state.phase);
  }

  private summaryTitle(): string {
    if (this.needsResultCheck()) { return '有一笔改期需要核对结果'; }
    if (this.state.phase === 'previewing') { return '正在生成改期预览'; }
    if (this.state.phase === 'review') { return '改期预览待你确认'; }
    if (this.state.report === null) { return this.busy() ? '正在核对课表与任务' : '课表与任务冲突核对'; }
    const count = this.state.report.conflicts.length;
    const reviews = this.state.report.course_overlap_reviews?.length ?? 0;
    if (reviews > 0) { return `${reviews} 项课内安排需要重新核对${count > 0 ? ` · 另有 ${count} 项冲突` : ''}`; }
    if (count > 0) { return `${count} 项任务与课程冲突`; }
    const accepted = this.state.report.accepted_course_overlaps?.length ?? 0;
    if (accepted > 0) { return `${accepted} 项已确认课内安排`; }
    return hasCourseClassification(this.state.report) ? '本次未发现待处理的课程重叠' : '暂未发现普通课程冲突';
  }

  private summaryDetail(): string {
    if (this.needsResultCheck()) { return '打开详情查询结果，请勿重复提交。'; }
    if (this.state.phase === 'review') { return '查看旧/新时间与未能安排的任务，再确认。'; }
    if (this.state.message.length > 0) { return this.state.message; }
    if (this.state.report !== null && !hasCourseClassification(this.state.report)) {
      return '此服务未提供课内确认分类，请升级后再核对；不代表所有重叠已处理。';
    }
    const count = this.state.report?.unchecked.length ?? 0;
    const accepted = this.state.report?.accepted_course_overlaps?.length ?? 0;
    return `${accepted > 0 ? `${accepted} 项已确认安排保持原时段 · ` : ''}` +
      (count > 0 ? `另有 ${count} 项待办需要人工核对 · 查看详情` : '仅核对未结束、时段完整的未完成任务 · 查看详情');
  }

  private openDetails(): void {
    if (this.active) { this.onOpenDetails(); }
  }

  private compactNeedsDetail(): boolean {
    const report = this.state.report;
    return report === null || this.state.message.length > 0 || this.busy() ||
      this.needsResultCheck() || this.state.phase === 'review' ||
      !hasCourseClassification(report) || report.unchecked.length > 0 ||
      this.overlapCount('conflicts') + this.overlapCount('reviews') > 0;
  }

  private busyText(): string {
    if (this.state.phase === 'previewing') { return '正在按课表寻找空档…'; }
    if (this.state.phase === 'confirming') { return '正在确认改期，请勿重复提交…'; }
    if (this.state.phase === 'checking') { return '正在查询上次确认结果…'; }
    return '正在核对当前课表与任务…';
  }

  private conflictRows(): PlanningCourseConflict[] {
    return this.overlapRows('conflicts');
  }

  private overlapCount(kind: string): number {
    if (kind === 'accepted') { return this.state.report?.accepted_course_overlaps?.length ?? 0; }
    if (kind === 'reviews') { return this.state.report?.course_overlap_reviews?.length ?? 0; }
    return this.state.report?.conflicts.length ?? 0;
  }

  private overlapRows(kind: string): PlanningCourseConflict[] {
    const items = kind === 'accepted' ? this.state.report?.accepted_course_overlaps :
      kind === 'reviews' ? this.state.report?.course_overlap_reviews : this.state.report?.conflicts;
    const page = this.pageFor(kind);
    const sorted = (items ?? []).slice().sort((left: PlanningCourseConflict, right: PlanningCourseConflict) => {
      const time = Date.parse(left.start_at) - Date.parse(right.start_at);
      return time !== 0 ? time : left.task_id < right.task_id ? -1 : left.task_id > right.task_id ? 1 : 0;
    });
    return sorted.slice(page * 6, page * 6 + 6);
  }

  private detailCount(): number {
    return this.overlapCount('conflicts') + this.overlapCount('accepted') + this.overlapCount('reviews') +
      (this.state.report?.unchecked.length ?? 0);
  }

  private overlapText(item: PlanningCourseConflict, course: TimetableEntry): string {
    const overlap = conflictCourseOverlap(item, course);
    return overlap === null ? '交集尚未核实' : `实际重叠：${formatPlanTimeRange(overlap.start_at, overlap.end_at)}`;
  }

  private openTask(id: string): void {
    if (!this.active || this.busy() || this.needsResultCheck()) { return; }
    const report = this.state.report;
    const present = (report?.conflicts ?? []).concat(report?.accepted_course_overlaps ?? [], report?.course_overlap_reviews ?? [])
      .some((item: PlanningCourseConflict) => item.task_id === id) || (report?.unchecked ?? []).some((item: ReplanUnresolved) => item.task_id === id) ||
      (this.state.preview?.unresolved ?? []).some((item: ReplanUnresolved) => item.task_id === id);
    if (present) { this.onOpenTask(id); }
  }

  private uncheckedRows(): ReplanUnresolved[] {
    return (this.state.report?.unchecked ?? []).slice(this.uncheckedPage * 6, this.uncheckedPage * 6 + 6);
  }

  private changeRows(): ReplanChange[] {
    return (this.state.preview?.changes ?? []).slice(this.changesPage * 6, this.changesPage * 6 + 6);
  }

  private unresolvedRows(): ReplanUnresolved[] {
    return (this.state.preview?.unresolved ?? []).slice(this.unresolvedPage * 6, this.unresolvedPage * 6 + 6);
  }

  private pageFor(kind: string): number {
    if (kind === 'conflicts') { return this.conflictPage; }
    if (kind === 'accepted') { return this.acceptedPage; }
    if (kind === 'reviews') { return this.reviewPage; }
    if (kind === 'unchecked') { return this.uncheckedPage; }
    return kind === 'changes' ? this.changesPage : this.unresolvedPage;
  }

  private validPage(page: number, count: number): number {
    return Math.max(0, Math.min(page, Math.ceil(count / 6) - 1));
  }

  private movePage(kind: string, offset: number, count: number): void {
    const page = this.validPage(this.pageFor(kind) + offset, count);
    if (kind === 'conflicts') { this.conflictPage = page; }
    else if (kind === 'accepted') { this.acceptedPage = page; }
    else if (kind === 'reviews') { this.reviewPage = page; }
    else if (kind === 'unchecked') { this.uncheckedPage = page; }
    else if (kind === 'changes') { this.changesPage = page; }
    else { this.unresolvedPage = page; }
  }

  @Builder
  private Pagination(kind: string, count: number) {
    if (count > 6) {
      Row({ space: 8 }) {
        Button('上一页').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(13)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
          .enabled(this.pageFor(kind) > 0).onClick(() => this.movePage(kind, -1, count))
        Text(`${this.pageFor(kind) + 1} / ${Math.ceil(count / 6)}`).fontSize(13).fontColor(this.palette.secondary)
        Button('下一页').layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(13)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
          .enabled((this.pageFor(kind) + 1) * 6 < count).onClick(() => this.movePage(kind, 1, count))
      }.width('100%')
    }
  }

  @Builder
  private UnresolvedRow(item: ReplanUnresolved) {
    Column({ space: 6 }) {
      Text(item.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
        .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(item.reason).fontSize(13).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Button('查看任务').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize)
        .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
        .enabled(this.active && !this.busy() && !this.needsResultCheck()).onClick(() => this.openTask(item.task_id))
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(this.palette.canvas).borderRadius(this.palette.controlRadius)
  }

  @Builder
  private ConflictGroup(kind: string, title: string) {
    if (this.overlapCount(kind) > 0) {
      Text(`${title} · ${this.overlapCount(kind)} 项`).fontSize(this.palette.bodySize)
        .fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      if (kind === 'accepted') {
        Text('这些是已明确确认的课内安排，将保持原时段。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      } else if (kind === 'reviews') {
        Text('课表或任务变过，需要重新核对具体重叠；规则改期不会擅自移动。').fontSize(this.palette.metaSize)
          .fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
    }
    ForEach(this.overlapRows(kind), (item: PlanningCourseConflict) => {
      Column({ space: 8 }) {
        Text(item.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
          .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text(`任务：${formatPlanTimeRange(item.start_at, item.end_at)}`).fontSize(13)
          .fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
        ForEach(item.courses, (course: TimetableEntry) => {
          Column({ space: 4 }) {
            Text(`课程：${course.title}\n${course.date} ${course.start_time}–${course.end_time}`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(`${course.location.length > 0 ? course.location : '地点未设置'}${course.teacher.length > 0 ? ` · ${course.teacher}` : ''}`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(this.overlapText(item, course)).fontSize(this.palette.metaSize).fontColor(kind === 'accepted' ? this.palette.accent : this.palette.warning)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }, (_course: TimetableEntry, index: number) => `${item.task_id}-course-${index}-${this.viewRevision}`)
        Button(kind === 'reviews' ? '查看任务，重新核对' : '查看任务').constraintSize({ minHeight: 48 })
          .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
          .enabled(this.active && !this.busy() && !this.needsResultCheck()).onClick(() => this.openTask(item.task_id))
      }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
        .backgroundColor(this.palette.canvas).borderRadius(this.palette.controlRadius)
    }, (item: PlanningCourseConflict) => `${kind}-${item.task_id}-${this.viewRevision}`)
    this.Pagination(kind, this.overlapCount(kind))
  }

  @Builder
  private ConflictDetails() {
    this.ConflictGroup('reviews', '需要重新核对')
    this.ConflictGroup('conflicts', '尚未允许的课程冲突')
    this.ConflictGroup('accepted', '已确认课内安排')
    if ((this.state.report?.unchecked.length ?? 0) > 0) {
      Text(`仍需核对 · ${this.state.report?.unchecked.length ?? 0} 项`).fontSize(14)
        .fontWeight(FontWeight.Medium).fontColor(this.palette.ink).width('100%')
      ForEach(this.uncheckedRows(), (item: ReplanUnresolved) => {
        this.UnresolvedRow(item)
      }, (item: ReplanUnresolved) => `unchecked-${item.task_id}-${this.viewRevision}`)
      this.Pagination('unchecked', this.state.report?.unchecked.length ?? 0)
    }
  }

  @Builder
  private Preview() {
    Column({ space: 12 }) {
      Divider().color(this.palette.line)
      Text(this.state.phase === 'applied' ? '已确认的改期结果' : '改期预览')
        .fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).width('100%')
      Text(this.state.preview?.policy ?? '').fontSize(13).lineHeight(21)
        .fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`可调整 ${this.state.preview?.changes.length ?? 0} 项 · 仍需处理 ${this.state.preview?.unresolved.length ?? 0} 项`)
        .fontSize(14).fontColor(this.palette.ink).width('100%')
      if (this.state.phase !== 'applied') {
        Text(this.needsResultCheck() ? '本次确认已发出，任务是否改期请以查询结果为准；暂不重复提交。' :
          `确认前不会修改原任务；预览有效至 ${formatPlanDateTime(this.state.preview?.expires_at ?? null)}。`)
          .fontSize(13).lineHeight(21).fontColor(this.palette.secondary).width('100%')
      }
      ForEach(this.changeRows(), (item: ReplanChange) => {
        Column({ space: 8 }) {
          Text(item.title).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
            .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(`原时间：${formatPlanTimeRange(item.old_start_at, item.old_end_at)}`)
            .fontSize(13).fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Text(`新时间：${formatPlanTimeRange(item.new_start_at, item.new_end_at)}`)
            .fontSize(13).fontColor(this.palette.accent).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
          .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
      }, (item: ReplanChange) => `change-${item.task_id}-${this.viewRevision}`)
      this.Pagination('changes', this.state.preview?.changes.length ?? 0)
      if ((this.state.preview?.unresolved.length ?? 0) > 0) {
        Text('以下任务仍需处理，确认不会改变它们的时间。').fontSize(13).fontColor(this.palette.warning).width('100%')
        ForEach(this.unresolvedRows(), (item: ReplanUnresolved) => {
          this.UnresolvedRow(item)
        }, (item: ReplanUnresolved) => `unresolved-${item.task_id}-${this.viewRevision}`)
        this.Pagination('unresolved', this.state.preview?.unresolved.length ?? 0)
      }
      if (this.state.phase === 'review') {
        if (this.lockedChangeId().length > 0) {
          Text('这批改期涉及尚待核对完成 / 恢复结果的任务，请先处理对应原操作。').fontSize(this.palette.bodySize)
            .fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
          Button('核对相关任务结果').width('100%').constraintSize({ minHeight: 48 }).enabled(this.active)
            .onClick(() => this.onOpenStatus(this.lockedChangeId()))
        }
        Button(`确认调整这 ${this.state.preview?.changes.length ?? 0} 项任务`).width('100%')
          .constraintSize({ minHeight: 48 }).fontSize(15).fontColor(this.palette.surface)
          .backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
          .enabled(this.active && !this.writeBlocked && !this.busy() && this.lockedChangeId().length === 0 && (this.state.preview?.changes.length ?? 0) > 0)
          .onClick(() => this.confirmRequested())
      }
      if (['review', 'error', 'stale'].includes(this.state.phase)) {
        Button('放弃这份预览').width('100%').constraintSize({ minHeight: 48 }).fontSize(14)
          .fontColor(this.palette.secondary).backgroundColor(Color.Transparent).enabled(this.active && !this.busy())
          .onClick(() => this.replanner().dismiss())
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private FullContent() {
    Column({ space: 12 }) {
      Text('课表与任务核对').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold)
        .fontColor(this.palette.ink).width('100%')
      Text('这里只扫描未结束、时段完整的未完成任务；规则改期需你确认，不自动移动已接受的课内安排。以下时间均为北京时间。')
        .fontSize(13).lineHeight(21).fontColor(this.palette.secondary).width('100%')
      if (this.state.report !== null) {
        Text(this.summaryTitle())
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.overlapCount('conflicts') + this.overlapCount('reviews') > 0 ?
            this.palette.warning : this.palette.ink).width('100%')
        Text(`核对时间：${formatPlanDateTime(this.state.report?.checked_at ?? null)}`)
          .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
        if (!hasCourseClassification(this.state.report)) {
          Text('此服务未提供课内确认分类，当前结果不能证明所有重叠已处理。升级服务后请重新核对。')
            .fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
        if ((this.state.report?.unchecked.length ?? 0) > 0) {
          Text(`另有 ${this.state.report?.unchecked.length ?? 0} 项待办缺少可核对时段或不适合自动改期。`)
            .fontSize(13).fontColor(this.palette.warning).width('100%')
        }
        if (this.detailCount() > 0) {
          Button(this.detailsExpanded ? '收起核对详情' : '展开全部核对详情').width('100%')
            .constraintSize({ minHeight: 48 }).fontSize(14).fontColor(this.palette.accent)
            .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
            .onClick(() => this.detailsExpanded = !this.detailsExpanded)
          if (this.detailsExpanded) { this.ConflictDetails() }
        }
      }
      if (this.busy()) {
        Row({ space: 8 }) {
          LoadingProgress().width(20).height(20).color(this.palette.accent)
          Text(this.busyText()).fontSize(13).fontColor(this.palette.secondary).layoutWeight(1)
        }.width('100%')
      }
      if (this.state.message.length > 0) {
        Text(this.state.message).fontSize(13).lineHeight(21).fontColor(this.palette.warning)
          .width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.state.notice.length > 0) {
        Text(this.state.notice).fontSize(13).lineHeight(21).fontColor(this.palette.secondary)
          .width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      if (this.state.phase === 'uncertain') {
        Button('查询上次确认结果').width('100%').constraintSize({ minHeight: 48 }).fontSize(15)
          .fontColor(this.palette.surface).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
          .enabled(this.active).onClick(() => this.replanner().checkResult())
      }
      if (!this.needsResultCheck()) {
        Button('重新核对当前课表').width('100%').constraintSize({ minHeight: 48 }).fontSize(14)
          .fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
          .enabled(this.active && !this.busy()).onClick(() => this.replanner().refresh())
        if ((this.state.report?.conflicts.length ?? 0) > 0 && this.state.phase !== 'review') {
          Button(this.state.phase === 'stale' || this.state.phase === 'error' ? '重新生成改期预览' : '按课表寻找空档，生成预览')
            .width('100%').constraintSize({ minHeight: 48 }).fontSize(15).fontColor(this.palette.surface)
            .backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
            .enabled(this.active && !this.writeBlocked && !this.busy()).onClick(() => this.previewRequested())
        }
      }
      if (this.state.preview !== null) { this.Preview() }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }

  build() {
    if (this.compact) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(this.compactNeedsDetail() ? this.summaryTitle() : '本次无待处理的课程重叠')
              .fontSize(this.palette.metaSize).fontWeight(FontWeight.Medium)
              .fontColor(this.needsResultCheck() || this.overlapCount('conflicts') + this.overlapCount('reviews') > 0 ? this.palette.warning : this.palette.secondary)
              .layoutWeight(1).textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
            AppIcon({ name: 'chevron', iconSize: 14, color: this.palette.secondary })
          }.width('100%')
          if (this.compactNeedsDetail()) {
            Text(this.summaryDetail()).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
              .width('100%').textAlign(TextAlign.Start).wordBreak(WordBreak.BREAK_WORD)
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor(this.compactNeedsDetail() ? this.palette.surface : Color.Transparent)
        .borderRadius(this.palette.controlRadius).enabled(this.active)
        .accessibilityText(`${this.summaryTitle()}，${this.summaryDetail()}`)
        .onClick(() => this.openDetails())
    } else {
      Scroll() {
        this.FullContent()
      }.width('100%').height('100%').align(Alignment.TopStart)
    }
  }
}
