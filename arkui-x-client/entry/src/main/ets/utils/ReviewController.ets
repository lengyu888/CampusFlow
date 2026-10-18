import { ReviewPeriod, ReviewSnapshot, ReviewGateway } from '../model/ReviewModels';
import { reviewRange, reviewToday } from './ReviewTime';
import { validateReview } from './ReviewValidation';
import { CampusFlowRequestError, localRequestFailure } from './AgentFeedback';

export interface ReviewState {
  phase: 'idle' | 'loading' | 'ready' | 'stale' | 'error';
  period: ReviewPeriod;
  anchor: string;
  snapshot: ReviewSnapshot | null;
  message: string;
  errorCode: string;
}
export function emptyReviewState(): ReviewState {
  return { phase: 'idle', period: 'day', anchor: reviewToday(), snapshot: null, message: '', errorCode: '' };
}
export class ReviewController {
  private state: ReviewState = emptyReviewState();
  private scope: string = '';
  private userId: string = '';
  private api: ReviewGateway | null = null;
  private active: boolean = false;
  private disposed: boolean = false;
  private generation: number = 0;
  private onChange: (state: ReviewState) => void;

  constructor(onChange: (state: ReviewState) => void) { this.onChange = onChange; }
  snapshot(): ReviewState { return JSON.parse(JSON.stringify(this.state)) as ReviewState; }
  private publish(): void { if (!this.disposed) { this.onChange(this.snapshot()); } }
  configure(scope: string, userId: string, api: ReviewGateway): void {
    if (this.disposed) { return; }
    if (scope === this.scope && userId === this.userId && api === this.api) { return; }
    this.generation++;
    const changed = scope !== this.scope || userId !== this.userId;
    this.scope = scope; this.userId = userId; this.api = api;
    if (changed) { this.state = emptyReviewState(); }
    else if (this.state.phase === 'loading') { this.state.phase = this.state.snapshot === null ? 'idle' : 'stale'; }
    this.publish();
  }
  setActive(active: boolean): void {
    if (this.disposed || active === this.active) { return; }
    this.active = active; this.generation++;
    if (!active) {
      if (this.state.phase === 'loading') {
        this.state.phase = this.state.snapshot === null ? 'idle' : 'stale';
        this.state.message = this.state.snapshot === null ? '' : '上次读取的回看仍保留，请刷新核对。';
      }
      this.publish(); return;
    }
    // Activation itself does not choose a date or issue a request. The page calls
    // select/refresh explicitly, avoiding a duplicate request before initial props.
    this.publish();
  }
  async select(period: ReviewPeriod, anchor: string): Promise<void> {
    if (this.disposed) { return; }
    const changed = period !== this.state.period || anchor !== this.state.anchor;
    if (changed) {
      this.generation++;
      this.state = { phase: 'idle', period: period, anchor: anchor, snapshot: null, message: '', errorCode: '' };
      this.publish();
    }
    await this.refresh();
  }
  async refresh(): Promise<void> {
    if (this.disposed || !this.active || this.api === null || this.scope.length === 0 || this.userId.length === 0) { return; }
    const period = this.state.period; const anchor = this.state.anchor;
    const generation = ++this.generation; const userId = this.userId; const scope = this.scope; const api = this.api;
    if (reviewRange(period, anchor) === null) {
      this.state.snapshot = null; this.state.phase = 'error'; this.state.errorCode = 'REVIEW_INVALID';
      this.state.message = localRequestFailure('REVIEW_INVALID').message; this.publish(); return;
    }
    this.state.phase = 'loading'; this.state.message = ''; this.state.errorCode = ''; this.publish();
    try {
      const result = await api.review(period, anchor);
      if (!this.current(generation, scope, userId)) { return; }
      if (!validateReview(result, userId, period, anchor)) { throw localRequestFailure('INVALID_RESPONSE'); }
      this.state.snapshot = JSON.parse(JSON.stringify(result)) as ReviewSnapshot;
      this.state.phase = 'ready'; this.state.message = ''; this.state.errorCode = ''; this.publish();
    } catch (error) {
      if (!this.current(generation, scope, userId)) { return; }
      const failure = error as CampusFlowRequestError;
      const code = ['REVIEW_INVALID','REVIEW_LIMIT','REVIEW_DATA_INVALID','REVIEW_FAILED','LOGIN_REQUIRED','NETWORK_ERROR','INVALID_RESPONSE','REQUEST_TIMEOUT']
        .includes(failure?.code ?? '') ? failure.code : 'REVIEW_FAILED';
      this.state.phase = this.state.snapshot === null ? 'error' : 'stale'; this.state.errorCode = code;
      this.state.message = localRequestFailure(code).message + (this.state.snapshot === null ? '' : ' 当前仍显示上次读取的资料。');
      this.publish();
    }
  }
  private current(generation: number, scope: string, userId: string): boolean {
    return !this.disposed && this.active && generation === this.generation && scope === this.scope && userId === this.userId;
  }
  dispose(): void {
    this.disposed = true; this.active = false; this.generation++; this.api = null; this.scope = ''; this.userId = '';
    this.state = emptyReviewState();
  }
}
