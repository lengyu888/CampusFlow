import {
  ClassroomItem,
  DataEvidence,
  ClassroomSearchResponse,
  ClassroomUsageItem,
  ClassroomUsageResponse,
  ElectricityHistoryItem,
  ElectricityOverview,
  HDUHelpDataResponse,
  HDUHelpDisplayItem,
  HDUHelpDisplaySection,
  HDUHelpSuggestedPrompt
} from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { AppIcon } from '../components/AppIcon';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { EvidencePanel } from '../components/EvidencePanel';
import { evidenceTime } from '../utils/EvidencePresentation';

class CampusServiceOption implements SelectOption {
  value: string;

  constructor(value: string) {
    this.value = value;
  }
}

@Component
export struct CampusServicesPage {
  @Prop baseUrl: string;
  @Prop token: string;
  @Watch('activeChanged') @Prop active: boolean = true;
  onOpenProfile: () => void = () => {};
  private pageActive: boolean = true;
  private classroomRevision: number = 0;
  private usageRevision: number = 0;
  private electricityRevision: number = 0;
  private campusRevision: number = 0;
  private usageRoom: ClassroomItem | null = null;
  private scrollers: Scroller[] = [new Scroller(), new Scroller(), new Scroller(), new Scroller()];
  @State private usageError: string = '';
  @State private classroomLimit: number = 20;
  @State private usageLimit: number = 8;
  onBack: () => void = () => {};
  onOpenAgent: (prompt: string) => void = () => {};
  @State private activeService: number = 0;
  @State private selectedBuilding: number = 0;
  @State private selectedPeriod: number = 0;
  @State private classrooms: ClassroomItem[] = [];
  @State private classroomEvidence: DataEvidence[] = [];
  @State private usageEvidence: DataEvidence[] = [];
  @State private classroomTotal: number = 0;
  @State private classroomLabel: string = '当前时段';
  @State private classroomLoading: boolean = true;
  @State private classroomError: string = '';
  @State private usageTitle: string = '';
  @State private usageItems: ClassroomUsageItem[] = [];
  @State private usageLoading: boolean = false;
  @State private electricityLoading: boolean = true;
  @State private electricityError: string = '';
  @State private campusInfoLoading: boolean = true;
  @State private campusInfoError: string = '';
  @State private campusSections: HDUHelpDisplaySection[] = [];
  @State private campusPrompts: HDUHelpSuggestedPrompt[] = [];
  @State private campusConfigured: boolean = false;
  @State private electricityData: ElectricityOverview = {
    bound: false,
    room_name: '',
    campus_name: '',
    building_name: '',
    floor_name: '',
    meter_hint: '',
    balance: null,
    balance_updated_at: null,
    daily_average: '',
    history: []
  };

  private buildingLabels: string[] = [
    '全部教学楼', '1教', '2教', '3教', '4教', '5教北楼', '5教南楼',
    '6教北楼', '6教南楼', '7教', '8教', '9教', '10教', '11教', '12教'
  ];
  private buildingIds: string[] = [
    '', '1', '2', '3', '4', '5n', '5s', '6n', '6s', '7', '8', '9', '10', '11', '12'
  ];
  private periodLabels: string[] = ['当前', '1–2', '3–5', '6–9', '10+'];

  aboutToAppear(): void {
    this.pageActive = true;
    this.activeChanged();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.invalidateRequests();
  }

  private invalidateRequests(): void {
    this.classroomRevision++;
    this.usageRevision++;
    this.electricityRevision++;
    this.campusRevision++;
    this.classroomLoading = false;
    this.usageLoading = false;
    this.electricityLoading = false;
    this.campusInfoLoading = false;
  }

  private activeChanged(): void {
    this.invalidateRequests();
    if (this.active && this.pageActive) { this.loadCurrentService(); }
  }

  private loadCurrentService(): void {
    if (this.activeService === 0) { this.loadClassrooms(); }
    else if (this.activeService === 1) { this.loadElectricity(); }
    else { this.loadCampusInfo(); }
  }

  private selectService(index: number): void {
    if (!Number.isInteger(index) || index < 0 || index > 3 || index === this.activeService) { return; }
    this.invalidateRequests();
    this.activeService = index;
    this.loadCurrentService();
  }

  private current(token: string, baseUrl: string): boolean {
    return this.pageActive && this.active && token === this.token && baseUrl === this.baseUrl;
  }

  private chooseBuilding(index: number): void {
    if (!Number.isInteger(index) || index < 0 || index >= this.buildingIds.length) { return; }
    this.selectedBuilding = index;
    this.loadClassrooms();
  }

  private choosePeriod(index: number): void {
    if (!Number.isInteger(index) || index < 0 || index >= this.periodLabels.length) { return; }
    this.selectedPeriod = index;
    this.loadClassrooms();
  }

  private closeUsage(): void {
    this.usageRevision++;
    this.usageTitle = '';
    this.usageLoading = false;
    this.usageError = '';
    this.usageRoom = null;
  }

  private retryUsage(): void {
    if (this.usageRoom !== null) { this.loadUsage(this.usageRoom); }
  }

  private periodSections(): number[] {
    if (this.selectedPeriod === 1) return [1, 2];
    if (this.selectedPeriod === 2) return [3, 4, 5];
    if (this.selectedPeriod === 3) return [6, 7, 8, 9];
    if (this.selectedPeriod === 4) return [10, 11, 12, 13];
    return [];
  }

  private async loadClassrooms(): Promise<void> {
    if (!this.pageActive || !this.active || this.activeService !== 0) { return; }
    const revision = ++this.classroomRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    this.classroomLoading = true;
    this.classroomError = '';
    this.closeUsage();
    try {
      const result: ClassroomSearchResponse = await new CampusFlowApi(baseUrl, token)
        .unusedClassrooms(this.buildingIds[this.selectedBuilding], this.periodSections());
      if (!this.current(token, baseUrl) || revision !== this.classroomRevision) { return; }
      this.classrooms = result.items;
      this.classroomEvidence = result.evidence ?? [];
      this.classroomTotal = result.total;
      this.classroomLabel = result.query_label;
      this.classroomLimit = 20;
    } catch {
      if (this.current(token, baseUrl) && revision === this.classroomRevision) {
        this.classroomError = '暂时无法查询空闲教室，请检查连接后重试。';
      }
    } finally {
      if (this.current(token, baseUrl) && revision === this.classroomRevision) { this.classroomLoading = false; }
    }
  }

  private async loadUsage(room: ClassroomItem): Promise<void> {
    if (!this.pageActive || !this.active || this.activeService !== 0 || this.classroomLoading) { return; }
    const revision = ++this.usageRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    this.usageTitle = room.location_name;
    this.usageRoom = room;
    this.usageLoading = true;
    this.usageError = '';
    this.usageItems = [];
    this.usageEvidence = [];
    this.usageLimit = 8;
    try {
      const result: ClassroomUsageResponse = await new CampusFlowApi(baseUrl, token).classroomUsage(room.location_id);
      if (this.current(token, baseUrl) && revision === this.usageRevision) {
        this.usageItems = result.items;
        this.usageEvidence = result.evidence ?? [];
      }
    } catch {
      if (this.current(token, baseUrl) && revision === this.usageRevision) {
        this.usageError = '暂时无法读取这间教室的占用安排，可以重试。';
      }
    } finally {
      if (this.current(token, baseUrl) && revision === this.usageRevision) { this.usageLoading = false; }
    }
  }

  private async loadElectricity(): Promise<void> {
    if (!this.pageActive || !this.active || this.activeService !== 1) { return; }
    const revision = ++this.electricityRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    this.electricityLoading = true;
    this.electricityError = '';
    try {
      const result = await new CampusFlowApi(baseUrl, token).electricity();
      if (this.current(token, baseUrl) && revision === this.electricityRevision) { this.electricityData = result; }
    } catch {
      if (this.current(token, baseUrl) && revision === this.electricityRevision) {
        this.electricityError = '暂时无法读取电费数据，请检查连接后重试。';
      }
    } finally {
      if (this.current(token, baseUrl) && revision === this.electricityRevision) { this.electricityLoading = false; }
    }
  }

  private async loadCampusInfo(): Promise<void> {
    if (!this.pageActive || !this.active || this.activeService < 2) { return; }
    const revision = ++this.campusRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    this.campusInfoLoading = true;
    this.campusInfoError = '';
    try {
      const result: HDUHelpDataResponse = await new CampusFlowApi(baseUrl, token).hduHelpData();
      if (!this.current(token, baseUrl) || revision !== this.campusRevision) { return; }
      this.campusConfigured = result.status.configured;
      this.campusSections = result.sections;
      this.campusPrompts = result.suggested_prompts;
    } catch {
      if (this.current(token, baseUrl) && revision === this.campusRevision) {
        this.campusInfoError = '暂时无法读取校园生活数据，请检查连接后重试。';
      }
    } finally {
      if (this.current(token, baseUrl) && revision === this.campusRevision) { this.campusInfoLoading = false; }
    }
  }

  private weekdayName(value: number): string {
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return value >= 1 && value <= 7 ? labels[value - 1] : '未知日期';
  }

  private balanceText(): string {
    return this.electricityData.balance === null ? '--' : this.electricityData.balance.toFixed(2);
  }

  private updatedText(): string {
    return evidenceTime(this.electricityData.balance_updated_at);
  }

  @Builder
  private serviceTab(index: number, label: string) {
    Button() {
      Text(label).fontSize(AppTheme.metaSize)
        .fontWeight(this.activeService === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeService === index ? AppTheme.ink : AppTheme.secondary)
        .maxLines(1)
    }
      .layoutWeight(1)
      .constraintSize({ minHeight: 48 })
      .padding({ left: 4, right: 4 })
      .backgroundColor(this.activeService === index ? AppTheme.surface : Color.Transparent)
      .borderRadius(10)
      .onClick(() => {
        this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
          this.selectService(index);
        });
      })
  }

  @Builder
  private classroomCard(room: ClassroomItem) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(room.location_name).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
        Text(room.building_name).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column({ space: 4 }) {
        Text(room.self_study ? '自习标记' : '空闲记录').fontSize(AppTheme.metaSize).fontWeight(FontWeight.Bold)
          .fontColor(room.self_study ? AppTheme.success : AppTheme.accent)
        Text(room.capacity > 0 ? `${room.capacity} 座` : '容量未知').fontSize(AppTheme.metaSize).fontColor(AppTheme.muted)
      }.alignItems(HorizontalAlign.End)
      AppIcon({ name: 'chevron', iconSize: 18, color: AppTheme.muted })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(AppTheme.surface)
    .borderRadius(18)
    .onClick(() => this.loadUsage(room))
  }

  @Builder
  private classroomView() {
    Column({ space: 14 }) {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 3 }) {
            Text('查询教室空闲记录').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Text('按节次查询；出发前核对来源与现场情况').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('刷新').constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize).fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
            .borderRadius(12).onClick(() => this.loadClassrooms())
        }.width('100%')

        Select(this.buildingLabels.map((label: string) => new CampusServiceOption(label)))
          .selected(this.selectedBuilding)
          .value(this.buildingLabels[this.selectedBuilding])
          .fontColor(AppTheme.ink)
          .backgroundColor(AppTheme.field)
          .optionBgColor(AppTheme.surface).optionFontColor(AppTheme.ink)
          .selectedOptionBgColor(AppTheme.accentSoft).selectedOptionFontColor(AppTheme.accent)
          .borderRadius(14)
          .width('100%')
          .onSelect((index: number) => {
            this.chooseBuilding(index);
          })

        Row({ space: 6 }) {
          ForEach(this.periodLabels, (label: string, index: number) => {
            Button(label).layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize)
              .fontColor(this.selectedPeriod === index ? AppTheme.surface : AppTheme.secondary)
              .backgroundColor(this.selectedPeriod === index ? AppTheme.accent : AppTheme.field)
              .borderRadius(11)
              .onClick(() => {
                this.getUIContext().animateTo({ duration: AppTheme.motion(160), curve: Curve.EaseOut }, () => {
                  this.choosePeriod(index);
                });
              })
          }, (label: string) => label)
        }.width('100%')
      }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(20)

      if (this.usageTitle.length > 0) {
        Column({ space: 10 }) {
          Row() {
            Column({ space: 3 }) {
              Text(this.usageTitle).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Text('本学期占用安排').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('关闭').constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize).fontColor(AppTheme.accent)
              .backgroundColor(Color.Transparent).onClick(() => this.closeUsage())
          }.width('100%')
          if (this.usageLoading) {
            FeedbackPanel({ kind: 'loading', title: '正在读取占用安排', message: this.usageTitle })
          } else if (this.usageError.length > 0) {
            FeedbackPanel({ kind: 'error', title: '占用安排暂不可用', message: this.usageError,
              actionLabel: '重试', onAction: () => this.retryUsage() })
          } else if (this.usageItems.length === 0) {
            Text('本次未返回占用记录，不代表教室一定空闲。').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
          } else {
            ForEach(this.usageItems.slice(0, this.usageLimit), (item: ClassroomUsageItem) => {
              Row() {
                Text(`第${item.week}周 · ${this.weekdayName(item.weekday)} · 第${item.section}节`)
                  .fontSize(AppTheme.metaSize).fontColor(AppTheme.ink).layoutWeight(1)
                Text(item.course_name).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).maxLines(1)
              }.width('100%')
            }, (item: ClassroomUsageItem) => `${item.week}-${item.weekday}-${item.section}-${item.course_name}`)
            if (this.usageLimit < this.usageItems.length) {
              Button(`查看更多（还有 ${this.usageItems.length - this.usageLimit} 项）`).constraintSize({ minHeight: 48 })
                .onClick(() => this.usageLimit += 20)
            }
          }
          if (!this.usageLoading && this.usageError.length === 0) {
            EvidencePanel({ evidence: this.usageEvidence, active: this.active })
          }
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)
      }

      Row() {
        Text(this.classroomLabel).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
        Blank()
        Text(this.classroomLoading || this.classroomError.length > 0 ? '待查询' : `${this.classroomTotal} 条记录`).fontSize(AppTheme.metaSize).fontColor(AppTheme.accent)
      }.width('100%')

      if (!this.classroomLoading && this.classroomError.length === 0) {
        EvidencePanel({ evidence: this.classroomEvidence, active: this.active })
      }
      if (this.classroomLoading) {
        FeedbackPanel({ kind: 'loading', title: '正在查询空闲教室', message: '查询完成前，请勿将上次结果作为当前可用状态。' })
      } else if (this.classroomError.length > 0) {
        FeedbackPanel({ kind: 'error', title: '查询未完成', message: this.classroomError, actionLabel: '重试', onAction: () => this.loadClassrooms() })
      } else if (this.classrooms.length === 0) {
        FeedbackPanel({ kind: 'empty', title: '本次未返回教室记录', message: '先核对来源状态；也可换教学楼或节次查询。' })
      } else {
        ForEach(this.classrooms.slice(0, this.classroomLimit), (room: ClassroomItem) => {
          this.classroomCard(room)
        }, (room: ClassroomItem) => room.location_id)
        if (this.classroomLimit < this.classrooms.length) {
          Button(`查看更多（还有 ${this.classrooms.length - this.classroomLimit} 间）`).constraintSize({ minHeight: 48 })
            .onClick(() => this.classroomLimit += 20)
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private electricityView() {
    Column({ space: 14 }) {
      if (this.electricityLoading) {
        FeedbackPanel({ kind: 'loading', title: '正在读取寝室电费', message: '以数据源记录的更新时间为准。' })
      } else if (this.electricityError.length > 0) {
        FeedbackPanel({ kind: 'error', title: '电费数据暂不可用', message: this.electricityError, actionLabel: '重试', onAction: () => this.loadElectricity() })
      } else if (!this.electricityData.bound) {
        Column({ space: 8 }) {
          Text('本次未取得已绑定电表记录').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('请先核对来源状态。若尚未绑定，可在 HDUHelp 中完成绑定后刷新。').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
          Button('重新检查').constraintSize({ minHeight: 48 }).fontColor(AppTheme.onAccent).backgroundColor(AppTheme.accent).borderRadius(13)
            .onClick(() => this.loadElectricity())
        }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor(AppTheme.surface).borderRadius(18)
      } else {
        Column({ space: 18 }) {
          Row() {
            Column({ space: 4 }) {
              Text('最近记录的电费余额').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
              Row({ space: 5 }) {
                Text('¥').fontSize(21).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
                Text(this.balanceText()).fontSize(40).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              }
              Text(this.electricityData.room_name).fontSize(AppTheme.bodySize).fontColor(AppTheme.secondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Column({ space: 5 }) {
              Text('日均消耗').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
              Text(`¥${this.electricityData.daily_average.length > 0 ? this.electricityData.daily_average : '--'}`)
                .fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.success)
              Text(this.electricityData.meter_hint).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
            }.alignItems(HorizontalAlign.End)
          }.width('100%')
          Row() {
            Text(`更新于 ${this.updatedText()}`).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).layoutWeight(1)
            Button('刷新余额').constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize).fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
              .borderRadius(11).onClick(() => this.loadElectricity())
          }.width('100%')
        }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(20)

        Column({ space: 12 }) {
          Row() {
            Text('近 14 天余额').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Blank()
            Text('HDUHelp 数据').fontSize(AppTheme.metaSize).fontColor(AppTheme.accent)
          }.width('100%')
          if (this.electricityData.history.length === 0) {
            Text('暂无历史记录').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
          } else {
            ForEach(this.electricityData.history, (item: ElectricityHistoryItem) => {
              Row() {
                Text(item.date.slice(5)).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width(52)
                Text(`余额 ¥${item.balance}`).fontSize(AppTheme.bodySize).fontWeight(FontWeight.Medium)
                  .fontColor(AppTheme.ink).layoutWeight(1)
                Text(item.change === '-' ? '首日' : `${item.change} 元`).fontSize(AppTheme.metaSize)
                  .fontColor(item.change.startsWith('-') ? AppTheme.warning : AppTheme.success)
              }.width('100%').padding({ top: 8, bottom: 8 })
            }, (item: ElectricityHistoryItem) => item.date)
          }
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)
      }
      if (!this.electricityLoading && this.electricityError.length === 0) {
        EvidencePanel({ evidence: this.electricityData.evidence ?? [], active: this.active })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private campusDataItem(item: HDUHelpDisplayItem) {
    if (item.label.length > 12 || item.value.length > 22) {
      Column({ space: 5 }) {
        Text(item.label).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
        Text(item.value).fontSize(item.emphasis ? 18 : AppTheme.bodySize)
          .fontWeight(item.emphasis ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(item.emphasis ? AppTheme.accent : AppTheme.ink)
          .width('100%').wordBreak(WordBreak.BREAK_WORD)
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding(11).backgroundColor(AppTheme.field).borderRadius(13)
    } else {
      Row() {
        Text(item.label).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
        Blank()
        Text(item.value).fontSize(item.emphasis ? 18 : AppTheme.bodySize)
          .fontWeight(item.emphasis ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(item.emphasis ? AppTheme.accent : AppTheme.ink)
          .constraintSize({ maxWidth: '68%' }).wordBreak(WordBreak.BREAK_WORD)
      }.width('100%')
    }
  }

  private librarySections(): HDUHelpDisplaySection[] {
    return this.campusSections.filter((section: HDUHelpDisplaySection) =>
      section.resource.startsWith('library_'));
  }

  private campusCardSections(): HDUHelpDisplaySection[] {
    return this.campusSections.filter((section: HDUHelpDisplaySection) =>
      section.resource === 'card_balance');
  }

  private otherLiveSections(): HDUHelpDisplaySection[] {
    const archived: string[] = ['identity', 'person', 'grades', 'card_balance'];
    return this.campusSections.filter((section: HDUHelpDisplaySection) =>
      !archived.includes(section.resource) && !section.resource.startsWith('library_'));
  }

  private libraryPrompts(): HDUHelpSuggestedPrompt[] {
    return this.campusPrompts.filter((suggestion: HDUHelpSuggestedPrompt) =>
      suggestion.resource !== null && suggestion.resource.startsWith('library_'));
  }

  private campusLifePrompts(): HDUHelpSuggestedPrompt[] {
    return this.campusPrompts.filter((suggestion: HDUHelpSuggestedPrompt) =>
      suggestion.resource !== 'identity' && suggestion.resource !== 'person' && suggestion.resource !== 'grades' &&
      (suggestion.resource === null || !suggestion.resource.startsWith('library_')));
  }

  @Builder
  private liveDataSection(section: HDUHelpDisplaySection) {
    Column({ space: 11 }) {
      Row() {
        Column({ space: 3 }) {
          Text(section.title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text(section.summary).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).wordBreak(WordBreak.BREAK_WORD)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Row() {
          AppIcon({ name: 'info', iconSize: 16, color: AppTheme.quiet })
        }.width(28).height(28).justifyContent(FlexAlign.Center)
          .backgroundColor(AppTheme.field).borderRadius(10)
      }.width('100%')
      ForEach(section.items, (item: HDUHelpDisplayItem) => {
        this.campusDataItem(item)
      }, (item: HDUHelpDisplayItem) => `${section.resource}-${item.label}`)
      EvidencePanel({ evidence: section.evidence ?? [], active: this.active })
    }.width('100%').padding(17).backgroundColor(AppTheme.surface).borderRadius(18)
  }

  @Builder
  private agentPromptBlock(prompts: HDUHelpSuggestedPrompt[], subtitle: string) {
    if (prompts.length > 0) {
      Column({ space: 10 }) {
        Text('继续问助手').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
        Text(subtitle).fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
        ForEach(prompts, (suggestion: HDUHelpSuggestedPrompt) => {
          Button() {
            Row({ space: 10 }) {
              Text(suggestion.title).fontSize(AppTheme.bodySize).fontColor(AppTheme.accent)
                .layoutWeight(1).wordBreak(WordBreak.BREAK_WORD)
              AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.accent })
            }.width('100%')
          }.width('100%').constraintSize({ minHeight: 48 }).padding({ left: 14, right: 14 })
            .backgroundColor(AppTheme.accentSoft).borderRadius(12)
            .onClick(() => this.onOpenAgent(suggestion.prompt))
        }, (suggestion: HDUHelpSuggestedPrompt) => suggestion.prompt_id)
      }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)
    }
  }

  @Builder
  private libraryView() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 4 }) {
          Text('我的图书馆').fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('到馆、借阅与座位使用记录').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('刷新').constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize).fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
          .borderRadius(12).onClick(() => this.loadCampusInfo())
      }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(20)

      if (this.campusInfoLoading) {
        FeedbackPanel({ kind: 'loading', title: '正在读取图书馆数据', message: '正在读取已连接的校园数据。' })
      } else if (this.campusInfoError.length > 0) {
        FeedbackPanel({ kind: 'error', title: '校园数据暂不可用', message: this.campusInfoError, actionLabel: '重试', onAction: () => this.loadCampusInfo() })
      } else if (!this.campusConfigured) {
        Column({ space: 8 }) {
          Text('尚未连接 HDUHelp').fontSize(AppTheme.sectionTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('请在个人设置中配置个人令牌，连接后可查看图书馆记录。')
            .fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
          Button('打开数据与连接').constraintSize({ minHeight: 48 }).onClick(() => this.onOpenProfile())
        }.width('100%').alignItems(HorizontalAlign.Start).padding(20)
          .backgroundColor(AppTheme.surface).borderRadius(18)
      } else {
        if (this.librarySections().length === 0) {
          Text('当前没有可展示的图书馆数据').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
            .padding(20).backgroundColor(AppTheme.surface).borderRadius(20)
        } else {
          ForEach(this.librarySections(), (section: HDUHelpDisplaySection) => {
            this.liveDataSection(section)
          }, (section: HDUHelpDisplaySection) => section.resource)
        }
        this.agentPromptBlock(this.libraryPrompts(), '结合到馆与借阅记录继续规划')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private campusCardView() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 4 }) {
          Text('校园卡余额').fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('余额与其他校园生活动态').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('刷新').constraintSize({ minHeight: 48 }).fontSize(AppTheme.metaSize).fontColor(AppTheme.accent).backgroundColor(AppTheme.accentSoft)
          .borderRadius(12).onClick(() => this.loadCampusInfo())
      }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(20)

      if (this.campusInfoLoading) {
        FeedbackPanel({ kind: 'loading', title: '正在读取校园卡数据', message: '正在读取已连接的校园数据。' })
      } else if (this.campusInfoError.length > 0) {
        FeedbackPanel({ kind: 'error', title: '校园数据暂不可用', message: this.campusInfoError, actionLabel: '重试', onAction: () => this.loadCampusInfo() })
      } else if (!this.campusConfigured) {
        FeedbackPanel({ kind: 'info', title: '尚未连接校园数据', message: '连接 HDUHelp 后可查询校园卡余额。',
          actionLabel: '打开数据与连接', onAction: () => this.onOpenProfile() })
      } else {
        if (this.campusCardSections().length === 0) {
          Text('当前没有可展示的校园卡数据').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary).width('100%')
            .padding(20).backgroundColor(AppTheme.surface).borderRadius(20)
        } else {
          ForEach(this.campusCardSections(), (section: HDUHelpDisplaySection) => {
            this.liveDataSection(section)
          }, (section: HDUHelpDisplaySection) => section.resource)
        }

        if (this.otherLiveSections().length > 0) {
          Text('其他校园服务').fontSize(AppTheme.bodySize).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
          ForEach(this.otherLiveSections(), (section: HDUHelpDisplaySection) => {
            this.liveDataSection(section)
          }, (section: HDUHelpDisplaySection) => section.resource)
        }
        this.agentPromptBlock(this.campusLifePrompts(), '结合余额、考试与提醒继续规划')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button() {
          AppIcon({ name: 'back', iconSize: 22, color: AppTheme.accent })
        }.width(48).constraintSize({ minHeight: 48 }).backgroundColor(AppTheme.surface)
          .borderRadius(22).accessibilityText('返回上一页').onClick(() => this.onBack())
        Column({ space: 3 }) {
          Text('校园服务').fontSize(AppTheme.pageTitle).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('查看教室与已连接的校园信息').fontSize(AppTheme.metaSize).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding({ left: 18, right: 18, top: 14, bottom: 12 })

      Row({ space: 6 }) {
        this.serviceTab(0, '空闲教室')
        this.serviceTab(1, '寝室电费')
        this.serviceTab(2, '图书馆')
        this.serviceTab(3, '校园卡')
      }.width('90%').alignSelf(ItemAlign.Center).padding(4)
        .backgroundColor(AppTheme.separator).borderRadius(14)

      Scroll(this.scrollers[this.activeService]) {
        Column() {
          if (this.activeService === 0) {
            this.classroomView()
          } else if (this.activeService === 1) {
            this.electricityView()
          } else if (this.activeService === 2) {
            this.libraryView()
          } else {
            this.campusCardView()
          }
        }.width('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
          .padding({ left: 18, right: 18, top: 16, bottom: 32 })
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(AppTheme.bg)
  }
}
