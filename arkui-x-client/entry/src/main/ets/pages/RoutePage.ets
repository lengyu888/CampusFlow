import { CampusDataPlace, CampusDataSnapshot, CampusPlaceCandidate, CampusRoute, DataEvidence } from '../model/ApiModels';
import { RouteMap } from '../components/RouteMap';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { AppPageHeader } from '../components/AppPageHeader';
import { InfoDisclosure } from '../components/InfoDisclosure';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { EvidencePanel } from '../components/EvidencePanel';
import { openingStatus } from '../utils/EvidencePresentation';
import { CourseRouteIntent, CoursePlaceMatch, matchCoursePlace } from '../utils/CourseRouteIntent';
import { supportedMapCampus, validBaiduRoute } from '../utils/RouteMapBridge';
import { CampusFlowRequestError, requestFailure } from '../utils/AgentFeedback';
import { candidatePreviewPlace, hasPlaceLocation, validPlaceCandidates, validPlaceSelection } from '../utils/CampusPlaceSelection';

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
  @Watch('accountChanged') @Prop school: string = '';
  @Watch('accountChanged') @Prop campus: string = '';
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
  @State private candidateEndpoint: string = '';
  @State private candidateQuery: string = '';
  @State private candidates: CampusPlaceCandidate[] = [];
  @State private selectedCandidateIndex: number = -1;
  @State private candidatePage: number = -1;
  @State private candidateHasMore: boolean = false;
  @State private candidateTruncated: boolean = false;
  @State private candidateExpiresAt: string = '';
  @State private candidateLoading: boolean = false;
  @State private candidateSaving: boolean = false;
  @State private candidateError: string = '';
  private candidateRevision: number = 0;
  private scroller: Scroller = new Scroller();
  private pageActive: boolean = true;
  private placesRevision: number = 0;
  private routeRevision: number = 0;
  @State private placesLoaded: boolean = false;
  @State private snapshot: CampusDataSnapshot | null = null;
  private boundScope: string = '';
  private boundBaseUrl: string = '';
  private boundToken: string = '';
  private boundSchool: string = '';
  private boundCampus: string = '';
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
    this.invalidateRoute();
  }

  private accountChanged(): void {
    if (this.boundScope === this.routeScope && this.boundBaseUrl === this.baseUrl && this.boundToken === this.token &&
      this.boundSchool === this.school && this.boundCampus === this.campus) { return; }
    this.invalidateRequests(); this.contextRevision++;
    this.boundScope = this.routeScope; this.boundBaseUrl = this.baseUrl; this.boundToken = this.token;
    this.boundSchool = this.school; this.boundCampus = this.campus;
    this.selections = []; this.places = []; this.packageEvidence = []; this.snapshot = null;
    this.originIndex = -1; this.destinationIndex = -1; this.pendingOriginId = ''; this.pendingDestinationId = '';
    this.courseMatch = null; this.visibleCourse = null; this.route = null; this.placesLoaded = false; this.placesError = ''; this.errorText = '';
    this.activeContextKey = ''; this.appliedIntentKey = ''; this.contextChanged();
  }

  private contextChanged(): void {
    const revision = ++this.contextRevision;
    this.closePlacePicker();
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
    if (this.boundScope !== this.routeScope || this.boundBaseUrl !== this.baseUrl || this.boundToken !== this.token ||
      this.boundSchool !== this.school || this.boundCampus !== this.campus) { this.accountChanged(); }
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
    this.closePlacePicker();
    this.placesRevision++;
    this.routeRevision++;
    this.loading = false;
    this.routeLoading = false;
  }

  private activeChanged(): void {
    if (!this.active) { this.rememberSelection(); this.invalidateRequests(); this.invalidateRoute(); return; }
    if (!this.pageActive) { return; }
    this.applyContext(); this.loadPlaces();
  }

  private async loadPlaces(): Promise<void> {
    if (!this.active || !this.pageActive || this.routeScope.length === 0 || this.token.length === 0 ||
      this.school.length === 0 || this.campus.length === 0 || this.loading && this.placesRevision > 0) { return; }
    this.closePlacePicker();
    const revision = ++this.placesRevision;
    const token = this.token;
    const baseUrl = this.baseUrl;
    const scope = this.routeScope;
    const originId = this.places[this.originIndex]?.place_id ?? this.pendingOriginId;
    const destinationId = this.places[this.destinationIndex]?.place_id ?? this.pendingDestinationId;
    this.loading = true;
    this.placesLoaded = false;
    this.snapshot = null;
    this.invalidateRoute();
    this.placesError = '';
    try {
      const data: CampusDataSnapshot = await new CampusFlowApi(baseUrl, token).campusData();
      if (!this.current(revision, token, baseUrl, scope, false)) { return; }
      if (!data.package || typeof data.package.package_id !== 'string' || typeof data.package.version !== 'string' ||
        !supportedMapCampus(this.school, this.campus) || !supportedMapCampus(data.package.school, data.package.campus) || !Array.isArray(data.places) ||
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
        this.snapshot = null;
        this.placesLoaded = false;
        this.placesError = '暂时无法读取校园地点，请检查连接后重试。';
      }
    } finally {
      if (this.current(revision, token, baseUrl, scope, false)) { this.loading = false; }
    }
  }

  private placeLabel(place: CampusDataPlace | null | undefined): string {
    // The campus package keeps the familiar display label as the first alias.
    const alias = place?.aliases?.[0];
    return typeof alias === 'string' && alias.trim().length > 0 ? alias.trim() : place?.name ?? '';
  }

  private options(): Array<SelectOption> {
    return this.places.map((place: CampusDataPlace) => new CampusSelectOption(this.placeLabel(place)));
  }

  private current(revision: number, token: string, baseUrl: string, scope: string, route: boolean): boolean {
    return this.pageActive && this.active && scope.length > 0 && scope === this.routeScope && scope === this.boundScope &&
      this.school === this.boundSchool && this.campus === this.boundCampus &&
      token === this.token && baseUrl === this.baseUrl && revision === (route ? this.routeRevision : this.placesRevision);
  }

  private mapActive(): boolean {
    return this.pageActive && this.active && this.routeScope.length > 0 && this.boundScope === this.routeScope &&
      this.token.length > 0 && this.boundToken === this.token && this.boundBaseUrl === this.baseUrl &&
      this.boundSchool === this.school && this.boundCampus === this.campus && this.placesLoaded && !this.loading &&
      this.placesError.length === 0 && this.snapshot !== null &&
      supportedMapCampus(this.school, this.campus) && supportedMapCampus(this.snapshot.package.school, this.snapshot.package.campus);
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
    this.closePlacePicker();
    if (origin) { this.originIndex = index; this.pendingOriginId = this.places[index].place_id; }
    else { this.destinationIndex = index; this.pendingDestinationId = this.places[index].place_id; this.preselectCourse = false; }
    this.rememberSelection();
    this.invalidateRoute();
  }

  private swap(): void {
    if (!this.active || !this.pageActive || this.loading || this.originIndex < 0 || this.destinationIndex < 0) { return; }
    this.closePlacePicker();
    const previous = this.originIndex;
    this.originIndex = this.destinationIndex;
    this.destinationIndex = previous;
    this.pendingOriginId = this.places[this.originIndex]?.place_id ?? '';
    this.pendingDestinationId = this.places[this.destinationIndex]?.place_id ?? '';
    this.preselectCourse = false; this.rememberSelection();
    this.invalidateRoute();
  }

  private async createRoute(): Promise<void> {
    if (!this.mapActive() || this.routeLoading ||
      this.activeContextKey !== this.routeContextKey || this.appliedIntentKey !== this.intentKey()) { return; }
    const origin = this.places[this.originIndex];
    const destination = this.places[this.destinationIndex];
    if (origin === undefined || destination === undefined || origin.place_id === destination.place_id) {
      this.errorText = '请选择两个不同的地点。';
      return;
    }
    if (this.candidateEndpoint.length > 0) { this.errorText = '请先确认候选地点或取消预览，再规划路线。'; return; }
    if (!hasPlaceLocation(origin)) { await this.openPlacePicker(true); return; }
    if (!hasPlaceLocation(destination)) { await this.openPlacePicker(false); return; }
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
        route.package_id !== packageId || route.package_version !== packageVersion || !validBaiduRoute(route)) { throw new Error('invalid route'); }
      this.route = route;
    } catch (error) {
      if (this.current(revision, token, baseUrl, scope, true)) {
        this.errorText = error instanceof CampusFlowRequestError ?
          requestFailure(error.statusCode, JSON.stringify({ code: error.code })).message :
          '暂时无法生成路线。起终点已保留，可以重试。';
      }
    } finally {
      if (this.current(revision, token, baseUrl, scope, true)) { this.routeLoading = false; }
    }
  }

  private closePlacePicker(): void {
    this.candidateRevision++;
    this.candidates = []; this.selectedCandidateIndex = -1; this.candidateExpiresAt = '';
    this.candidateEndpoint = ''; this.candidateQuery = ''; this.candidatePage = -1;
    this.candidateHasMore = false; this.candidateTruncated = false;
    this.candidateLoading = false; this.candidateSaving = false; this.candidateError = '';
  }

  private pickerPlace(): CampusDataPlace | undefined {
    return this.candidateEndpoint === 'origin' ? this.places[this.originIndex] :
      this.candidateEndpoint === 'destination' ? this.places[this.destinationIndex] : undefined;
  }

  private candidateContext(): string {
    return JSON.stringify([this.token, this.baseUrl, this.routeScope, this.school, this.campus,
      this.routeContextKey, this.intentKey(), this.snapshot?.package.package_id, this.snapshot?.package.version,
      this.places[this.originIndex]?.place_id, this.places[this.destinationIndex]?.place_id, this.candidateEndpoint]);
  }

  private candidateCurrent(revision: number, context: string): boolean {
    return this.mapActive() && revision === this.candidateRevision && this.candidateEndpoint.length > 0 &&
      this.activeContextKey === this.routeContextKey && this.appliedIntentKey === this.intentKey() && context === this.candidateContext();
  }

  private async openPlacePicker(origin: boolean): Promise<void> {
    if (!this.mapActive() || this.activeContextKey !== this.routeContextKey || this.appliedIntentKey !== this.intentKey()) { return; }
    const place = this.places[origin ? this.originIndex : this.destinationIndex];
    if (place === undefined) { return; }
    this.closePlacePicker(); this.invalidateRoute();
    this.candidateEndpoint = origin ? 'origin' : 'destination'; this.candidateQuery = place.name;
    await this.loadCandidates(false);
  }

  private candidateQueryChanged(value: string): void {
    this.candidateRevision++;
    this.candidateQuery = value;
    this.candidates = []; this.selectedCandidateIndex = -1; this.candidateExpiresAt = '';
    this.candidatePage = -1; this.candidateHasMore = false; this.candidateTruncated = false;
    this.candidateLoading = false; this.candidateSaving = false; this.candidateError = '';
  }

  private async loadCandidates(more: boolean): Promise<void> {
    const place = this.pickerPlace();
    if (!this.mapActive() || place === undefined || this.candidateLoading || this.candidateSaving ||
      more && (!this.candidateHasMore || this.candidatePage >= 4)) { return; }
    const page = more ? this.candidatePage + 1 : 0;
    const query = this.candidateQuery.trim();
    const previousExpiry = more ? this.candidateExpiresAt : '';
    const revision = ++this.candidateRevision;
    const context = this.candidateContext();
    if (!more) { this.candidates = []; this.candidatePage = -1; this.candidateHasMore = false; this.candidateTruncated = false; }
    // Each page has a short-lived credential; loading another page requires a fresh explicit choice.
    this.selectedCandidateIndex = -1; this.candidateExpiresAt = ''; this.candidateError = ''; this.candidateLoading = true;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).campusPlaceCandidates(place.place_id, page, query);
      if (!this.candidateCurrent(revision, context)) { return; }
      if (!validPlaceCandidates(result, place.place_id, page)) { throw new Error('invalid candidates'); }
      this.candidates = (more ? this.candidates : []).concat(result.candidates);
      this.candidatePage = result.page; this.candidateHasMore = result.has_more && result.page < 4;
      this.candidateTruncated = result.truncated;
      this.candidateExpiresAt = previousExpiry.length > 0 && Date.parse(previousExpiry) < Date.parse(result.expires_at) ? previousExpiry : result.expires_at;
    } catch (error) {
      if (this.candidateCurrent(revision, context)) {
        this.candidateError = error instanceof CampusFlowRequestError ?
          requestFailure(error.statusCode, JSON.stringify({ code: error.code })).message : '暂时无法读取候选地点，请重试检索。';
      }
    } finally {
      if (this.candidateCurrent(revision, context)) { this.candidateLoading = false; }
    }
  }

  private previewCandidate(index: number): void {
    if (!this.mapActive() || this.candidateLoading || this.candidateSaving || !Number.isInteger(index) || index < 0 || index >= this.candidates.length) { return; }
    this.selectedCandidateIndex = index; this.invalidateRoute();
  }

  private previewPlace(place: CampusDataPlace | null, origin: boolean): CampusDataPlace | null {
    const candidate = this.candidates[this.selectedCandidateIndex];
    return place !== null && candidate !== undefined && this.candidateEndpoint === (origin ? 'origin' : 'destination') && this.mapActive() ?
      candidatePreviewPlace(place, candidate) : place;
  }

  private placeSelectionStatus(place: CampusDataPlace): string {
    if (validPlaceSelection(place.selection, place.place_id)) { return `已确认：${place.selection!.name} · ${place.selection!.address}`; }
    return hasPlaceLocation(place) ? '已配置地图入口，可直接规划路线。' : '待确认地图入口，请检索候选并核对位置。';
  }

  private async confirmCandidate(): Promise<void> {
    const place = this.pickerPlace(); const candidate = this.candidates[this.selectedCandidateIndex];
    if (!this.mapActive() || place === undefined || candidate === undefined || this.candidateSaving || this.candidateLoading) { return; }
    const revision = ++this.candidateRevision; const context = this.candidateContext();
    if (!this.candidateCurrent(revision, context)) { return; }
    if (!Number.isFinite(Date.parse(this.candidateExpiresAt)) || Date.parse(this.candidateExpiresAt) <= Date.now()) {
      this.candidates = []; this.selectedCandidateIndex = -1; this.candidateHasMore = false;
      this.candidateError = '候选地点已过期，请重新检索后确认。'; return;
    }
    this.candidateSaving = true; this.candidateError = '';
    try {
      const saved = await new CampusFlowApi(this.baseUrl, this.token).confirmCampusPlaceSelection(place.place_id, candidate.selection_token);
      if (!this.candidateCurrent(revision, context)) { return; }
      if (!validPlaceSelection(saved, place.place_id) || saved.baidu_uid !== candidate.baidu_uid ||
        saved.location.lat !== candidate.location.lat || saved.location.lng !== candidate.location.lng) { throw new Error('invalid selection'); }
      this.closePlacePicker();
      await this.loadPlaces();
    } catch (error) {
      if (this.candidateCurrent(revision, context)) {
        this.candidateError = error instanceof CampusFlowRequestError ?
          requestFailure(error.statusCode, JSON.stringify({ code: error.code })).message : '暂时无法确认保存结果，请重新读取地点后核对。';
        if (error instanceof CampusFlowRequestError && (error.code === 'MAP_SELECTION_EXPIRED' || error.code === 'MAP_SELECTION_INVALID')) {
          this.candidates = []; this.selectedCandidateIndex = -1; this.candidateHasMore = false;
        }
      }
    } finally {
      if (this.candidateCurrent(revision, context)) { this.candidateSaving = false; }
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
    if (this.courseMatch.status === 'unique') {
      const placeId = this.courseMatch.candidateIds[0];
      const place = this.places.find((item: CampusDataPlace) => item.place_id === placeId);
      return `地图匹配到：${this.placeLabel(place) || this.courseMatch.matchedLabel}。楼内教室需按原地点核对。`;
    }
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
            Button(`${this.placeLabel(place)} · ${place.zone}`).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
              .width('100%').constraintSize({ minHeight: 48 }).padding(12).backgroundColor(this.palette.accentSoft)
              .borderRadius(this.palette.controlRadius).enabled(!this.loading).onClick(() => this.selectCandidate(place.place_id))
          }, (place: CampusDataPlace) => place.place_id)
        }
        EvidencePanel({ evidence: this.visibleCourse.evidence, active: this.active })
        InfoDisclosure({ title: '课程地点说明', message: '来源描述整份已保存课表；地图仅指向楼宇，不定位到教室或当前位置。' })
      }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
        .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
    }
  }

  @Builder
  private PlaceEvidence(place: CampusDataPlace) {
    Column({ space: 8 }) {
      Text(`${this.placeLabel(place)} · ${openingStatus(place)}`).fontSize(this.palette.bodySize).fontColor(this.palette.ink)
        .width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(`参考开放时间：${place.open_hours.length > 0 ? place.open_hours : '未提供'}`)
        .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      EvidencePanel({ evidence: place.evidence ?? [], active: this.active })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private EndpointSelection(place: CampusDataPlace, origin: boolean) {
    Column({ space: 6 }) {
      Text(`${origin ? '起点' : '终点'} · ${this.placeSelectionStatus(place)}`).fontSize(this.palette.metaSize)
        .fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Button(hasPlaceLocation(place) ? '重新选择地图入口' : '检索并确认地图入口')
        .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
        .borderRadius(this.palette.controlRadius).width('100%').constraintSize({ minHeight: 44 })
        .enabled(!this.candidateSaving).onClick(() => this.openPlacePicker(origin))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private PlacePicker() {
    if (this.candidateEndpoint.length > 0) {
      Column({ space: 12 }) {
        Text(`确认${this.candidateEndpoint === 'origin' ? '起点' : '终点'}地图入口`)
          .fontSize(this.palette.sectionTitle).fontColor(this.palette.ink).width('100%')
        Text(this.placeLabel(this.pickerPlace())).fontSize(this.palette.bodySize).fontColor(this.palette.ink)
          .width('100%').wordBreak(WordBreak.BREAK_WORD)
        TextInput({ text: this.candidateQuery, placeholder: '输入地点或入口名称' }).fontColor(this.palette.ink)
          .backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius).height(48)
          .maxLength(200).enabled(!this.candidateSaving).onChange((value: string) => this.candidateQueryChanged(value))
        Row({ space: 12 }) {
          Button('检索候选').fontSize(this.palette.bodySize).fontColor(this.palette.onAccent)
            .backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius).constraintSize({ minHeight: 44 }).layoutWeight(1)
            .enabled(!this.candidateLoading && !this.candidateSaving).onClick(() => this.loadCandidates(false))
          Button('取消预览').fontSize(this.palette.bodySize).fontColor(this.palette.accent)
            .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius).constraintSize({ minHeight: 44 }).layoutWeight(1)
            .onClick(() => this.closePlacePicker())
        }.width('100%')
        Text('点选候选可在下方地图预览；核对名称、地址和位置后，点击“确认此地点”保存到当前账号。')
          .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        if (this.candidateLoading) {
          FeedbackPanel({ kind: 'loading', title: '正在检索候选地点', message: '保留起终点，等候查询结果。' })
        }
        ForEach(this.candidates, (candidate: CampusPlaceCandidate, index: number) => {
          Column({ space: 6 }) {
            Text(candidate.name).fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Text(candidate.address.length > 0 ? candidate.address : '未提供地址，请核对地图位置。')
              .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            Button(this.selectedCandidateIndex === index ? '已选中 · 地图预览中' : '选择并预览位置')
              .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
              .borderRadius(this.palette.controlRadius).width('100%').constraintSize({ minHeight: 44 })
              .enabled(!this.candidateLoading && !this.candidateSaving).onClick(() => this.previewCandidate(index))
          }.width('100%').padding(12).backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius)
        }, (candidate: CampusPlaceCandidate, index: number) => `${candidate.baidu_uid}-${index}`)
        if (!this.candidateLoading && this.candidatePage >= 0 && this.candidates.length === 0 && this.candidateError.length === 0) {
          Text(this.candidateHasMore ? '本页没有符合校园范围的候选，可加载下一页或修改关键词。' : '没有找到符合校园范围的候选，请修改关键词后重试。')
            .fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
        if (this.candidateHasMore) {
          Button('加载更多候选').fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
            .borderRadius(this.palette.controlRadius).width('100%').constraintSize({ minHeight: 44 })
            .enabled(!this.candidateLoading && !this.candidateSaving).onClick(() => this.loadCandidates(true))
        }
        if (this.candidateTruncated) {
          Text('已达到本次检索页数上限，请用更具体的入口名称缩小范围。').fontSize(this.palette.metaSize)
            .fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        }
        if (this.candidateError.length > 0) {
          FeedbackPanel({ kind: 'error', title: '地点尚未确认', message: this.candidateError,
            actionLabel: '重新检索', busy: this.candidateLoading || this.candidateSaving, onAction: () => this.loadCandidates(false) })
        }
        Button(this.candidateSaving ? '正在保存并核对地点…' : '确认此地点').fontSize(this.palette.bodySize)
          .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
          .width('100%').constraintSize({ minHeight: 48 })
          .enabled(this.selectedCandidateIndex >= 0 && !this.candidateLoading && !this.candidateSaving)
          .onClick(() => this.confirmCandidate())
      }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
        .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
    }
  }

  build() {
    Column() {
      AppPageHeader({ title: '校园导航', onBack: () => this.onBack() })

      Scroll(this.scroller) {
        Column({ space: 16 }) {
          this.CourseContext()
          Column({ space: 12 }) {
            Row() {
              Text('选择路线').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
              Blank()
              Button('交换起终点').constraintSize({ minHeight: 44 }).fontSize(this.palette.metaSize).fontColor(this.palette.accent)
                .padding({ left: 8, right: 0 }).backgroundColor(Color.Transparent)
                .enabled(!this.loading && this.originIndex >= 0 && this.destinationIndex >= 0).onClick(() => {
                  this.getUIContext().animateTo({ duration: AppTheme.motion(200), curve: Curve.EaseOut }, () => this.swap());
                })
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
              Row({ space: 12 }) {
                Text('起点').fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width(40)
                Select(this.options()).selected(this.originIndex)
                  .value(this.placeLabel(this.places[this.originIndex]) || '请选择起点')
                  .fontColor(this.palette.ink).backgroundColor(this.palette.field)
                  .optionBgColor(this.palette.surface).optionFontColor(this.palette.ink)
                  .selectedOptionBgColor(this.palette.accentSoft).selectedOptionFontColor(this.palette.accent)
                  .borderRadius(this.palette.controlRadius).layoutWeight(1).constraintSize({ minHeight: 48 })
                  .onSelect((index: number) => {
                    this.choosePlace(index, true);
                  })
              }.width('100%')

              Row({ space: 12 }) {
                Text('终点').fontSize(this.palette.bodySize).fontColor(this.palette.secondary).width(40)
                Select(this.options()).selected(this.destinationIndex)
                  .value(this.placeLabel(this.places[this.destinationIndex]) || '请选择终点')
                  .fontColor(this.palette.ink).backgroundColor(this.palette.field)
                  .optionBgColor(this.palette.surface).optionFontColor(this.palette.ink)
                  .selectedOptionBgColor(this.palette.accentSoft).selectedOptionFontColor(this.palette.accent)
                  .borderRadius(this.palette.controlRadius).layoutWeight(1).constraintSize({ minHeight: 48 })
                  .onSelect((index: number) => {
                    this.choosePlace(index, false);
                  })
              }.width('100%')

              Text('手动选择起点，不读取当前位置。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
              if (this.places[this.originIndex] !== undefined) { this.EndpointSelection(this.places[this.originIndex], true) }
              if (this.places[this.destinationIndex] !== undefined) { this.EndpointSelection(this.places[this.destinationIndex], false) }

              Button(this.routeLoading ? '正在查询百度步行路线…' : '规划步行路线').width('100%').constraintSize({ minHeight: 48 })
                .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.onAccent)
                .backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius).enabled(!this.routeLoading && this.candidateEndpoint.length === 0)
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

          this.PlacePicker()
          RouteMap({ baseUrl: this.baseUrl, token: this.token, active: this.mapActive(),
            route: this.route, origin: this.previewPlace(this.places[this.originIndex] ?? null, true),
            destination: this.previewPlace(this.places[this.destinationIndex] ?? null, false) })

          if (this.route !== null) {
            Text(`百度步行路线 · 约 ${this.route.total_minutes} 分钟 · ${this.route.distance_meters ?? 0} 米`)
              .fontSize(this.palette.metaSize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
            InfoDisclosure({ title: '路线与开放时间说明', message: '路线与预计步行时间来自百度地图；请核对现场通行情况。手动选择起终点，不读取当前位置。开放时间为参考资料，临时闭馆请另行核对。' })
            EvidencePanel({ evidence: this.route.evidence ?? [], active: this.active })
            this.PlaceEvidence(this.route.origin)
            this.PlaceEvidence(this.route.destination)
          } else if (!this.loading && !this.routeLoading && this.errorText.length === 0 && this.placesError.length === 0 && this.places.length >= 2) {
            InfoDisclosure({ title: '地图与路线说明', message: '拖动或缩放查看校园地图，选择两个不同地点后查询百度步行路线。预计时间请以现场道路与通行情况为准。' })
          }
        }.width('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
          .padding({ left: 18, right: 18, top: 4, bottom: 32 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(this.palette.bg)
  }
}
