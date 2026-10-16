import {
  ClassroomItem,
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
  onBack: () => void = () => {};
  onOpenAgent: (prompt: string) => void = () => {};
  @State private activeService: number = 0;
  @State private selectedBuilding: number = 0;
  @State private selectedPeriod: number = 0;
  @State private classrooms: ClassroomItem[] = [];
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
    this.loadClassrooms();
    this.loadElectricity();
    this.loadCampusInfo();
  }

  private periodSections(): number[] {
    if (this.selectedPeriod === 1) return [1, 2];
    if (this.selectedPeriod === 2) return [3, 4, 5];
    if (this.selectedPeriod === 3) return [6, 7, 8, 9];
    if (this.selectedPeriod === 4) return [10, 11, 12, 13];
    return [];
  }

  private async loadClassrooms(): Promise<void> {
    this.classroomLoading = true;
    this.classroomError = '';
    this.usageTitle = '';
    this.usageItems = [];
    try {
      const result: ClassroomSearchResponse = await new CampusFlowApi(this.baseUrl, this.token)
        .unusedClassrooms(this.buildingIds[this.selectedBuilding], this.periodSections());
      this.classrooms = result.items;
      this.classroomTotal = result.total;
      this.classroomLabel = result.query_label;
    } catch (error) {
      this.classroomError = `空闲教室加载失败：${error}`;
      this.classrooms = [];
    } finally {
      this.classroomLoading = false;
    }
  }

  private async loadUsage(room: ClassroomItem): Promise<void> {
    this.usageTitle = room.location_name;
    this.usageLoading = true;
    this.usageItems = [];
    try {
      const result: ClassroomUsageResponse = await new CampusFlowApi(this.baseUrl, this.token)
        .classroomUsage(room.location_id);
      this.usageItems = result.items;
    } catch (error) {
      this.classroomError = `教室占用情况加载失败：${error}`;
      this.usageTitle = '';
    } finally {
      this.usageLoading = false;
    }
  }

  private async loadElectricity(): Promise<void> {
    this.electricityLoading = true;
    this.electricityError = '';
    try {
      this.electricityData = await new CampusFlowApi(this.baseUrl, this.token).electricity();
    } catch (error) {
      this.electricityError = `电费数据加载失败：${error}`;
    } finally {
      this.electricityLoading = false;
    }
  }

  private async loadCampusInfo(): Promise<void> {
    this.campusInfoLoading = true;
    this.campusInfoError = '';
    try {
      const result: HDUHelpDataResponse = await new CampusFlowApi(this.baseUrl, this.token).hduHelpData();
      this.campusConfigured = result.status.configured;
      this.campusSections = result.sections;
      this.campusPrompts = result.suggested_prompts;
    } catch (error) {
      this.campusInfoError = `校园生活数据加载失败：${error}`;
      this.campusSections = [];
      this.campusPrompts = [];
    } finally {
      this.campusInfoLoading = false;
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
    if (this.electricityData.balance_updated_at === null) return '暂无更新时间';
    return this.electricityData.balance_updated_at.slice(0, 16).replace('T', ' ');
  }

  @Builder
  private serviceTab(index: number, label: string) {
    Button() {
      Text(label).fontSize(13)
        .fontWeight(this.activeService === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeService === index ? AppTheme.ink : AppTheme.secondary)
        .maxLines(1)
    }
      .layoutWeight(1)
      .height(44)
      .padding({ left: 4, right: 4 })
      .backgroundColor(this.activeService === index ? AppTheme.surface : Color.Transparent)
      .borderRadius(10)
      .onClick(() => {
        this.getUIContext().animateTo({ duration: AppTheme.motion(180), curve: Curve.EaseOut }, () => {
          this.activeService = index;
        });
      })
  }

  @Builder
  private classroomCard(room: ClassroomItem) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(room.location_name).fontSize(16).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
        Text(room.building_name).fontSize(13).fontColor(AppTheme.secondary)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column({ space: 4 }) {
        Text(room.self_study ? '可自习' : '空闲').fontSize(13).fontWeight(FontWeight.Bold)
          .fontColor(room.self_study ? AppTheme.green : AppTheme.blue)
        Text(room.capacity > 0 ? `${room.capacity} 座` : '容量未知').fontSize(12).fontColor(AppTheme.muted)
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
            Text('找一间现在能用的教室').fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Text('时间由系统自动判断，也可按节次筛选').fontSize(13).fontColor(AppTheme.secondary)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('刷新').height(44).fontSize(13).fontColor(AppTheme.blue).backgroundColor(AppTheme.blueSoft)
            .borderRadius(12).onClick(() => this.loadClassrooms())
        }.width('100%')

        Select(this.buildingLabels.map((label: string) => new CampusServiceOption(label)))
          .selected(this.selectedBuilding)
          .value(this.buildingLabels[this.selectedBuilding])
          .fontColor(AppTheme.ink)
          .backgroundColor(AppTheme.field)
          .optionBgColor(AppTheme.surface).optionFontColor(AppTheme.ink)
          .selectedOptionBgColor(AppTheme.blueSoft).selectedOptionFontColor(AppTheme.blue)
          .borderRadius(14)
          .width('100%')
          .onSelect((index: number) => {
            this.selectedBuilding = index;
            this.loadClassrooms();
          })

        Row({ space: 6 }) {
          ForEach(this.periodLabels, (label: string, index: number) => {
            Button(label).layoutWeight(1).height(44).fontSize(12)
              .fontColor(this.selectedPeriod === index ? AppTheme.surface : AppTheme.secondary)
              .backgroundColor(this.selectedPeriod === index ? AppTheme.blue : AppTheme.field)
              .borderRadius(11)
              .onClick(() => {
                this.getUIContext().animateTo({ duration: AppTheme.motion(160), curve: Curve.EaseOut }, () => {
                  this.selectedPeriod = index;
                });
                this.loadClassrooms();
              })
          }, (label: string) => label)
        }.width('100%')
      }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(20)

      if (this.usageTitle.length > 0) {
        Column({ space: 10 }) {
          Row() {
            Column({ space: 3 }) {
              Text(this.usageTitle).fontSize(16).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              Text('本学期占用安排').fontSize(13).fontColor(AppTheme.secondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('关闭').height(44).fontSize(14).fontColor(AppTheme.blue)
              .backgroundColor(Color.Transparent).onClick(() => this.usageTitle = '')
          }.width('100%')
          if (this.usageLoading) {
            Text('正在读取占用情况…').fontSize(14).fontColor(AppTheme.secondary).width('100%')
          } else if (this.usageItems.length === 0) {
            Text('本学期没有查到占用记录').fontSize(14).fontColor(AppTheme.secondary).width('100%')
          } else {
            ForEach(this.usageItems.slice(0, 8), (item: ClassroomUsageItem) => {
              Row() {
                Text(`第${item.week}周 · ${this.weekdayName(item.weekday)} · 第${item.section}节`)
                  .fontSize(13).fontColor(AppTheme.ink).layoutWeight(1)
                Text(item.course_name).fontSize(13).fontColor(AppTheme.secondary).maxLines(1)
              }.width('100%')
            }, (item: ClassroomUsageItem) => `${item.week}-${item.weekday}-${item.section}-${item.course_name}`)
          }
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)
      }

      Row() {
        Text(this.classroomLabel).fontSize(15).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
        Blank()
        Text(`${this.classroomTotal} 间可用`).fontSize(13).fontColor(AppTheme.blue)
      }.width('100%')

      if (this.classroomLoading) {
        Text('正在查询 HDUHelp 实时教室状态…').fontSize(14).fontColor(AppTheme.secondary).width('100%')
          .padding(18).backgroundColor(AppTheme.surface).borderRadius(18)
      } else if (this.classroomError.length > 0) {
        Text(this.classroomError).fontSize(14).fontColor(AppTheme.red).width('100%')
          .padding(18).backgroundColor(AppTheme.bg).borderRadius(18)
      } else if (this.classrooms.length === 0) {
        Text('当前筛选条件下没有空闲教室').fontSize(15).fontColor(AppTheme.secondary).width('100%')
          .padding(20).backgroundColor(AppTheme.surface).borderRadius(18)
      } else {
        ForEach(this.classrooms.slice(0, 20), (room: ClassroomItem) => {
          this.classroomCard(room)
        }, (room: ClassroomItem) => room.location_id)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private electricityView() {
    Column({ space: 14 }) {
      if (this.electricityLoading) {
        Text('正在读取寝室电费…').fontSize(15).fontColor(AppTheme.secondary).width('100%')
          .padding(20).backgroundColor(AppTheme.surface).borderRadius(20)
      } else if (this.electricityError.length > 0) {
        Text(this.electricityError).fontSize(14).fontColor(AppTheme.red).width('100%')
          .padding(18).backgroundColor(AppTheme.bg).borderRadius(18)
      } else if (!this.electricityData.bound) {
        Column({ space: 8 }) {
          Text('尚未绑定寝室电表').fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('请先在 HDUHelp 中完成电表绑定，再返回刷新。').fontSize(14).fontColor(AppTheme.secondary)
          Button('重新检查').height(44).fontColor(AppTheme.surface).backgroundColor(AppTheme.blue).borderRadius(13)
            .onClick(() => this.loadElectricity())
        }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor(AppTheme.surface).borderRadius(18)
      } else {
        Column({ space: 18 }) {
          Row() {
            Column({ space: 4 }) {
              Text('当前电费余额').fontSize(14).fontColor(AppTheme.secondary)
              Row({ space: 5 }) {
                Text('¥').fontSize(21).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
                Text(this.balanceText()).fontSize(40).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
              }
              Text(this.electricityData.room_name).fontSize(15).fontColor(AppTheme.secondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Column({ space: 5 }) {
              Text('日均消耗').fontSize(12).fontColor(AppTheme.secondary)
              Text(`¥${this.electricityData.daily_average.length > 0 ? this.electricityData.daily_average : '--'}`)
                .fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.green)
              Text(this.electricityData.meter_hint).fontSize(11).fontColor(AppTheme.secondary)
            }.alignItems(HorizontalAlign.End)
          }.width('100%')
          Row() {
            Text(`更新于 ${this.updatedText()}`).fontSize(12).fontColor(AppTheme.secondary).layoutWeight(1)
            Button('刷新余额').height(44).fontSize(14).fontColor(AppTheme.blue).backgroundColor(AppTheme.blueSoft)
              .borderRadius(11).onClick(() => this.loadElectricity())
          }.width('100%')
        }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(20)

        Column({ space: 12 }) {
          Row() {
            Text('近 14 天余额').fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
            Blank()
            Text('HDUHelp 实时数据').fontSize(12).fontColor(AppTheme.blue)
          }.width('100%')
          if (this.electricityData.history.length === 0) {
            Text('暂无历史记录').fontSize(14).fontColor(AppTheme.secondary).width('100%')
          } else {
            ForEach(this.electricityData.history, (item: ElectricityHistoryItem) => {
              Row() {
                Text(item.date.slice(5)).fontSize(14).fontColor(AppTheme.secondary).width(52)
                Text(`余额 ¥${item.balance}`).fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor(AppTheme.ink).layoutWeight(1)
                Text(item.change === '-' ? '首日' : `${item.change} 元`).fontSize(13)
                  .fontColor(item.change.startsWith('-') ? AppTheme.orange : AppTheme.green)
              }.width('100%').padding({ top: 8, bottom: 8 })
            }, (item: ElectricityHistoryItem) => item.date)
          }
        }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(18)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private campusDataItem(item: HDUHelpDisplayItem) {
    if (item.label.length > 12 || item.value.length > 22) {
      Column({ space: 5 }) {
        Text(item.label).fontSize(13).fontColor(AppTheme.secondary).width('100%')
        Text(item.value).fontSize(item.emphasis ? 17 : 15)
          .fontWeight(item.emphasis ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(item.emphasis ? AppTheme.blue : AppTheme.ink)
          .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding(11).backgroundColor(AppTheme.field).borderRadius(13)
    } else {
      Row() {
        Text(item.label).fontSize(13).fontColor(AppTheme.secondary)
        Blank()
        Text(item.value).fontSize(item.emphasis ? 17 : 15)
          .fontWeight(item.emphasis ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(item.emphasis ? AppTheme.blue : AppTheme.ink)
          .constraintSize({ maxWidth: '68%' }).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
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
          Text(section.summary).fontSize(13).fontColor(AppTheme.secondary).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Row() {
          AppIcon({ name: 'check', iconSize: 16, color: AppTheme.green })
        }.width(28).height(28).justifyContent(FlexAlign.Center)
          .backgroundColor(AppTheme.greenSoft).borderRadius(10)
      }.width('100%')
      ForEach(section.items, (item: HDUHelpDisplayItem) => {
        this.campusDataItem(item)
      }, (item: HDUHelpDisplayItem) => `${section.resource}-${item.label}`)
    }.width('100%').padding(17).backgroundColor(AppTheme.surface).borderRadius(18)
  }

  @Builder
  private agentPromptBlock(prompts: HDUHelpSuggestedPrompt[], subtitle: string) {
    if (prompts.length > 0) {
      Column({ space: 10 }) {
        Text('继续问 Agent').fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
        Text(subtitle).fontSize(13).fontColor(AppTheme.secondary).width('100%')
        ForEach(prompts.slice(0, 4), (suggestion: HDUHelpSuggestedPrompt) => {
          Button() {
            Row({ space: 10 }) {
              Text(suggestion.title).fontSize(15).fontColor(AppTheme.blue)
                .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              AppIcon({ name: 'chevron', iconSize: 16, color: AppTheme.blue })
            }.width('100%')
          }.width('100%').height(48).padding({ left: 14, right: 14 })
            .backgroundColor(AppTheme.blueSoft).borderRadius(12)
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
          Text('到馆、借阅与座位使用记录').fontSize(13).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('刷新').height(44).fontSize(13).fontColor(AppTheme.blue).backgroundColor(AppTheme.blueSoft)
          .borderRadius(12).onClick(() => this.loadCampusInfo())
      }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(20)

      if (this.campusInfoLoading) {
        Text('正在同步图书馆数据…').fontSize(15).fontColor(AppTheme.secondary).width('100%')
          .padding(20).backgroundColor(AppTheme.surface).borderRadius(20)
      } else if (this.campusInfoError.length > 0) {
        Text(this.campusInfoError).fontSize(14).fontColor(AppTheme.red).width('100%')
          .padding(18).backgroundColor(AppTheme.bg).borderRadius(18)
      } else if (!this.campusConfigured) {
        Column({ space: 8 }) {
          Text('尚未连接 HDUHelp').fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('请前往“我的”配置个人令牌，连接后可查看图书馆记录。')
            .fontSize(14).fontColor(AppTheme.secondary)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(20)
          .backgroundColor(AppTheme.surface).borderRadius(18)
      } else {
        if (this.librarySections().length === 0) {
          Text('当前没有可展示的图书馆数据').fontSize(14).fontColor(AppTheme.secondary).width('100%')
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
          Text('余额与其他校园生活动态').fontSize(13).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('刷新').height(44).fontSize(13).fontColor(AppTheme.blue).backgroundColor(AppTheme.blueSoft)
          .borderRadius(12).onClick(() => this.loadCampusInfo())
      }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(20)

      if (this.campusInfoLoading) {
        Text('正在同步校园卡数据…').fontSize(15).fontColor(AppTheme.secondary).width('100%')
          .padding(20).backgroundColor(AppTheme.surface).borderRadius(20)
      } else if (this.campusInfoError.length > 0) {
        Text(this.campusInfoError).fontSize(14).fontColor(AppTheme.red).width('100%')
          .padding(18).backgroundColor(AppTheme.bg).borderRadius(18)
      } else if (!this.campusConfigured) {
        Text('请先在“我的”连接 HDUHelp，随后即可查询校园卡余额。')
          .fontSize(14).fontColor(AppTheme.secondary).width('100%')
          .padding(20).backgroundColor(AppTheme.surface).borderRadius(20)
      } else {
        if (this.campusCardSections().length === 0) {
          Text('当前没有可展示的校园卡数据').fontSize(14).fontColor(AppTheme.secondary).width('100%')
            .padding(20).backgroundColor(AppTheme.surface).borderRadius(20)
        } else {
          ForEach(this.campusCardSections(), (section: HDUHelpDisplaySection) => {
            this.liveDataSection(section)
          }, (section: HDUHelpDisplaySection) => section.resource)
        }

        if (this.otherLiveSections().length > 0) {
          Text('其他校园服务').fontSize(16).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink).width('100%')
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
          AppIcon({ name: 'back', iconSize: 22, color: AppTheme.blue })
        }.width(44).height(44).backgroundColor(AppTheme.surface)
          .borderRadius(22).onClick(() => this.onBack())
        Column({ space: 3 }) {
          Text('校园服务').fontSize(28).fontWeight(FontWeight.Bold).fontColor(AppTheme.ink)
          Text('实时教室与生活数据').fontSize(13).fontColor(AppTheme.secondary)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding({ left: 18, right: 18, top: 14, bottom: 12 })

      Row({ space: 6 }) {
        this.serviceTab(0, '空闲教室')
        this.serviceTab(1, '寝室电费')
        this.serviceTab(2, '图书馆')
        this.serviceTab(3, '校园卡')
      }.width('90%').alignSelf(ItemAlign.Center).padding(4)
        .backgroundColor(AppTheme.separator).borderRadius(14)

      Scroll() {
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
