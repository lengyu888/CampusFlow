import {
  ClassroomItem,
  ClassroomSearchResponse,
  ClassroomUsageItem,
  ClassroomUsageResponse,
  ElectricityHistoryItem,
  ElectricityOverview
} from '../model/ApiModels';
import { CampusFlowApi } from '../services/CampusFlowApi';

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
    Button(label)
      .layoutWeight(1)
      .height(40)
      .fontSize(13)
      .fontWeight(this.activeService === index ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.activeService === index ? '#FFFFFF' : '#596174')
      .backgroundColor(this.activeService === index ? '#171A22' : Color.Transparent)
      .borderRadius(13)
      .onClick(() => this.activeService = index)
  }

  @Builder
  private classroomCard(room: ClassroomItem) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(room.location_name).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#171A22')
        Text(room.building_name).fontSize(11).fontColor('#7B8292')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column({ space: 4 }) {
        Text(room.self_study ? '可自习' : '空闲').fontSize(11).fontWeight(FontWeight.Bold)
          .fontColor(room.self_study ? '#087D5B' : '#315BFF')
        Text(room.capacity > 0 ? `${room.capacity} 座` : '容量未知').fontSize(10).fontColor('#9096A4')
      }.alignItems(HorizontalAlign.End)
      Text('›').fontSize(22).fontColor('#A4AAB7')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .onClick(() => this.loadUsage(room))
  }

  @Builder
  private classroomView() {
    Column({ space: 14 }) {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 3 }) {
            Text('找一间现在能用的教室').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#171A22')
            Text('时间由系统自动判断，也可按节次筛选').fontSize(11).fontColor('#7B8292')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('刷新').height(34).fontSize(11).fontColor('#315BFF').backgroundColor('#E9EEFF')
            .borderRadius(12).onClick(() => this.loadClassrooms())
        }.width('100%')

        Select(this.buildingLabels.map((label: string) => new CampusServiceOption(label)))
          .selected(this.selectedBuilding)
          .value(this.buildingLabels[this.selectedBuilding])
          .fontColor('#171A22')
          .backgroundColor('#F3F5F9')
          .optionBgColor('#FFFFFF').optionFontColor('#171A22')
          .selectedOptionBgColor('#E9EEFF').selectedOptionFontColor('#315BFF')
          .borderRadius(14)
          .width('100%')
          .onSelect((index: number) => {
            this.selectedBuilding = index;
            this.loadClassrooms();
          })

        Row({ space: 6 }) {
          ForEach(this.periodLabels, (label: string, index: number) => {
            Button(label).layoutWeight(1).height(34).fontSize(10)
              .fontColor(this.selectedPeriod === index ? '#FFFFFF' : '#596174')
              .backgroundColor(this.selectedPeriod === index ? '#315BFF' : '#F3F5F9')
              .borderRadius(11)
              .onClick(() => {
                this.selectedPeriod = index;
                this.loadClassrooms();
              })
          }, (label: string) => label)
        }.width('100%')
      }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(24)

      if (this.usageTitle.length > 0) {
        Column({ space: 10 }) {
          Row() {
            Column({ space: 3 }) {
              Text(this.usageTitle).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              Text('本学期占用安排').fontSize(11).fontColor('#AEB9D8')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Text('×').fontSize(20).fontColor('#FFFFFF').onClick(() => this.usageTitle = '')
          }.width('100%')
          if (this.usageLoading) {
            Text('正在读取占用情况…').fontSize(12).fontColor('#AEB9D8').width('100%')
          } else if (this.usageItems.length === 0) {
            Text('本学期没有查到占用记录').fontSize(12).fontColor('#AEB9D8').width('100%')
          } else {
            ForEach(this.usageItems.slice(0, 8), (item: ClassroomUsageItem) => {
              Row() {
                Text(`第${item.week}周 · ${this.weekdayName(item.weekday)} · 第${item.section}节`)
                  .fontSize(11).fontColor('#FFFFFF').layoutWeight(1)
                Text(item.course_name).fontSize(11).fontColor('#AEB9D8').maxLines(1)
              }.width('100%')
            }, (item: ClassroomUsageItem) => `${item.week}-${item.weekday}-${item.section}-${item.course_name}`)
          }
        }.width('100%').padding(18).backgroundColor('#171A22').borderRadius(22)
      }

      Row() {
        Text(this.classroomLabel).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#171A22')
        Blank()
        Text(`${this.classroomTotal} 间可用`).fontSize(11).fontColor('#315BFF')
      }.width('100%')

      if (this.classroomLoading) {
        Text('正在查询 HDUHelp 实时教室状态…').fontSize(12).fontColor('#7B8292').width('100%')
          .padding(18).backgroundColor('#FFFFFF').borderRadius(18)
      } else if (this.classroomError.length > 0) {
        Text(this.classroomError).fontSize(12).fontColor('#D33D3D').width('100%')
          .padding(18).backgroundColor('#FFF0F0').borderRadius(18)
      } else if (this.classrooms.length === 0) {
        Text('当前筛选条件下没有空闲教室').fontSize(13).fontColor('#7B8292').width('100%')
          .padding(20).backgroundColor('#FFFFFF').borderRadius(18)
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
        Text('正在读取寝室电费…').fontSize(13).fontColor('#7B8292').width('100%')
          .padding(20).backgroundColor('#FFFFFF').borderRadius(20)
      } else if (this.electricityError.length > 0) {
        Text(this.electricityError).fontSize(12).fontColor('#D33D3D').width('100%')
          .padding(18).backgroundColor('#FFF0F0').borderRadius(18)
      } else if (!this.electricityData.bound) {
        Column({ space: 8 }) {
          Text('尚未绑定寝室电表').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Text('请先在 HDUHelp 中完成电表绑定，再返回刷新。').fontSize(12).fontColor('#7B8292')
          Button('重新检查').height(40).fontColor('#FFFFFF').backgroundColor('#315BFF').borderRadius(13)
            .onClick(() => this.loadElectricity())
        }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor('#FFFFFF').borderRadius(22)
      } else {
        Column({ space: 18 }) {
          Row() {
            Column({ space: 4 }) {
              Text('当前电费余额').fontSize(12).fontColor('#B9C4E4')
              Row({ space: 5 }) {
                Text('¥').fontSize(21).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                Text(this.balanceText()).fontSize(42).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              }
              Text(this.electricityData.room_name).fontSize(13).fontColor('#FFFFFF')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Column({ space: 5 }) {
              Text('日均消耗').fontSize(10).fontColor('#B9C4E4')
              Text(`¥${this.electricityData.daily_average.length > 0 ? this.electricityData.daily_average : '--'}`)
                .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#7EE1BE')
              Text(this.electricityData.meter_hint).fontSize(9).fontColor('#8490B3')
            }.alignItems(HorizontalAlign.End)
          }.width('100%')
          Row() {
            Text(`更新于 ${this.updatedText()}`).fontSize(10).fontColor('#8490B3').layoutWeight(1)
            Button('刷新余额').height(34).fontSize(10).fontColor('#171A22').backgroundColor('#FFFFFF')
              .borderRadius(11).onClick(() => this.loadElectricity())
          }.width('100%')
        }.width('100%').padding(22).backgroundColor('#171A22').borderRadius(26)

        Column({ space: 12 }) {
          Row() {
            Text('近 14 天余额').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#171A22')
            Blank()
            Text('HDUHelp 实时数据').fontSize(10).fontColor('#315BFF')
          }.width('100%')
          if (this.electricityData.history.length === 0) {
            Text('暂无历史记录').fontSize(12).fontColor('#7B8292').width('100%')
          } else {
            ForEach(this.electricityData.history, (item: ElectricityHistoryItem) => {
              Row() {
                Text(item.date.slice(5)).fontSize(12).fontColor('#7B8292').width(52)
                Text(`余额 ¥${item.balance}`).fontSize(13).fontWeight(FontWeight.Medium)
                  .fontColor('#171A22').layoutWeight(1)
                Text(item.change === '-' ? '首日' : `${item.change} 元`).fontSize(11)
                  .fontColor(item.change.startsWith('-') ? '#E05A47' : '#087D5B')
              }.width('100%').padding({ top: 8, bottom: 8 })
            }, (item: ElectricityHistoryItem) => item.date)
          }
        }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(22)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button('‹').width(44).height(44).fontSize(26).fontColor('#171A22').backgroundColor('#FFFFFF')
          .borderRadius(15).onClick(() => this.onBack())
        Column({ space: 3 }) {
          Text('校园服务').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#171A22')
          Text('实时教室与生活数据').fontSize(11).fontColor('#7B8292')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('LIVE').fontSize(10).fontWeight(FontWeight.Bold).fontColor('#087D5B')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 }).backgroundColor('#E5F7F0').borderRadius(10)
      }.width('100%').padding({ left: 18, right: 18, top: 14, bottom: 12 })

      Row({ space: 6 }) {
        this.serviceTab(0, '空闲教室')
        this.serviceTab(1, '寝室电费')
      }.width('100%').padding({ left: 22, right: 22, top: 4, bottom: 4 })
        .backgroundColor('#E9ECF3').borderRadius(17)

      Scroll() {
        Column() {
          if (this.activeService === 0) {
            this.classroomView()
          } else {
            this.electricityView()
          }
        }.width('100%').padding({ left: 18, right: 18, top: 16, bottom: 40 })
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}
