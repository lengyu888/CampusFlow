import { CampusDataPlace, CampusDataSnapshot, CampusRoute, DataEvidence } from '../model/ApiModels';
import { RouteMap } from '../components/RouteMap';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { AppIcon } from '../components/AppIcon';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { EvidencePanel } from '../components/EvidencePanel';
import { openingStatus } from '../utils/EvidencePresentation';
import { CourseRouteIntent, CoursePlaceMatch, matchCoursePlace } from '../utils/CourseRouteIntent';

interface RouteSelectionState {
  key: string;
  intentKey: string;
  originId: string;
  destinationId: string;
}

class CampusSelectOption implements SelectOption {
  value: ResourceStr;

  constructor(value: string) {
    this.value = value;
  }
}

@Component
export struct RoutePage {
  @StorageLink('campusflowThemePalette') private palette: ThemePalette = themePalette('paper-green');
  @Watch('accountChanged') @Prop baseUrl: string;
  @Watch('accountChanged') @Prop token: string;
  @Watch('accountChanged') @Prop routeScope: string = '';
  @Watch('contextChanged') @Prop routeContextKey: string = '0';
  @Watch('contextChanged') @Prop courseIntent: CourseRouteIntent | null = null;
  @Watch('activeChanged') @Prop active: boolean = true;
  onBack: () => void = () => {};
  @State private places: CampusDataPlace[] = [];
  @State private packageEvidence: DataEvidence[] = [];
  @State private originIndex: number = -1;
  @State private destinationIndex: number = -1;
  @State private courseMatch: CoursePlaceMatch | null = null;
  @State private visibleCourse: CourseRouteIntent | null = null;
  @State private route: CampusRoute | null = null;
  @State private loading: boolean = true;
  @State private routeLoading: boolean = false;
  @State private errorText: string = '';
  @State private placesError: string = '';
  private scroller: Scroller = new Scroller();
  private pageActive: boolean = true;
  private placesRevision: number = 0;
  private routeRevision: number = 0;
  private placesLoaded: boolean = false;
  private snapshot: CampusDataSnapshot | null = null;
  private boundScope: string = '';
  private boundBaseUrl: string = '';
  private boundToken: string = '';
  private activeContextKey: string = '';
  private appliedIntentKey: string = '';
  private pendingOriginId: string = '';
  private pendingDestinationId: string = '';
  private preselectCourse: boolean = false;
  private contextRevision: number = 0;
  private selections: RouteSelectionState[] = [];

  aboutToAppear(): void {
    this.pageActive = true;
    this.accountChanged();
    this.activeChanged();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.contextRevision++;
    this.invalidateRequests();
  }

  private accountChanged(): void {
    if (this.boundScope === this.routeScope && this.boundBaseUrl === this.baseUrl && this.boundToken === this.token) { return; }
    this.invalidateRequests(); this.contextRevision++;
    this.boundScope = this.routeScope; this.boundBaseUrl = this.baseUrl; this.boundToken = this.token;
    this.selections = []; this.places = []; this.packageEvidence = []; this.snapshot = null;
    this.originIndex = -1; this.destinationIndex = -1; this.pendingOriginId = ''; this.pendingDestinationId = '';
    this.courseMatch = null; this.visibleCourse = null; this.route = null; this.placesLoaded = false; this.placesError = ''; this.errorText = '';
    this.activeContextKey = ''; this.appliedIntentKey = ''; this.contextChanged();
  }

  private contextChanged(): void {
    const revision = ++this.contextRevision;
    // Coalesce the parent's context-key and intent prop updates before caching either root.
    Promise.resolve().then(() => {
      if (revision !== this.contextRevision || !this.pageActive || !this.active) { return; }
      this.applyContext();
      if (!this.placesLoaded) { this.loadPlaces(); }
    });
  }

  private intentKey(): string { return this.courseIntent === null ? 'generic' : `course-${this.courseIntent.requestId}`; }

  private rememberSelection(): void {
    if (this.activeContextKey.length === 0 || this.boundScope.length === 0) { return; }
    const selection: RouteSelectionState = { key: this.activeContextKey, intentKey: this.appliedIntentKey,
      originId: this.places[this.originIndex]?.place_id ?? this.pendingOriginId,
      destinationId: this.places[this.destinationIndex]?.place_id ?? this.pendingDestinationId };
    this.selections = this.selections.filter((item: RouteSelectionState) => item.key !== selection.key).concat(selection);
  }

  private applyContext(): void {
    if (this.boundScope !== this.routeScope || this.boundBaseUrl !== this.baseUrl || this.boundToken !== this.token) { this.accountChanged(); }
    const intentKey = this.intentKey();
    if (this.activeContextKey === this.routeContextKey && this.appliedIntentKey === intentKey) { return; }
    this.rememberSelection();
    this.invalidateRequests();
    this.activeContextKey = this.routeContextKey; this.appliedIntentKey = intentKey;
    this.visibleCourse = this.routeScope.length > 0 ? this.courseIntent : null;
    const saved = this.selections.find((item: RouteSelectionState) => item.key === this.activeContextKey && item.intentKey === intentKey);
    this.pendingOriginId = saved?.originId ?? ''; this.pendingDestinationId = saved?.destinationId ?? '';
    this.originIndex = this.places.findIndex((place: CampusDataPlace) => place.place_id === this.pendingOriginId);
    this.destinationIndex = this.places.findIndex((place: CampusDataPlace) => place.place_id === this.pendingDestinationId);
    this.preselectCourse = saved === undefined && this.courseIntent !== null;
    this.updateCourseMatch(); this.invalidateRoute();
  }

  private updateCourseMatch(): void {
    this.courseMatch = this.visibleCourse !== null && this.snapshot !== null ? matchCoursePlace(this.visibleCourse, this.snapshot) : null;
    if (this.preselectCourse && this.courseMatch?.status === 'unique') {
      const id = this.courseMatch.candidateIds[0];
      this.destinationIndex = this.places.findIndex((place: CampusDataPlace) => place.place_id === id);
      this.pendingDestinationId = id;
      this.preselectCourse = false;
    }
  }

  private invalidateRequests(): void {
    this.placesRevision++;
    this.routeRevision++;
    this.loading = false;
    this.routeLoading = false;
  }

  private activeChanged(): void {
    if (!this.active) { this.rememberSelection(); this.invalidateRequests(); return; }
    if (!this.pageActive) { return; }
    this.applyContext(); this.loadPlaces();
  }

  private async loadPlaces(): Promise<void> {
    if (!this.active || !this.pageActive || this.routeScope.length === 0 || this.token.length === 0 || this.loading && this.placesRevision > 0) { return; }
    const revision = ++this.placesRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    const scope = this.routeScope;
    const originId = this.places[this.originIndex]?.place_id ?? this.pendingOriginId;
    const destinationId = this.places[this.destinationIndex]?.place_id ?? this.pendingDestinationId;
    this.loading = true;
    this.placesError = '';
    try {
      const data: CampusDataSnapshot = await new CampusFlowApi(baseUrl, token).campusData();
      if (!this.current(revision, token, baseUrl, scope, false)) { return; }
      if (!data.package || typeof data.package.package_id !== 'string' || typeof data.package.version !== 'string' ||
        typeof data.package.school !== 'string' || typeof data.package.campus !== 'string' || !Array.isArray(data.places) ||
        data.places.some((place: CampusDataPlace) => typeof place.place_id !== 'string' || place.place_id.length === 0 ||
          typeof place.name !== 'string' || typeof place.zone !== 'string' || !Array.isArray(place.aliases) ||
          place.aliases.some((alias: string) => typeof alias !== 'string')) ||
        data.places.some((place: CampusDataPlace, index: number) => data.places.findIndex((item: CampusDataPlace) => item.place_id === place.place_id) !== index)) {
        throw new Error('invalid places');
      }
      this.snapshot = data;
      this.places = data.places;
      this.packageEvidence = data.package.evidence ?? [];
      this.placesLoaded = true;
      const origin = this.places.findIndex((item: CampusDataPlace) => item.place_id === originId);
      const destination = this.places.findIndex((item: CampusDataPlace) => item.place_id === destinationId);
      this.originIndex = origin; this.destinationIndex = destination;
      this.pendingOriginId = origin >= 0 ? originId : ''; this.pendingDestinationId = destination >= 0 ? destinationId : '';
      this.updateCourseMatch(); this.rememberSelection();
      this.invalidateRoute();
    } catch {
      if (this.current(revision, token, baseUrl, scope, false)) {
        this.placesError = '暂时无法读取校园地点，请检查连接后重试。';
      }
    } finally {
      if (this.current(revision, token, baseUrl, scope, false)) { this.loading = false; }
    }
  }

  private options(): Array<SelectOption> {
    return this.places.map((place: CampusDataPlace) => new CampusSelectOption(place.name));
  }

  private current(revision: number, token: string, baseUrl: string, scope: string, route: boolean): boolean {
    return this.pageActive && this.active && scope.length > 0 && scope === this.routeScope && scope === this.boundScope &&
      token === this.token && baseUrl === this.baseUrl && revision === (route ? this.routeRevision : this.placesRevision);
  }

  private invalidateRoute(): void {
    this.routeRevision++;
    this.route = null;
    this.routeLoading = false;
    this.errorText = '';
  }

  private choosePlace(index: number, origin: boolean): void {
    if (!this.active || !this.pageActive || this.routeScope.length === 0 || this.loading || this.placesError.length > 0) { return; }
    if (!Number.isInteger(index) || index < 0 || index >= this.places.length) { return; }
    if (origin) { this.originIndex = index; this.pendingOriginId = this.places[index].place_id; }
    else { this.destinationIndex = index; this.pendingDestinationId = this.places[index].place_id; this.preselectCourse = false; }
    this.rememberSelection();
    this.invalidateRoute();
  }

  private swap(): void {
    if (!this.active || !this.pageActive || this.loading || this.originIndex < 0 || this.destinationIndex < 0) { return; }
    const previous = this.originIndex;
    this.originIndex = this.destinationIndex;
    this.destinationIndex = previous;
    this.pendingOriginId = this.places[this.originIndex]?.place_id ?? '';
    this.pendingDestinationId = this.places[this.destinationIndex]?.place_id ?? '';
    this.preselectCourse = false; this.rememberSelection();
    this.invalidateRoute();
  }

  private async createRoute(): Promise<void> {
    if (!this.active || !this.pageActive || this.routeScope.length === 0 || this.boundScope !== this.routeScope || this.loading || this.routeLoading || this.placesError.length > 0 ||
      this.activeContextKey !== this.routeContextKey || this.appliedIntentKey !== this.intentKey()) { return; }
    const origin = this.places[this.originIndex];
    const destination = this.places[this.destinationIndex];
    if (origin === undefined || destination === undefined || origin.place_id === destination.place_id) {
      this.errorText = '请选择两个不同的地点。';
      return;
    }
    const revision = ++this.routeRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    const scope = this.routeScope;
    const packageId = this.snapshot?.package.package_id ?? '';
    const packageVersion = this.snapshot?.package.version ?? '';
    this.errorText = '';
    this.route = null;
    this.routeLoading = true;
    try {
      const route = await new CampusFlowApi(baseUrl, token).campusRoute(origin.place_id, destination.place_id);
      if (!this.current(revision, token, baseUrl, scope, true)) { return; }
      if (route.origin?.place_id !== origin.place_id || route.destination?.place_id !== destination.place_id ||
        route.package_id !== packageId || route.package_version !== packageVersion) { throw new Error('route selection changed'); }
      this.route = route;
    } catch {
      if (this.current(revision, token, baseUrl, scope, true)) {
        this.errorText = '暂时无法生成路线。起终点已保留，可以重试。';
      }
    } finally {
      if (this.current(revision, token, baseUrl, scope, true)) { this.routeLoading = false; }
    }
  }

  private candidatePlaces(): CampusDataPlace[] {
    return this.places.filter((place: CampusDataPlace) => this.courseMatch?.candidateIds.includes(place.place_id) === true);
  }

  private selectCandidate(id: string): void {
    this.choosePlace(this.places.findIndex((place: CampusDataPlace) => place.place_id === id), false);
  }

  private matchMessage(): string {
    if (this.courseMatch === null) { return '地点读取后核对课程楼宇。'; }
    if (this.courseMatch.status === 'unsupported') { return '课程所属校区与当前地图范围不一致，请核对原地点；没有自动预选。'; }
    if (this.courseMatch.status === 'ambiguous') { return '原地点对应多个地图地点，请明确选择本次目的地。'; }
    if (this.courseMatch.status === 'unique') { return `地图匹配到：${this.courseMatch.matchedLabel}。楼内教室需按原地点核对。`; }
    return '尚未唯一匹配到地图地点。原地点已保留，可在下方手动选择并核对。';
  }

  @Builder
  private CourseContext() {
    if (this.visibleCourse !== null) {
      Column({ space: 8 }) {
        Text('来自课程安排').fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
        Text(this.visibleCourse.course.title).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium)
          .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text(`${this.visibleCourse.course.date} · ${this.visibleCourse.course.start_time}–${this.visibleCourse.course.end_time}`)
          .fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text(`${this.visibleCourse.school} · ${this.visibleCourse.campus}`).fontSize(this.palette.metaSize)
          .fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text(`课程原地点：${this.visibleCourse.course.location || '未填写'}`).fontSize(this.palette.bodySize)
          .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
        if (this.visibleCourse.course.teacher.length > 0) {
          Text(`教师：${this.visibleCourse.course.teacher}`).fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%')
            .wordBreak(WordBreak.BREAK_WORD)
        }
        Text(this.matchMessage()).fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        if (this.courseMatch?.status === 'ambiguous' || this.courseMatch?.status === 'missing') {
          ForEach(this.candidatePlaces(), (place: CampusDataPlace) => {
            Button(`${place.name} · ${place.zone}`).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
              .width('100%').constraintSize({ minHeight: 48 }).padding(12).backgroundColor(this.palette.accentSoft)
              .borderRadius(this.palette.controlRadius).enabled(!this.loading).onClick(() => this.selectCandidate(place.place_id))
          }, (place: CampusDataPlace) => place.place_id)
        }
        EvidencePanel({ evidence: this.visibleCourse.evidence, active: this.active })
        Text('来源描述整份已保存课表；地图仅指向楼宇，不定位到教室或当前位置。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
        .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
    }
  }

  @Builder
  private PlaceEvidence(place: CampusDataPlace) {
    Column({ space: 8 }) {
      Text(`${place.name} · ${openingStatus(place)}`).fontSize(this.palette.bodySize).fontColor(this.palette.ink)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`参考开放时间：${place.open_hours.length > 0 ? place.open_hours : '未提供'}。临时闭馆与现场通行情况请另行核对。`)
        .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      EvidencePanel({ evidence: place.evidence ?? [], active: this.active })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          AppIcon({ name: 'back', iconSize: 22, color: this.palette.accent })
        }.width(44).height(44).backgroundColor(Color.Transparent).borderRadius(12)
          .accessibilityText('返回上一页').onClick(() => this.onBack())
        Text('校园导航').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.palette.ink).layoutWeight(1)
      }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 8, right: 20, top: 4, bottom: 4 })

      Scroll(this.scroller) {
        Column({ space: 16 }) {
          this.CourseContext()
          Column({ space: 12 }) {
            Row() {
              Text('选择路线').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
              Blank()
              Text(`${this.places.length} 个地点`).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
            }.width('100%')

            if (this.loading) {
              FeedbackPanel({ kind: 'loading', title: '正在读取校园地点', message: '保留当前选择，读取完成后可生成路线。' })
            } else if (this.placesError.length > 0) {
              FeedbackPanel({ kind: 'error', title: '地点暂不可用', message: this.placesError,
                actionLabel: '重试读取地点', onAction: () => this.loadPlaces() })
            } else if (this.places.length < 2) {
              FeedbackPanel({ kind: 'empty', title: '地点数据不足', message: '需要至少两个可用地点才能生成路线。',
                actionLabel: '重新读取', onAction: () => this.loadPlaces() })
            } else {
              Column({ space: 6 }) {
                Text('起点').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
                Select(this.options()).selected(this.originIndex)
                  .value(this.places[this.originIndex]?.name ?? '请选择起点')
                  .fontColor(this.palette.ink).backgroundColor(this.palette.field)
                  .optionBgColor(this.palette.surface).optionFontColor(this.palette.ink)
                  .selectedOptionBgColor(this.palette.accentSoft).selectedOptionFontColor(this.palette.accent)
                  .borderRadius(13).width('100%').constraintSize({ minHeight: 48 })
                  .onSelect((index: number) => {
                    this.choosePlace(index, true);
                  })
              }.width('100%').alignItems(HorizontalAlign.Start)

              Button('交换起终点').constraintSize({ minHeight: 44 }).fontSize(this.palette.metaSize).fontColor(this.palette.accent)
                .backgroundColor(Color.Transparent).borderRadius(12).enabled(this.originIndex >= 0 && this.destinationIndex >= 0).onClick(() => {
                  this.getUIContext().animateTo({ duration: AppTheme.motion(200), curve: Curve.EaseOut }, () => this.swap());
                })

              Column({ space: 6 }) {
                Text('终点').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
                Select(this.options()).selected(this.destinationIndex)
                  .value(this.places[this.destinationIndex]?.name ?? '请选择终点')
                  .fontColor(this.palette.ink).backgroundColor(this.palette.field)
                  .optionBgColor(this.palette.surface).optionFontColor(this.palette.ink)
                  .selectedOptionBgColor(this.palette.accentSoft).selectedOptionFontColor(this.palette.accent)
                  .borderRadius(13).width('100%').constraintSize({ minHeight: 48 })
                  .onSelect((index: number) => {
                    this.choosePlace(index, false);
                  })
              }.width('100%').alignItems(HorizontalAlign.Start)

              Text('手动选择起点，不读取当前位置。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')

              Button(this.routeLoading ? '正在生成示意路线…' : '生成路线图').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.onAccent)
                .backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius).enabled(!this.routeLoading)
                .onClick(() => this.createRoute())
            }

            if (!this.loading && this.placesError.length === 0) {
              EvidencePanel({ evidence: this.packageEvidence, active: this.active })
            }

            if (this.errorText.length > 0) {
              FeedbackPanel({ kind: 'error', title: '路线尚未生成', message: this.errorText,
                actionLabel: '重试生成路线', busy: this.routeLoading, onAction: () => this.createRoute() })
            }
          }.width('100%').padding(this.palette.cardInset).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)

          if (this.route !== null) {
            RouteMap({ route: this.route as CampusRoute })
            Text('路线几何为示意，距离与步行分钟为估算；不含实时定位、道路封闭或通行状态。')
              .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            EvidencePanel({ evidence: this.route.evidence ?? [], active: this.active })
            this.PlaceEvidence(this.route.origin)
            this.PlaceEvidence(this.route.destination)
          } else if (!this.loading && !this.routeLoading && this.errorText.length === 0 && this.placesError.length === 0 && this.places.length >= 2) {
            Column({ space: 7 }) {
              AppIcon({ name: 'route', iconSize: 32, color: this.palette.accent })
              Text('选择两个地点').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
              Text('路线按已有校园地图生成，步行时间为估算；请以现场道路与通行情况为准。')
                .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).textAlign(TextAlign.Center)
            }.width('100%').padding(20).backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
          .padding({ left: 18, right: 18, top: 4, bottom: 32 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(this.palette.bg)
  }
}
