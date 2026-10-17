// Input snapshots only: these records are never authority to execute a server action.
export type DraftKind = 'assistant' | 'new-task' | 'onboarding' | 'timetable';
export type DraftOperationKind = 'run' | 'proposal' | 'onboarding' | 'timetable';

export interface DraftCourse {
  date: string;
  title: string;
  start_time: string;
  end_time: string;
  location: string;
  teacher: string;
}

export interface DraftIssue {
  index: number;
  relatedIndex: number;
  field: string;
  message: string;
}

export interface DraftCampusPlace {
  name: string;
  category: string;
  zone: string;
  aliases: string[];
}

export interface DraftCampusMap {
  campus_name: string;
  places: DraftCampusPlace[];
  warnings: string[];
}

export interface AssistantDraft {
  text: string;
  sessionId: string;
  anchorDate: string;
  timezone: string;
}

export interface NewTaskDraft {
  title: string;
  date: string;
  dateChoice: string;
  time: string;
  anchorDate: string;
  timezone: string;
}

export interface TimetableSubmission {
  operationId: string;
  expectedRevision: string;
  entries: DraftCourse[];
  confirmClear: boolean;
}

export interface OnboardingSubmission {
  operationId: string;
  expectedRevision: string;
  school: string;
  campus: string;
  semester: string;
  timetable: DraftCourse[];
  campusMap: DraftCampusMap;
}

export interface OnboardingDraft {
  school: string;
  campus: string;
  step: number;
  semester: string;
  entries: DraftCourse[];
  editor: DraftCourse;
  editorOpen: boolean;
  editorDirty: boolean;
  editingIndex: number;
  repeatWeeks: number;
  sourceWarnings: DraftIssue[];
  anchorDate: string;
  timezone: string;
  baselineEntries: DraftCourse[];
  expectedRevision: string;
  submission: OnboardingSubmission | null;
}

export interface TimetableDraft {
  baselineEntries: DraftCourse[];
  expectedRevision: string;
  draftEntries: DraftCourse[];
  editor: DraftCourse;
  editorOpen: boolean;
  editorDirty: boolean;
  editingIndex: number;
  repeatWeeks: number;
  sourceWarnings: DraftIssue[];
  anchorDate: string;
  timezone: string;
  submission: TimetableSubmission | null;
}

export type DraftPayload = AssistantDraft | NewTaskDraft | OnboardingDraft | TimetableDraft;

export interface DraftKey {
  kind: DraftKind;
  ownerId: string;
}

export interface DraftLease {
  scope: string;
  generation: number;
}

export interface DraftRecord {
  formatVersion: number;
  scope: string;
  kind: DraftKind;
  ownerId: string;
  localRevision: number;
  updatedAt: string;
  payload: DraftPayload;
}

export interface DraftTicket {
  localRevision: number;
}

export interface DraftRunRequest {
  run_id: string;
  session_id: string;
  model: string;
  message: string;
}

export interface DraftOperationInput {
  kind: DraftOperationKind;
  id: string;
  draftKind: DraftKind;
  ownerId: string;
  localRevision: number;
  fingerprint?: string;
  runRequest?: DraftRunRequest | null;
}

export interface DraftOperation {
  scope: string;
  kind: DraftOperationKind;
  id: string;
  draftKind: DraftKind;
  ownerId: string;
  localRevision: number;
  fingerprint: string;
  runRequest: DraftRunRequest | null;
}

export interface DraftSaveState {
  scope: string;
  generation: number;
  phase: string;
  message: string;
}

export interface DraftDriver {
  read(): Promise<string | undefined>;
  write(text: string): Promise<void>;
  remove(): Promise<void>;
}

export interface DraftScheduler {
  now(): number;
  set(callback: () => void, delayMs: number): number;
  clear(id: number): void;
}

interface DraftDocument {
  version: number;
  scope: string;
  revision: number;
  records: DraftRecord[];
  operations: DraftOperation[];
}

class SystemDraftScheduler implements DraftScheduler {
  now(): number { return Date.now(); }
  set(callback: () => void, delayMs: number): number { return setTimeout(callback, delayMs); }
  clear(id: number): void { clearTimeout(id); }
}

export const MAX_LOCAL_DRAFT_BYTES: number = 4 * 1024 * 1024;
export const MAX_DRAFT_RECORD_BYTES: number = 2 * 1024 * 1024;
export const MAX_LOCAL_DRAFTS: number = 20;
export const MAX_DRAFT_OPERATIONS: number = 40;

export function draftUtf8Bytes(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index++) {
    const unit = value.charCodeAt(index);
    if (unit < 0x80) {
      bytes++;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < value.length &&
      value.charCodeAt(index + 1) >= 0xDC00 && value.charCodeAt(index + 1) <= 0xDFFF) {
      bytes += 4;
      index++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

function invalid(): Error { return new Error('草稿格式或容量不符合要求，原有草稿未被覆盖。'); }

function text(value: string, maximum: number, required: boolean = false): string {
  if (typeof value !== 'string' || value.length > maximum || (required && value.length === 0)) {
    throw invalid();
  }
  return value;
}

function userText(value: string, maximum: number): string {
  if (typeof value !== 'string' || value.length === 0 || Array.from(value).length > maximum) { throw invalid(); }
  return value;
}

function integer(value: number, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) { throw invalid(); }
  return value;
}

function flag(value: boolean): boolean {
  if (typeof value !== 'boolean') { throw invalid(); }
  return value;
}

function kind(value: DraftKind): DraftKind {
  if (value !== 'assistant' && value !== 'new-task' && value !== 'onboarding' && value !== 'timetable') {
    throw invalid();
  }
  return value;
}

function operationKind(value: DraftOperationKind): DraftOperationKind {
  if (value !== 'run' && value !== 'proposal' && value !== 'onboarding' && value !== 'timetable') {
    throw invalid();
  }
  return value;
}

function timezone(value: string): string {
  if (value !== 'Asia/Shanghai') { throw invalid(); }
  return value;
}

function revision(value: string, allowEmpty: boolean = true): string {
  if (typeof value !== 'string' || (!/^[a-f0-9]{64}$/.test(value) && !(allowEmpty && value === ''))) {
    throw invalid();
  }
  return value;
}

function operationId(value: string): string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,160}$/.test(value)) { throw invalid(); }
  return value;
}

function course(value: DraftCourse): DraftCourse {
  if (!value || typeof value !== 'object' || Array.isArray(value)) { throw invalid(); }
  // Wider than submit validation: partially typed and invalid editors must survive restart.
  return { date: text(value.date, 64), title: text(value.title, 2048),
    start_time: text(value.start_time, 64), end_time: text(value.end_time, 64),
    location: text(value.location, 2048), teacher: text(value.teacher, 1024) };
}

function courses(values: DraftCourse[]): DraftCourse[] {
  if (!Array.isArray(values) || values.length > 500) { throw invalid(); }
  return values.map((value: DraftCourse): DraftCourse => course(value));
}

function issues(values: DraftIssue[]): DraftIssue[] {
  if (!Array.isArray(values) || values.length > 2000) { throw invalid(); }
  return values.map((value: DraftIssue): DraftIssue => {
    if (!value || typeof value !== 'object') { throw invalid(); }
    return { index: integer(value.index, -1, 499), relatedIndex: integer(value.relatedIndex, -1, 499),
      field: text(value.field, 80), message: text(value.message, 2048) };
  });
}

function strings(values: string[], maximum: number, length: number): string[] {
  if (!Array.isArray(values) || values.length > maximum) { throw invalid(); }
  return values.map((value: string): string => text(value, length));
}

function campusMap(value: DraftCampusMap): DraftCampusMap {
  if (!value || typeof value !== 'object' || !Array.isArray(value.places) || value.places.length > 500) {
    throw invalid();
  }
  return { campus_name: text(value.campus_name, 512), warnings: strings(value.warnings, 100, 2048),
    places: value.places.map((place: DraftCampusPlace): DraftCampusPlace => {
      if (!place || typeof place !== 'object') { throw invalid(); }
      return { name: text(place.name, 512), category: text(place.category, 128),
        zone: text(place.zone, 512), aliases: strings(place.aliases, 100, 512) };
    }) };
}

function timetableSubmission(value: TimetableSubmission | null): TimetableSubmission | null {
  if (value === null) { return null; }
  if (!value || typeof value !== 'object') { throw invalid(); }
  return { operationId: operationId(value.operationId), expectedRevision: revision(value.expectedRevision, false),
    entries: courses(value.entries), confirmClear: flag(value.confirmClear) };
}

function onboardingSubmission(value: OnboardingSubmission | null): OnboardingSubmission | null {
  if (value === null) { return null; }
  if (!value || typeof value !== 'object') { throw invalid(); }
  return { operationId: operationId(value.operationId), expectedRevision: revision(value.expectedRevision, false),
    school: text(value.school, 512), campus: text(value.campus, 512), semester: text(value.semester, 512),
    timetable: courses(value.timetable), campusMap: campusMap(value.campusMap) };
}

function payload(valueKind: DraftKind, value: DraftPayload): DraftPayload {
  if (!value || typeof value !== 'object' || Array.isArray(value)) { throw invalid(); }
  if (valueKind === 'assistant') {
    const item = value as AssistantDraft;
    return { text: text(item.text, 32000), sessionId: text(item.sessionId, 512, true),
      anchorDate: text(item.anchorDate, 32), timezone: timezone(item.timezone) } as AssistantDraft;
  }
  if (valueKind === 'new-task') {
    const item = value as NewTaskDraft;
    return { title: text(item.title, 2048), date: text(item.date, 64), dateChoice: text(item.dateChoice, 64),
      time: text(item.time, 64), anchorDate: text(item.anchorDate, 32), timezone: timezone(item.timezone) } as NewTaskDraft;
  }
  if (valueKind === 'onboarding') {
    const item = value as OnboardingDraft;
    const entries = courses(item.entries);
    return { school: text(item.school, 512), campus: text(item.campus, 512), step: integer(item.step, 0, 10),
      semester: text(item.semester, 512), entries: entries, editor: course(item.editor),
      editorOpen: flag(item.editorOpen), editorDirty: flag(item.editorDirty),
      editingIndex: integer(item.editingIndex, -1, entries.length - 1), repeatWeeks: integer(item.repeatWeeks, 1, 24),
      sourceWarnings: issues(item.sourceWarnings), anchorDate: text(item.anchorDate, 32), timezone: timezone(item.timezone),
      baselineEntries: courses(item.baselineEntries), expectedRevision: revision(item.expectedRevision),
      submission: onboardingSubmission(item.submission) } as OnboardingDraft;
  }
  const item = value as TimetableDraft;
  const entries = courses(item.draftEntries);
  return { baselineEntries: courses(item.baselineEntries), expectedRevision: revision(item.expectedRevision),
    draftEntries: entries, editor: course(item.editor), editorOpen: flag(item.editorOpen),
    editorDirty: flag(item.editorDirty), editingIndex: integer(item.editingIndex, -1, entries.length - 1),
    repeatWeeks: integer(item.repeatWeeks, 1, 24), sourceWarnings: issues(item.sourceWarnings),
    anchorDate: text(item.anchorDate, 32), timezone: timezone(item.timezone),
    submission: timetableSubmission(item.submission) } as TimetableDraft;
}

function record(value: DraftRecord, scope: string): DraftRecord {
  if (!value || typeof value !== 'object' || value.formatVersion !== 1 || value.scope !== scope ||
      typeof value.updatedAt !== 'string' || !Number.isFinite(Date.parse(value.updatedAt))) { throw invalid(); }
  const valueKind = kind(value.kind);
  const result: DraftRecord = { formatVersion: 1, scope: scope, kind: valueKind,
    ownerId: text(value.ownerId, 512, true), localRevision: integer(value.localRevision, 1, Number.MAX_SAFE_INTEGER),
    updatedAt: value.updatedAt, payload: payload(valueKind, value.payload) };
  if (draftUtf8Bytes(JSON.stringify(result)) > MAX_DRAFT_RECORD_BYTES) { throw invalid(); }
  return result;
}

function operation(value: DraftOperationInput, scope: string): DraftOperation {
  if (!value || typeof value !== 'object') { throw invalid(); }
  const fingerprint = value.fingerprint === undefined ? '' : value.fingerprint;
  if (typeof fingerprint !== 'string' || (fingerprint !== '' && !/^[a-f0-9]{16,128}$/.test(fingerprint))) {
    throw invalid();
  }
  const result: DraftOperation = { scope: scope, kind: operationKind(value.kind), id: operationId(value.id),
    draftKind: kind(value.draftKind), ownerId: text(value.ownerId, 512, true),
    localRevision: integer(value.localRevision, 1, Number.MAX_SAFE_INTEGER), fingerprint: fingerprint, runRequest: null };
  if ((result.kind === 'run' && result.draftKind !== 'assistant') ||
      (result.kind === 'proposal' && result.draftKind !== 'new-task') ||
      (result.kind === 'onboarding' && result.draftKind !== 'onboarding') ||
      (result.kind === 'timetable' && result.draftKind !== 'timetable')) { throw invalid(); }
  if (value.runRequest !== undefined && value.runRequest !== null) {
    const request = value.runRequest;
    if (result.kind !== 'run' || typeof request !== 'object' || request.run_id !== result.id ||
        typeof request.model !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/.test(request.model)) { throw invalid(); }
    result.runRequest = { run_id: result.id, session_id: userText(request.session_id, 128),
      model: request.model, message: userText(request.message, 8000) };
  }
  return result;
}

function emptyDocument(scope: string = ''): DraftDocument {
  return { version: 1, scope: scope, revision: 0, records: [], operations: [] };
}

function cloneDocument(value: DraftDocument): DraftDocument {
  if (!value || typeof value !== 'object' || value.version !== 1 || !Array.isArray(value.records) ||
      !Array.isArray(value.operations) || value.records.length > MAX_LOCAL_DRAFTS ||
      value.operations.length > MAX_DRAFT_OPERATIONS) { throw invalid(); }
  const scope = text(value.scope, 4096);
  const latest = integer(value.revision, 0, Number.MAX_SAFE_INTEGER);
  if (scope.length === 0 && (value.records.length > 0 || value.operations.length > 0)) { throw invalid(); }
  const result = emptyDocument(scope);
  result.revision = latest;
  for (const item of value.records) {
    const next = record(item, scope);
    if (next.localRevision > latest || result.records.some((previous: DraftRecord): boolean =>
      previous.kind === next.kind && previous.ownerId === next.ownerId)) { throw invalid(); }
    result.records.push(next);
  }
  for (const item of value.operations) {
    if (item.scope !== scope) { throw invalid(); }
    const next = operation(item, scope);
    if (next.localRevision > latest || result.operations.some((previous: DraftOperation): boolean =>
      previous.kind === next.kind && previous.id === next.id)) { throw invalid(); }
    result.operations.push(next);
  }
  if (draftUtf8Bytes(JSON.stringify(result)) > MAX_LOCAL_DRAFT_BYTES) { throw invalid(); }
  return result;
}

function matches(value: DraftRecord, key: DraftKey): boolean {
  return value.kind === key.kind && value.ownerId === key.ownerId;
}

export class DraftStore {
  private driver: DraftDriver;
  private scheduler: DraftScheduler;
  private document: DraftDocument = emptyDocument();
  private initialized: boolean = false;
  private generation: number = 0;
  private visible: boolean = false;
  private timer: number = -1;
  private queue: Promise<void> = Promise.resolve();
  private savedRevision: number = -1;
  private inputRejected: boolean = false;
  private state: DraftSaveState = { scope: '', generation: 0, phase: 'unavailable', message: '本机草稿尚未初始化。' };
  private listeners: ((state: DraftSaveState) => void)[] = [];

  constructor(driver: DraftDriver, scheduler: DraftScheduler = new SystemDraftScheduler()) {
    this.driver = driver;
    this.scheduler = scheduler;
  }

  private enqueue<T>(action: () => Promise<T>): Promise<T> {
    const result = this.queue.then(action);
    this.queue = result.then((): void => {}, (): void => {});
    return result;
  }

  private publish(phase: string, message: string): void {
    if (phase === 'saved' && this.inputRejected) {
      phase = 'error'; message = '最近一次输入尚未保存，请调整草稿后重试。';
    }
    this.state = { scope: this.visible ? this.document.scope : '', generation: this.generation, phase: phase, message: message };
    for (const listener of this.listeners) {
      try { listener(this.copyState()); } catch { /* A view cannot break persistence. */ }
    }
  }

  private copyState(): DraftSaveState {
    return { scope: this.state.scope, generation: this.state.generation, phase: this.state.phase, message: this.state.message };
  }

  subscribe(listener: (state: DraftSaveState) => void): () => void {
    this.listeners.push(listener);
    try { listener(this.copyState()); } catch { /* Same isolation as later notifications. */ }
    return (): void => { this.listeners = this.listeners.filter((item): boolean => item !== listener); };
  }

  private cancelTimer(): void {
    if (this.timer >= 0) { this.scheduler.clear(this.timer); this.timer = -1; }
  }

  async initialize(): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      if (this.initialized) { return; }
      try {
        const source = await this.driver.read();
        if (source !== undefined && draftUtf8Bytes(source) > MAX_LOCAL_DRAFT_BYTES) { throw invalid(); }
        this.document = source === undefined ? emptyDocument() : cloneDocument(JSON.parse(source) as DraftDocument);
        this.savedRevision = this.document.revision;
        this.initialized = true;
        this.publish('idle', '登录后可查看本机草稿。');
      } catch {
        this.publish('unavailable', '本机草稿读取失败，未覆盖原文件。可明确清除本机草稿后重试。');
        throw new Error(this.state.message);
      }
    });
  }

  activate(scope: string): Promise<DraftLease> {
    const requestedScope = text(scope, 4096, true);
    const generation = ++this.generation;
    this.visible = false;
    this.cancelTimer();
    this.publish('loading', '正在读取本机草稿。');
    return this.enqueue(async (): Promise<DraftLease> => {
      if (!this.initialized) {
        if (generation === this.generation) { this.publish('unavailable', '本机草稿尚不可用，未覆盖原文件。'); }
        throw new Error('本机草稿尚不可用，未覆盖原文件。');
      }
      if (generation !== this.generation) { throw new Error('账号已变化，旧草稿操作已停止。'); }
      const candidate = this.document.scope === requestedScope ? cloneDocument(this.document) : emptyDocument(requestedScope);
      try {
        // Commit account replacement before granting access to any record.
        await this.driver.write(JSON.stringify(candidate));
        this.document = candidate;
        this.savedRevision = candidate.revision;
        if (generation !== this.generation) { throw new Error('账号已变化，旧草稿操作已停止。'); }
        this.visible = true;
        this.inputRejected = false;
        this.publish('idle', '本机草稿已就绪。');
        return { scope: requestedScope, generation: generation };
      } catch {
        if (generation === this.generation) {
          this.publish('unavailable', '本机草稿切换失败，当前未开放草稿内容。请重试或清除本机草稿。');
        }
        throw new Error('本机草稿切换失败，当前未开放草稿内容。');
      }
    });
  }

  valid(lease: DraftLease): boolean {
    return !!lease && this.initialized && this.visible && lease.generation === this.generation &&
      lease.scope === this.document.scope;
  }

  private requireLease(lease: DraftLease): void {
    if (!this.valid(lease)) { throw new Error('账号已变化或本机草稿不可用，旧草稿操作已停止。'); }
  }

  status(lease: DraftLease): DraftSaveState {
    if (!this.valid(lease)) {
      return { scope: '', generation: this.generation, phase: 'unavailable', message: '此账号的草稿访问已失效。' };
    }
    return this.copyState();
  }

  list(lease: DraftLease, valueKind: DraftKind): DraftRecord[] {
    if (!this.valid(lease)) { return []; }
    return this.document.records.filter((item: DraftRecord): boolean => item.kind === valueKind)
      .map((item: DraftRecord): DraftRecord => record(item, lease.scope))
      .sort((left: DraftRecord, right: DraftRecord): number => right.localRevision - left.localRevision);
  }

  read(lease: DraftLease, key: DraftKey): DraftRecord | undefined {
    if (!this.valid(lease)) { return undefined; }
    const item = this.document.records.find((value: DraftRecord): boolean => matches(value, key));
    return item === undefined ? undefined : record(item, lease.scope);
  }

  stage(lease: DraftLease, key: DraftKey, value: DraftPayload): DraftTicket {
    this.requireLease(lease);
    try {
      const candidate = cloneDocument(this.document);
      const next: DraftRecord = record({ formatVersion: 1, scope: lease.scope, kind: kind(key.kind),
        ownerId: text(key.ownerId, 512, true), localRevision: this.document.revision + 1,
        updatedAt: new Date(this.scheduler.now()).toISOString(), payload: value }, lease.scope);
      const index = candidate.records.findIndex((item: DraftRecord): boolean => matches(item, key));
      if (index >= 0) { candidate.records[index] = next; } else { candidate.records.push(next); }
      candidate.revision = next.localRevision;
      this.document = cloneDocument(candidate);
      this.inputRejected = false;
      this.publish('pending', '更改尚未保存到本机。');
      this.cancelTimer();
      const captured: DraftLease = { scope: lease.scope, generation: lease.generation };
      this.timer = this.scheduler.set((): void => {
        this.timer = -1;
        this.flush(captured).catch((): void => {});
      }, 300);
      return { localRevision: next.localRevision };
    } catch {
      this.cancelTimer();
      this.inputRejected = true;
      this.publish('error', '本次草稿超出格式或容量限制，尚未保存；原有草稿仍保留。');
      throw invalid();
    }
  }

  flush(lease: DraftLease): Promise<void> {
    // A late callback from a logged-out page must not cancel the new account's debounce.
    if (this.valid(lease)) { this.cancelTimer(); }
    return this.enqueue(async (): Promise<void> => {
      this.requireLease(lease);
      if (this.inputRejected) { throw new Error('最近一次输入尚未保存，请调整草稿后重试。'); }
      if (this.savedRevision === this.document.revision) { return; }
      const candidate = cloneDocument(this.document);
      this.publish('saving', '正在保存到本机。');
      try {
        await this.driver.write(JSON.stringify(candidate));
        this.requireLease(lease);
        this.savedRevision = candidate.revision;
        if (this.inputRejected) { throw new Error('最近一次输入尚未保存。'); }
        this.publish(this.document.revision === candidate.revision ? 'saved' : 'pending',
          this.document.revision === candidate.revision ? '已保存到本机。' : '新更改尚未保存到本机。');
      } catch {
        if (this.valid(lease)) { this.publish('error', '尚未保存到本机，请重试；当前输入仍保留。'); }
        throw new Error('草稿尚未保存到本机。');
      }
    });
  }

  operations(lease: DraftLease): DraftOperation[] {
    if (!this.valid(lease)) { return []; }
    return this.document.operations.map((value: DraftOperation): DraftOperation => operation(value, lease.scope));
  }

  isBlocked(lease: DraftLease, key: DraftKey, localRevision?: number): boolean {
    if (!this.valid(lease)) { return true; }
    return this.document.operations.some((item: DraftOperation): boolean => item.draftKind === key.kind &&
      item.ownerId === key.ownerId && (localRevision === undefined || item.localRevision === localRevision));
  }

  async beginOperation(lease: DraftLease, input: DraftOperationInput): Promise<void> {
    this.requireLease(lease);
    const next = operation(input, lease.scope);
    const existing = this.document.operations.find((item: DraftOperation): boolean => item.kind === next.kind && item.id === next.id);
    if (existing !== undefined) {
      if (JSON.stringify(existing) !== JSON.stringify(next)) { throw new Error('待核对操作标识已关联另一份草稿。'); }
    } else {
      const source = this.document.records.find((item: DraftRecord): boolean => item.kind === next.draftKind &&
        item.ownerId === next.ownerId && item.localRevision === next.localRevision);
      if (source === undefined) { throw new Error('提交前草稿已经变化，请重新核对。'); }
      const candidate = cloneDocument(this.document);
      candidate.operations.push(next);
      candidate.revision++;
      this.document = cloneDocument(candidate);
      this.publish('pending', '正在保存操作恢复标识，完成后才能提交。');
    }
    // Failure deliberately leaves an in-memory block. No caller may POST after rejection.
    await this.flush(lease);
    this.requireLease(lease);
    if (!this.document.operations.some((item: DraftOperation): boolean => item.kind === next.kind && item.id === next.id)) {
      throw new Error('该操作已完成核对，请勿再次提交旧请求。');
    }
  }

  resolveOperation(lease: DraftLease, valueKind: DraftOperationKind, id: string, removeMatchingDraft: boolean = false): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      this.requireLease(lease);
      const resolved = this.document.operations.find((item: DraftOperation): boolean => item.kind === valueKind && item.id === id);
      if (resolved === undefined) { return; }
      const candidate = cloneDocument(this.document);
      candidate.operations = candidate.operations.filter((item: DraftOperation): boolean => !(item.kind === valueKind && item.id === id));
      if (removeMatchingDraft) {
        candidate.records = candidate.records.filter((item: DraftRecord): boolean => item.kind !== resolved.draftKind ||
          item.ownerId !== resolved.ownerId || item.localRevision !== resolved.localRevision);
      }
      // Reserve a revision synchronously with snapshot creation; newer keystrokes get a higher one.
      candidate.revision = ++this.document.revision;
      try {
        await this.driver.write(JSON.stringify(candidate));
        this.requireLease(lease);
        this.document.operations = this.document.operations.filter((item: DraftOperation): boolean => !(item.kind === valueKind && item.id === id));
        // Success must remove the consumed input in this same atomic replacement: a crash
        // between two separate writes must not reopen an already-applied input as a new draft.
        if (removeMatchingDraft) {
          this.document.records = this.document.records.filter((item: DraftRecord): boolean => item.kind !== resolved.draftKind ||
            item.ownerId !== resolved.ownerId || item.localRevision !== resolved.localRevision);
        }
        this.savedRevision = candidate.revision;
        this.publish(this.document.revision === candidate.revision ? 'saved' : 'pending',
          this.document.revision === candidate.revision ? '核对结果已保存。' : '新更改尚未保存到本机。');
      } catch {
        if (this.valid(lease)) { this.publish('error', '核对结果尚未保存，仍保留待核对标识。请重新核对后重试。'); }
        throw new Error('核对结果尚未保存，待核对标识仍保留。');
      }
    });
  }

  remove(lease: DraftLease, key: DraftKey, expectedLocalRevision: number): Promise<boolean> {
    return this.enqueue(async (): Promise<boolean> => {
      this.requireLease(lease);
      if (this.isBlocked(lease, key)) { return false; }
      const current = this.document.records.find((item: DraftRecord): boolean => matches(item, key));
      if (current === undefined || current.localRevision !== expectedLocalRevision) { return false; }
      const candidate = cloneDocument(this.document);
      candidate.records = candidate.records.filter((item: DraftRecord): boolean => !matches(item, key));
      candidate.revision = ++this.document.revision;
      try {
        await this.driver.write(JSON.stringify(candidate));
        this.requireLease(lease);
        const nowBlocked = this.isBlocked(lease, key);
        if (!nowBlocked) {
          this.document.records = this.document.records.filter((item: DraftRecord): boolean =>
            !matches(item, key) || item.localRevision !== expectedLocalRevision);
        }
        this.savedRevision = candidate.revision;
        this.publish(this.document.revision === candidate.revision ? 'saved' : 'pending',
          this.document.revision === candidate.revision ? '该版本草稿已移除。' : '新更改尚未保存到本机。');
        return !nowBlocked;
      } catch {
        if (this.valid(lease)) { this.publish('error', '草稿移除失败，原有草稿仍保留。'); }
        throw new Error('草稿移除失败，原有草稿仍保留。');
      }
    });
  }

  clear(): Promise<void> {
    const generation = ++this.generation;
    this.visible = false;
    this.cancelTimer();
    this.publish('pending', '正在清除本机草稿。');
    return this.enqueue(async (): Promise<void> => {
      try {
        await this.driver.remove();
        this.document = emptyDocument();
        this.savedRevision = 0;
        this.inputRejected = false;
        this.initialized = true;
        if (generation === this.generation) { this.publish('idle', '本机草稿已清除。'); }
      } catch {
        // Still hidden and old leases invalid, even if the filesystem cannot be cleared.
        if (generation === this.generation) { this.publish('error', '本机草稿清理失败，请重试；旧草稿未重新开放。'); }
        throw new Error('本机草稿清理失败，请重试。');
      }
    });
  }
}
