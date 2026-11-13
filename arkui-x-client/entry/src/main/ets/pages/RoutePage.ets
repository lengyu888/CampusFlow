import { CampusDataPlace, CampusDataSnapshot, CampusPlaceCandidate, CampusRoute, CampusRouteStep, DataEvidence } from '../model/ApiModels';
import { RouteMap } from '../components/RouteMap';
import { CampusFlowApi } from '../services/CampusFlowApi';
import { AppTheme } from '../theme/AppTheme';
import { ThemePalette, themePalette } from '../theme/ThemePalette';
import { AppPageHeader } from '../components/AppPageHeader';
import { AppIcon } from '../components/AppIcon';
import { InfoDisclosure } from '../components/InfoDisclosure';
import { FeedbackPanel } from '../components/FeedbackPanel';
import { EvidencePanel } from '../components/EvidencePanel';
import { openingStatus } from '../utils/EvidencePresentation';
import { CourseRouteIntent, CoursePlaceMatch, matchCoursePlace } from '../utils/CourseRouteIntent';
import { supportedMapCampus, validBaiduRoute } from '../utils/RouteMapBridge';
import { CampusFlowRequestError, requestFailure } from '../utils/AgentFeedback';
import { candidatePreviewPlace, conflictingParcelBrand, hasPlaceLocation, matchesCampusPlace, validPlaceCandidates, validPlaceSelection } from '../utils/CampusPlaceSelection';

interface RouteSelectionState {
  key: string;
  intentKey: string;
  originId: string;
  destinationId: string;
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
  @Watch('backPressed') @Prop backRevision: number = 0;
  onBack: () => void = () => {};
  onInnerNavigationChanged: (open: boolean) => void = () => {};
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
  @State private choosingEndpoint: string = '';
  @State private placeQuery: string = '';
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
  @State private candidatePageError: string = '';
  @State private candidateAcknowledged: boolean = false;
  @State private routeFormExpanded: boolean = false;
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
      this.school.length === 0 || this.campus.length === 0 || this.candidateSaving ||
      this.loading && this.placesRevision > 0) { return; }
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

  private matchingPlaces(): CampusDataPlace[] {
    const excluded = this.places[this.choosingEndpoint === 'origin' ? this.destinationIndex : this.originIndex]?.place_id;
    return this.places.filter((place: CampusDataPlace) => place.place_id !== excluded && matchesCampusPlace(place, this.placeQuery));
  }

  private openEndpointList(origin: boolean): void {
    if (!this.mapActive() || this.candidateSaving) { return; }
    this.closePlacePicker();
    this.choosingEndpoint = origin ? 'origin' : 'destination';
    this.onInnerNavigationChanged(true);
    this.scroller.scrollEdge(Edge.Top);
  }

  private backPressed(): void {
    if (this.candidateSaving) { return; }
    if (this.selectedCandidateIndex >= 0) {
      this.selectedCandidateIndex = -1;
      this.candidateAcknowledged = false;
      this.candidateError = '';
    } else if (this.candidateEndpoint.length > 0 || this.choosingEndpoint.length > 0) {
      this.closePlacePicker();
    } else {
      this.onBack();
      return;
    }
    this.scroller.scrollEdge(Edge.Top);
  }

  private pageTitle(): string {
    if (this.choosingEndpoint.length > 0) { return this.choosingEndpoint === 'origin' ? '选择起点' : '选择终点'; }
    if (this.selectedCandidateIndex >= 0) { return '核对地图入口'; }
    if (this.candidateEndpoint.length > 0) { return this.candidateEndpoint === 'origin' ? '搜索起点入口' : '搜索终点入口'; }
    return '校园导航';
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
    this.routeFormExpanded = false;
  }

  private choosePlace(index: number, origin: boolean): void {
    if (!this.active || !this.pageActive || this.routeScope.length === 0 || this.loading || this.placesError.length > 0) { return; }
    if (!Number.isInteger(index) || index < 0 || index >= this.places.length ||
      index === (origin ? this.destinationIndex : this.originIndex)) { return; }
    this.closePlacePicker();
    if (origin) { this.originIndex = index; this.pendingOriginId = this.places[index].place_id; }
    else { this.destinationIndex = index; this.pendingDestinationId = this.places[index].place_id; this.preselectCourse = false; }
    this.rememberSelection();
    this.invalidateRoute();
  }

  private selectEndpoint(placeId: string): void {
    const origin = this.choosingEndpoint === 'origin';
    const index = this.places.findIndex((place: CampusDataPlace) => place.place_id === placeId);
    this.choosePlace(index, origin);
    this.scroller.scrollEdge(Edge.Top);
    if (index >= 0 && !hasPlaceLocation(this.places[index])) { this.openPlacePicker(origin); }
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

  private async createRoute(useSavedEntries: boolean = false): Promise<void> {
    if (!this.mapActive() || this.routeLoading || this.candidateSaving ||
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
    if (this.routeEntryNeedsReview() && !useSavedEntries) {
      this.errorText = '请核对起终点，再选择按已保存入口规划。';
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
        route.package_id !== packageId || route.package_version !== packageVersion || !validBaiduRoute(route)) { throw new Error('invalid route'); }
      this.routeFormExpanded = false;
      this.route = route;
      this.scroller.scrollEdge(Edge.Top);
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
    if (this.choosingEndpoint.length > 0 || this.candidateEndpoint.length > 0) { this.onInnerNavigationChanged(false); }
    this.candidateRevision++;
    this.choosingEndpoint = ''; this.placeQuery = '';
    this.candidates = []; this.selectedCandidateIndex = -1; this.candidateExpiresAt = '';
    this.candidateEndpoint = ''; this.candidateQuery = ''; this.candidatePage = -1;
    this.candidateHasMore = false; this.candidateTruncated = false;
    this.candidateLoading = false; this.candidateError = ''; this.candidatePageError = '';
    this.candidateAcknowledged = false;
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
    if (!this.mapActive() || this.candidateSaving || this.activeContextKey !== this.routeContextKey ||
      this.appliedIntentKey !== this.intentKey()) { return; }
    const place = this.places[origin ? this.originIndex : this.destinationIndex];
    if (place === undefined) { return; }
    this.closePlacePicker(); this.invalidateRoute();
    this.candidateEndpoint = origin ? 'origin' : 'destination'; this.candidateQuery = place.name;
    this.onInnerNavigationChanged(true);
    this.scroller.scrollEdge(Edge.Top);
    await this.loadCandidates(false);
  }

  private candidateQueryChanged(value: string): void {
    if (this.candidateSaving || value === this.candidateQuery) { return; }
    this.candidateRevision++;
    this.candidateQuery = value;
    this.candidates = []; this.selectedCandidateIndex = -1; this.candidateExpiresAt = '';
    this.candidatePage = -1; this.candidateHasMore = false; this.candidateTruncated = false;
    this.candidateLoading = false; this.candidateError = ''; this.candidatePageError = '';
    this.candidateAcknowledged = false;
  }

  private async loadCandidates(more: boolean): Promise<void> {
    const place = this.pickerPlace();
    if (!this.mapActive() || place === undefined || this.candidateLoading || this.candidateSaving ||
      more && (!this.candidateHasMore || this.candidatePage >= 4)) { return; }
    const page = more ? this.candidatePage + 1 : 0;
    const query = this.candidateQuery.trim();
    if (query.length === 0) { this.candidateError = '请输入地点或入口名称。'; return; }
    const previousExpiry = more ? this.candidateExpiresAt : '';
    const revision = ++this.candidateRevision;
    const context = this.candidateContext();
    if (!more) {
      this.candidates = []; this.candidatePage = -1; this.candidateHasMore = false; this.candidateTruncated = false;
      this.candidateExpiresAt = '';
    }
    // Keep the existing candidates' expiry if the next page fails to load.
    this.selectedCandidateIndex = -1; this.candidateAcknowledged = false;
    this.candidateError = ''; this.candidatePageError = ''; this.candidateLoading = true;
    try {
      const result = await new CampusFlowApi(this.baseUrl, this.token).campusPlaceCandidates(place.place_id, page, query);
      if (!this.candidateCurrent(revision, context)) { return; }
      if (!validPlaceCandidates(result, place.place_id, page)) { throw new Error('invalid candidates'); }
      const candidates = (more ? this.candidates : []).concat(result.candidates);
      const seen = new Set<string>();
      this.candidates = candidates.filter((candidate: CampusPlaceCandidate) => {
        if (seen.has(candidate.baidu_uid)) { return false; }
        seen.add(candidate.baidu_uid);
        return true;
      });
      this.candidatePage = result.page; this.candidateHasMore = result.has_more && result.page < 4;
      this.candidateTruncated = result.truncated;
      this.candidateExpiresAt = previousExpiry.length > 0 && Date.parse(previousExpiry) < Date.parse(result.expires_at) ? previousExpiry : result.expires_at;
    } catch (error) {
      if (this.candidateCurrent(revision, context)) {
        const message = error instanceof CampusFlowRequestError ?
          requestFailure(error.statusCode, JSON.stringify({ code: error.code })).message : '暂时无法读取候选地点，请重试检索。';
        if (more) { this.candidatePageError = message; } else { this.candidateError = message; }
      }
    } finally {
      if (this.candidateCurrent(revision, context)) { this.candidateLoading = false; }
    }
  }

  private previewCandidate(index: number): void {
    if (!this.mapActive() || this.candidateLoading || this.candidateSaving || !Number.isInteger(index) || index < 0 || index >= this.candidates.length) { return; }
    this.selectedCandidateIndex = index; this.invalidateRoute();
    this.candidateAcknowledged = false;
    this.candidateError = '';
    this.scroller.scrollEdge(Edge.Top);
  }

  private previewPlace(place: CampusDataPlace | null, origin: boolean): CampusDataPlace | null {
    const candidate = this.candidates[this.selectedCandidateIndex];
    return place !== null && candidate !== undefined && this.candidateEndpoint === (origin ? 'origin' : 'destination') && this.mapActive() ?
      candidatePreviewPlace(place, candidate) : place;
  }

  private placeSelectionStatus(place: CampusDataPlace): string {
    if (validPlaceSelection(place.selection, place.place_id)) { return `已确认 · ${place.selection!.name}`; }
    return hasPlaceLocation(place) ? '已有地图入口' : '待确认地图入口';
  }

  private savedEntryConflict(place: CampusDataPlace | undefined): boolean {
    return place !== undefined && validPlaceSelection(place.selection, place.place_id) &&
      conflictingParcelBrand(place, place.selection!.name);
  }

  private routeEntryNeedsReview(): boolean {
    return this.savedEntryConflict(this.places[this.originIndex]) || this.savedEntryConflict(this.places[this.destinationIndex]);
  }

  private routeActionLabel(): string {
    if (this.routeLoading) { return '正在规划…'; }
    const origin = this.places[this.originIndex];
    const destination = this.places[this.destinationIndex];
    if (origin === undefined || destination === undefined) { return '规划步行路线'; }
    if (!hasPlaceLocation(origin)) { return '确认起点入口'; }
    if (!hasPlaceLocation(destination)) { return '确认终点入口'; }
    return this.routeEntryNeedsReview() ? '按已保存入口规划' : '规划步行路线';
  }

  private performRouteAction(): Promise<void> {
    return this.createRoute(this.routeEntryNeedsReview());
  }

  private routedPlaceLabel(place: CampusDataPlace | undefined): string {
    return this.savedEntryConflict(place) ? place!.selection!.name : this.placeLabel(place);
  }

  private candidateConflict(): boolean {
    const place = this.pickerPlace();
    const candidate = this.candidates[this.selectedCandidateIndex];
    return place !== undefined && candidate !== undefined && conflictingParcelBrand(place, candidate.name);
  }

  private async confirmCandidate(): Promise<void> {
    const place = this.pickerPlace(); const candidate = this.candidates[this.selectedCandidateIndex];
    if (!this.mapActive() || place === undefined || candidate === undefined || this.candidateSaving || this.candidateLoading) { return; }
    if (this.candidateConflict() && !this.candidateAcknowledged) { return; }
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
    } catch (error) {
      if (this.candidateCurrent(revision, context)) {
        this.candidateError = error instanceof CampusFlowRequestError ?
          requestFailure(error.statusCode, JSON.stringify({ code: error.code })).message : '暂时无法确认保存结果，请重新读取地点后核对。';
        if (error instanceof CampusFlowRequestError && (error.code === 'MAP_SELECTION_EXPIRED' || error.code === 'MAP_SELECTION_INVALID')) {
          this.candidates = []; this.selectedCandidateIndex = -1; this.candidateHasMore = false;
        }
      }
    } finally {
      this.candidateSaving = false;
      // A save can finish after the picker closes. Re-read the current context before planning again.
      if (!this.candidateCurrent(revision, context)) { await this.loadPlaces(); }
    }
  }

  private walkingInstructions(steps: CampusRouteStep[]): string {
    return steps.map((step: CampusRouteStep) => {
      const duration = step.minutes > 0 ? '（约 ' + step.minutes + ' 分钟）' : '';
      return step.index + '. ' + step.instruction + duration;
    }).join('\n');
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
        Text(this.visibleCourse.course.title).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Medium)
          .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text(`${this.visibleCourse.course.date} · ${this.visibleCourse.course.start_time}–${this.visibleCourse.course.end_time}`)
          .fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text(this.visibleCourse.course.location || '课表未填写地点').fontSize(this.palette.bodySize)
          .fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
        Text(this.matchMessage()).fontSize(this.palette.bodySize).fontColor(this.palette.quiet).width('100%').wordBreak(WordBreak.BREAK_WORD)
        if (this.courseMatch?.status === 'ambiguous' || this.courseMatch?.status === 'missing') {
          ForEach(this.candidatePlaces(), (place: CampusDataPlace) => {
            Button(`${this.placeLabel(place)} · ${place.zone}`).fontSize(this.palette.bodySize).fontColor(this.palette.accent)
              .width('100%').constraintSize({ minHeight: 48 }).padding(12).backgroundColor(this.palette.accentSoft)
              .borderRadius(this.palette.controlRadius).enabled(!this.loading).onClick(() => this.selectCandidate(place.place_id))
          }, (place: CampusDataPlace) => place.place_id)
        }
        EvidencePanel({ evidence: this.visibleCourse.evidence, active: this.active })
        InfoDisclosure({ title: '课程与地点说明', message: `${this.visibleCourse.school} · ${this.visibleCourse.campus}${this.visibleCourse.course.teacher.length > 0 ? '\n教师：' + this.visibleCourse.course.teacher : ''}\n课表地点用于匹配楼宇，地图不定位到教室或当前位置。` })
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
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }

  @Builder
  private EndpointRow(place: CampusDataPlace | undefined, origin: boolean) {
    Column({ space: 0 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Circle().width(12).height(12).fill(origin ? this.palette.surface : this.palette.accent)
            .stroke(this.palette.accent).strokeWidth(2)
          Column({ space: 3 }) {
            Text(origin ? '起点' : '终点').fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
            Text(this.placeLabel(place) || (origin ? '选择出发地点' : '选择到达地点'))
              .fontSize(this.palette.bodySize + 2).fontWeight(FontWeight.Medium)
              .fontColor(place === undefined ? this.palette.secondary : this.palette.ink)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          AppIcon({ name: 'chevron', iconSize: 19, color: this.palette.secondary })
        }.width('100%').padding({ top: 11, bottom: 11 })
      }.width('100%').constraintSize({ minHeight: 52 }).padding(0).backgroundColor(Color.Transparent)
        .accessibilityText((origin ? '选择起点 ' : '选择终点 ') + this.placeLabel(place))
        .onClick(() => this.openEndpointList(origin))
      if (place !== undefined) {
        Row({ space: 8 }) {
          Text(this.savedEntryConflict(place) ? `名称需核对 · ${place.selection!.name}` : this.placeSelectionStatus(place))
            .fontSize(this.palette.metaSize).fontColor(this.savedEntryConflict(place) ? this.palette.warning : this.palette.secondary)
            .wordBreak(WordBreak.BREAK_WORD).layoutWeight(1)
          Button(hasPlaceLocation(place) ? '换入口' : '确认入口', { type: ButtonType.Normal })
            .fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(Color.Transparent)
            .padding({ left: 6, right: 2 }).constraintSize({ minHeight: 44 })
            .onClick(() => this.openPlacePicker(origin))
        }.width('100%').padding({ left: 24 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private PlaceRow(name: string, description: string, selected: boolean, onChoose: () => void, caution: boolean = false) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(name).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.ink)
            .width('100%').wordBreak(WordBreak.BREAK_WORD)
          if (description.length > 0) {
            Text(description).fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
              .width('100%').wordBreak(WordBreak.BREAK_WORD)
          }
          if (caution) {
            Text('品牌名称不同').fontSize(this.palette.metaSize).fontColor(this.palette.warning)
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        AppIcon({ name: selected ? 'check' : 'chevron', iconSize: 18, color: selected ? this.palette.accent : this.palette.secondary })
      }.width('100%').padding({ top: 13, bottom: 13, left: 15, right: 13 })
    }.width('100%').constraintSize({ minHeight: 52 }).padding(0)
      .backgroundColor(selected ? this.palette.accentSoft : this.palette.surface).onClick(onChoose)
  }

  @Builder
  private EndpointList() {
    TextInput({ text: this.placeQuery, placeholder: '搜索楼宇、简称或区域' })
      .fontColor(this.palette.ink).backgroundColor(this.palette.surface).borderRadius(this.palette.controlRadius)
      .height(48).width('100%').maxLength(80).onChange((value: string) => this.placeQuery = value)
    if (this.matchingPlaces().length === 0) {
      FeedbackPanel({ kind: 'empty', title: '没有匹配的校园地点', message: '试试楼名或常用简称。' })
    } else {
      Column() {
        ForEach(this.matchingPlaces(), (place: CampusDataPlace, index: number) => {
          if (index > 0) { Divider().color(this.palette.line).margin({ left: 15, right: 15 }) }
          this.PlaceRow(this.placeLabel(place), place.name === this.placeLabel(place) ? place.zone : place.name,
            this.places[this.choosingEndpoint === 'origin' ? this.originIndex : this.destinationIndex]?.place_id === place.place_id,
            () => this.selectEndpoint(place.place_id))
        }, (place: CampusDataPlace) => place.place_id)
      }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).clip(true)
    }
  }

  @Builder
  private CandidateList() {
    Column({ space: 12 }) {
      Text(this.placeLabel(this.pickerPlace())).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold)
        .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
      if (this.pickerPlace()?.selection?.name) {
        Text(`当前入口 · ${this.pickerPlace()?.selection?.name}`).fontSize(this.palette.metaSize)
          .fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
      }
      Row({ space: 8 }) {
        TextInput({ text: this.candidateQuery, placeholder: '输入地点或入口名称' })
          .fontColor(this.palette.ink).backgroundColor(this.palette.field).borderRadius(this.palette.controlRadius)
          .layoutWeight(1).height(46).maxLength(200).enterKeyType(EnterKeyType.Search)
          .onChange((value: string) => this.candidateQueryChanged(value)).onSubmit(() => this.loadCandidates(false))
        Button('搜索').fontSize(this.palette.bodySize).fontColor(this.palette.onAccent)
          .backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius).constraintSize({ minHeight: 46 })
          .enabled(!this.candidateLoading && this.candidateQuery.trim().length > 0).onClick(() => this.loadCandidates(false))
      }.width('100%')
      if (this.placeLabel(this.pickerPlace()).length > 0 && this.placeLabel(this.pickerPlace()) !== this.candidateQuery) {
        Button(`搜“${this.placeLabel(this.pickerPlace())}”`, { type: ButtonType.Normal })
          .fontSize(this.palette.metaSize).fontColor(this.palette.accent).backgroundColor(this.palette.accentSoft)
          .borderRadius(this.palette.controlRadius).constraintSize({ minHeight: 44 })
          .onClick(() => {
            this.candidateQueryChanged(this.placeLabel(this.pickerPlace()));
            this.loadCandidates(false);
          })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
    if (this.candidates.length > 0) {
      Text(`${this.candidates.length} 个候选入口`).fontSize(this.palette.bodySize).fontColor(this.palette.secondary)
      Column() {
        ForEach(this.candidates, (candidate: CampusPlaceCandidate, index: number) => {
          if (index > 0) { Divider().color(this.palette.line).margin({ left: 15, right: 15 }) }
          this.PlaceRow(candidate.name, candidate.address || '暂无地址', false, () => this.previewCandidate(index),
            this.pickerPlace() !== undefined && conflictingParcelBrand(this.pickerPlace()!, candidate.name))
        }, (candidate: CampusPlaceCandidate) => candidate.baidu_uid)
      }.width('100%').backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius).clip(true)
    }
    if (this.candidateLoading) {
      FeedbackPanel({ kind: 'loading', title: this.candidatePage < 0 ? '正在搜索地图入口' : '正在加载更多入口' })
    } else if (this.candidateError.length > 0) {
      FeedbackPanel({ kind: 'error', title: '入口尚未确认', message: this.candidateError,
        actionLabel: '重新搜索', onAction: () => this.loadCandidates(false) })
    } else if (this.candidatePage >= 0 && this.candidates.length === 0 && !this.candidatePageError) {
      FeedbackPanel({ kind: 'empty', title: '未找到校区内的入口',
        message: this.candidateHasMore ? '可加载下一页，或换一个关键词。' : '试试楼名、地标或门的方向。' })
    }
    if (this.candidateHasMore && !this.candidateLoading) {
      if (this.candidatePageError.length > 0) {
        Text(this.candidatePageError).fontSize(this.palette.metaSize).fontColor(this.palette.warning).width('100%')
      }
      Button(this.candidatePageError ? '重试加载下一页' : '加载更多入口', { type: ButtonType.Normal })
        .fontSize(this.palette.bodySize).fontColor(this.palette.accent).backgroundColor(this.palette.surface)
        .borderRadius(this.palette.controlRadius).width('100%').constraintSize({ minHeight: 44 }).onClick(() => this.loadCandidates(true))
    }
    if (this.candidateTruncated) {
      Text('可用更具体的门名缩小搜索范围。').fontSize(this.palette.metaSize).fontColor(this.palette.secondary)
    }
  }

  @Builder
  private CandidatePreview(candidate: CampusPlaceCandidate) {
    Column({ space: 6 }) {
      Text(`${this.candidateEndpoint === 'origin' ? '起点' : '终点'} · ${this.placeLabel(this.pickerPlace())}`)
        .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
      Text(candidate.name).fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold)
        .fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
      Text(candidate.address || '暂无地址，请核对地图位置。').fontSize(this.palette.metaSize)
        .fontColor(this.palette.secondary).width('100%').wordBreak(WordBreak.BREAK_WORD)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
    if (this.candidateConflict()) {
      Column({ space: 4 }) {
        Text('快递品牌与校园地点名称不同').fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
          .fontColor(this.palette.warning).width('100%')
        Row({ space: 5 }) {
          Checkbox({ name: 'map-entrance-confirmation' }).select(this.candidateAcknowledged)
            .selectedColor(this.palette.accent).enabled(!this.candidateSaving)
            .accessibilityText('仍将此入口保存到当前地点')
            .onChange((checked: boolean) => this.candidateAcknowledged = checked)
          Text('仍将此入口保存到当前地点').fontSize(this.palette.metaSize).fontColor(this.palette.ink).layoutWeight(1)
        }.width('100%').constraintSize({ minHeight: 44 })
      }.width('100%').padding({ left: 14, right: 14, top: 12 }).backgroundColor(this.palette.warningSoft)
        .borderRadius(this.palette.controlRadius)
    }
  }

  @Builder
  private RouteForm() {
    if (this.loading) {
      FeedbackPanel({ kind: 'loading', title: '正在读取校园地点' })
    } else if (this.placesError.length > 0) {
      FeedbackPanel({ kind: 'error', title: '地点暂不可用', message: this.placesError,
        actionLabel: '重试读取地点', onAction: () => this.loadPlaces() })
    } else if (this.places.length < 2) {
      FeedbackPanel({ kind: 'empty', title: '地点数据不足', message: '需要至少两个校园地点才能规划路线。',
        actionLabel: '重新读取', onAction: () => this.loadPlaces() })
    } else {
      Column({ space: 8 }) {
        Row() {
          Text('步行路线').fontSize(this.palette.sectionTitle).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
          Blank()
          if (this.route !== null) {
            Button('查看当前路线', { type: ButtonType.Normal }).fontSize(this.palette.metaSize).fontColor(this.palette.accent)
              .backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 })
              .onClick(() => this.routeFormExpanded = false)
          }
          Button('交换', { type: ButtonType.Normal }).fontSize(this.palette.metaSize).fontColor(this.palette.accent)
            .backgroundColor(Color.Transparent).constraintSize({ minWidth: 52, minHeight: 44 })
            .accessibilityText('交换起点和终点').enabled(this.originIndex >= 0 && this.destinationIndex >= 0).onClick(() => {
              this.getUIContext().animateTo({ duration: AppTheme.motion(200), curve: Curve.EaseOut }, () => this.swap());
            })
        }.width('100%')
        this.EndpointRow(this.places[this.originIndex], true)
        Divider().color(this.palette.line).margin({ left: 24 })
        this.EndpointRow(this.places[this.destinationIndex], false)
        if (this.routeActionLabel() === '按已保存入口规划') {
          Text('本次使用已保存的百度入口。').fontSize(this.palette.bodySize)
            .fontColor(this.palette.warning).width('100%').padding({ bottom: 4 })
        }
        Button(this.routeActionLabel())
          .width('100%').constraintSize({ minHeight: 48 }).fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium)
          .fontColor(this.palette.onAccent).backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
          .enabled(!this.routeLoading && !this.candidateSaving && this.originIndex >= 0 && this.destinationIndex >= 0)
          .onClick(() => this.performRouteAction())
      }.width('100%').padding({ left: this.palette.cardInset, right: this.palette.cardInset, top: 6, bottom: this.palette.cardInset })
        .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
      if (this.errorText.length > 0) {
        FeedbackPanel({ kind: 'error', title: '路线尚未生成', message: this.errorText,
          actionLabel: this.routeActionLabel(), busy: this.routeLoading, onAction: () => this.performRouteAction() })
      }
    }
  }

  @Builder
  private RouteResultHeader(route: CampusRoute) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(`约 ${route.total_minutes} 分钟`).fontSize(23).fontWeight(FontWeight.Bold).fontColor(this.palette.ink)
          .layoutWeight(1)
        Button('调整起终点', { type: ButtonType.Normal }).fontSize(this.palette.metaSize).fontColor(this.palette.accent)
          .backgroundColor(this.palette.accentSoft).borderRadius(this.palette.controlRadius)
          .constraintSize({ minHeight: 44 }).onClick(() => this.routeFormExpanded = true)
      }.width('100%')
      Text(`${route.distance_meters ?? 0} 米步行`).fontSize(this.palette.bodySize).fontColor(this.palette.secondary)
      Text(`${this.routedPlaceLabel(this.places[this.originIndex])} → ${this.routedPlaceLabel(this.places[this.destinationIndex])}`)
        .fontSize(this.palette.bodySize).fontColor(this.palette.ink).width('100%').wordBreak(WordBreak.BREAK_WORD)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(this.palette.cardInset)
      .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
  }

  @Builder
  private RouteDetails() {
    if (this.route !== null) {
      Column({ space: 0 }) {
        if (this.route.steps.length > 0) {
          InfoDisclosure({ title: '分段步行指引', message: this.walkingInstructions(this.route.steps) })
        }
        InfoDisclosure({ title: '路线说明', message: '百度地图提供步行路线。实际通行和耗时以现场情况为准。' })
        EvidencePanel({ evidence: this.route.evidence ?? [], active: this.active })
      }.width('100%').padding({ left: this.palette.cardInset, right: this.palette.cardInset })
        .backgroundColor(this.palette.surface).borderRadius(this.palette.cardRadius)
      this.PlaceEvidence(this.route.origin)
      this.PlaceEvidence(this.route.destination)
    } else if (this.mapActive()) {
      InfoDisclosure({ title: '地图说明', message: '可拖动或缩放地图。起点由你选择，应用不读取当前位置。' })
      EvidencePanel({ evidence: this.packageEvidence, active: this.active })
    }
  }

  build() {
    Column() {
      AppPageHeader({ title: this.pageTitle(), backEnabled: !this.candidateSaving, onBack: () => this.backPressed() })
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (this.choosingEndpoint.length > 0) {
            this.EndpointList()
          } else if (this.selectedCandidateIndex >= 0) {
            this.CandidatePreview(this.candidates[this.selectedCandidateIndex])
          } else if (this.candidateEndpoint.length > 0) {
            this.CandidateList()
          } else if (this.route !== null && !this.routeFormExpanded) {
            this.RouteResultHeader(this.route)
          } else {
            this.CourseContext()
            this.RouteForm()
          }
          if (this.choosingEndpoint.length === 0 && (this.candidateEndpoint.length === 0 || this.selectedCandidateIndex >= 0)) {
            if (this.candidateEndpoint.length === 0 && this.route === null && this.mapActive()) {
              Text(this.routeLoading ? '正在生成步行路线' : '地图预览 · 尚未生成路线')
                .fontSize(this.palette.metaSize).fontColor(this.palette.secondary).width('100%')
            }
            RouteMap({ baseUrl: this.baseUrl, token: this.token, active: this.mapActive(),
              preview: this.selectedCandidateIndex >= 0, mapHeight: this.selectedCandidateIndex >= 0 ? 290 : 365,
              route: this.route,
              origin: this.selectedCandidateIndex >= 0 && this.candidateEndpoint === 'destination' ? null :
                this.previewPlace(this.places[this.originIndex] ?? null, true),
              destination: this.selectedCandidateIndex >= 0 && this.candidateEndpoint === 'origin' ? null :
                this.previewPlace(this.places[this.destinationIndex] ?? null, false) })
            if (this.selectedCandidateIndex >= 0 && this.candidateError.length > 0) {
              FeedbackPanel({ kind: 'error', title: '入口尚未保存', message: this.candidateError })
            }
          }
          if (this.candidateEndpoint.length === 0 && this.choosingEndpoint.length === 0) { this.RouteDetails() }
        }.width('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
          .padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 8, bottom: 22 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
      if (this.selectedCandidateIndex >= 0) {
        Column() {
          Button(this.candidateSaving ? '正在保存…' : '保存此入口').width('100%').constraintSize({ minHeight: 48 })
            .fontSize(this.palette.bodySize).fontWeight(FontWeight.Medium).fontColor(this.palette.onAccent)
            .backgroundColor(this.palette.accent).borderRadius(this.palette.controlRadius)
            .enabled(!this.candidateSaving && (!this.candidateConflict() || this.candidateAcknowledged))
            .onClick(() => this.confirmCandidate())
        }.width('100%').padding({ left: this.palette.pageInset, right: this.palette.pageInset, top: 8, bottom: 10 })
          .backgroundColor(this.palette.surface).border({ width: { top: 1 }, color: this.palette.line })
      }
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start).backgroundColor(this.palette.bg)
  }
}
