import { FocusRequest, FocusOperation, FocusInterval, FocusGap, FocusRecordState } from '../model/FocusModels';
import { FocusAnchor, validFocusSample, FocusTimer } from './FocusTimer';
import { focusUuid, focusInteger, focusKeys, focusTarget, validFocusRequest, validFocusPieces, validFocusOperation } from './FocusValidation';

export const MAX_FOCUS_BYTES: number = 4 * 1024 * 1024;
export interface FocusLease { scope: string; generation: number; }
export interface FocusDriver { read(): Promise<string | undefined>; write(value: string): Promise<void>; remove(): Promise<void>; }
export type FocusLocalState = 'starting' | 'running' | 'paused' | 'interrupted' | 'ended';
export interface LocalFocusRecord {
  recordId: string; taskId: string; mode: 'online' | 'offline'; localState: FocusLocalState; revision: number;
  confirmedRevision: number; confirmedState: FocusRecordState | null; targetMs: number | null;
  baseElapsedMs: number; confirmedElapsedMs: number; segmentId: string | null; clockSessionId: string | null; anchor: FocusAnchor | null;
  intervals: FocusInterval[]; gaps: FocusGap[];
}
export interface LocalFocusOperation {
  recordId: string; request: FocusRequest; dispatchState: 'queued' | 'unknown' | 'not_found' | 'conflict';
  receipt: FocusOperation | null; errorCode: string;
}
export interface FocusDocument {
  schemaVersion: number; scope: string; revision: number; deviceId: string;
  records: LocalFocusRecord[]; operations: LocalFocusOperation[];
}
export function focusBytes(value: string): number {
  let bytes = 0;
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code < 0x80) { bytes++; } else if (code < 0x800) { bytes += 2; }
    else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length && value.charCodeAt(index + 1) >= 0xdc00 && value.charCodeAt(index + 1) <= 0xdfff) { bytes += 4; index++; }
    else { bytes += 3; }
  }
  return bytes;
}
function emptyDocument(): FocusDocument { return { schemaVersion: 1, scope: '', revision: 0, deviceId: '', records: [], operations: [] }; }
function invalid(): Error { return new Error('本机专注记录格式不可核验，未覆盖原文件。'); }
export function validFocusAnchor(anchor: FocusAnchor, recordId: string): boolean {
  if (!focusKeys(anchor, ['recordId','segmentId','intervalId','clockSessionId','sequence','firstSample','lastAcceptedSample','elapsedMs']) ||
    anchor.recordId !== recordId || !focusUuid(anchor.segmentId) || !focusUuid(anchor.intervalId) || !focusUuid(anchor.clockSessionId) ||
    !focusInteger(anchor.sequence, 1) || !validFocusSample(anchor.firstSample) || !validFocusSample(anchor.lastAcceptedSample) ||
    !focusKeys(anchor.firstSample, ['wallMs','monotonicMs','clockSessionId']) || !focusKeys(anchor.lastAcceptedSample, ['wallMs','monotonicMs','clockSessionId']) ||
    anchor.firstSample.clockSessionId !== anchor.clockSessionId || anchor.lastAcceptedSample.clockSessionId !== anchor.clockSessionId ||
    !focusInteger(anchor.elapsedMs, 0, 86400000) || anchor.elapsedMs !== anchor.lastAcceptedSample.monotonicMs - anchor.firstSample.monotonicMs ||
    Math.abs(anchor.lastAcceptedSample.wallMs - anchor.firstSample.wallMs - anchor.elapsedMs) > 2000) { return false; }
  return true;
}
function validLocalRecord(value: LocalFocusRecord): boolean {
  return focusKeys(value, ['recordId','taskId','mode','localState','revision','confirmedRevision','confirmedState','targetMs','baseElapsedMs',
    'confirmedElapsedMs','segmentId','clockSessionId','anchor','intervals','gaps']) && focusUuid(value.recordId) && typeof value.taskId === 'string' && value.taskId.trim().length > 0 && value.taskId.length <= 128 &&
    ['online','offline'].includes(value.mode) && ['starting','running','paused','interrupted','ended'].includes(value.localState) &&
    focusInteger(value.revision) && focusInteger(value.confirmedRevision) && value.confirmedRevision <= value.revision &&
    (value.confirmedState === null || ['running','paused','ended'].includes(value.confirmedState)) && focusTarget(value.targetMs) &&
    focusInteger(value.baseElapsedMs) && focusInteger(value.confirmedElapsedMs) &&
    (value.segmentId === null || focusUuid(value.segmentId)) && (value.clockSessionId === null || focusUuid(value.clockSessionId)) &&
    ((value.segmentId === null) === (value.clockSessionId === null)) && validFocusPieces(value.intervals, value.gaps, 2000) &&
    (value.anchor === null ? value.localState !== 'running' : validFocusAnchor(value.anchor, value.recordId) && value.anchor.segmentId === value.segmentId && value.anchor.clockSessionId === value.clockSessionId) &&
    (value.anchor === null || !value.intervals.some((item: FocusInterval) => item.interval_id === value.anchor?.intervalId));
}
export function cloneFocusDocument(value: FocusDocument): FocusDocument {
  if (!focusKeys(value, ['schemaVersion','scope','revision','deviceId','records','operations']) || value.schemaVersion !== 1 ||
    typeof value.scope !== 'string' || value.scope.length > 1024 || !focusInteger(value.revision) ||
    (value.scope === '' ? value.deviceId !== '' : !focusUuid(value.deviceId)) || !Array.isArray(value.records) || value.records.length > 20 ||
    !Array.isArray(value.operations) || value.operations.length > 100 ||
    value.scope === '' && (value.records.length > 0 || value.operations.length > 0) ||
    !value.records.every((record: LocalFocusRecord) => validLocalRecord(record)) ||
    new Set(value.records.map((record: LocalFocusRecord) => record.recordId)).size !== value.records.length ||
    value.records.filter((record: LocalFocusRecord) => record.localState !== 'ended').length > 1) { throw invalid(); }
  const operationIds: string[] = [];
  for (const operation of value.operations) {
    if (!focusKeys(operation, ['recordId','request','dispatchState','receipt','errorCode']) || !focusUuid(operation.recordId) ||
      !value.records.some((record: LocalFocusRecord) => record.recordId === operation.recordId) || !validFocusRequest(operation.request) ||
      operation.request.device_id !== value.deviceId || !['queued','unknown','not_found','conflict'].includes(operation.dispatchState) ||
      typeof operation.errorCode !== 'string' || !/^[A-Z_]{0,80}$/.test(operation.errorCode) || operationIds.includes(operation.request.operation_id) ||
      operation.receipt !== null && !validFocusOperation(operation.receipt, operation.receipt.user_id, operation.recordId, operation.request)) { throw invalid(); }
    operationIds.push(operation.request.operation_id);
  }
  if (focusBytes(JSON.stringify(value)) > MAX_FOCUS_BYTES) { throw invalid(); }
  return JSON.parse(JSON.stringify(value)) as FocusDocument;
}
// Serial, atomic, scope-bound snapshots; no server upsert and no generic payload.
export class FocusStore {
  private driver: FocusDriver;
  private document: FocusDocument = emptyDocument();
  private initialized: boolean = false;
  private blocked: boolean = false;
  private generation: number = 0;
  private tail: Promise<void> = Promise.resolve();
  constructor(driver: FocusDriver) { this.driver = driver; }
  private enqueue(work: () => Promise<void>): Promise<void> {
    const result = this.tail.then(work); this.tail = result.catch(() => {}); return result;
  }
  async initialize(): Promise<void> {
    if (this.initialized) { return; }
    await this.enqueue(async () => {
      if (this.initialized) { return; }
      try {
        const raw = await this.driver.read();
        if (raw !== undefined && focusBytes(raw) > MAX_FOCUS_BYTES) { throw invalid(); }
        this.document = raw === undefined ? emptyDocument() : cloneFocusDocument(JSON.parse(raw) as FocusDocument);
        this.initialized = true; this.blocked = false;
      } catch { this.blocked = true; throw invalid(); }
    });
  }
  async activate(scope: string, deviceId: string = ''): Promise<FocusLease> {
    if (!this.initialized || this.blocked || scope.trim().length === 0 || scope.length > 1024) { throw invalid(); }
    const generation = this.generation;
    await this.enqueue(async () => {
      if (generation !== this.generation || this.blocked) { throw invalid(); }
      if (this.document.scope !== '' && this.document.scope !== scope) { throw new Error('请先明确清理原账号的本机专注记录。'); }
      if (this.document.scope === '') {
        if (!focusUuid(deviceId)) { throw invalid(); }
        const next: FocusDocument = { schemaVersion: 1, scope: scope, revision: 1, deviceId: deviceId, records: [], operations: [] };
        await this.driver.write(JSON.stringify(next));
        if (generation !== this.generation || this.blocked) { throw invalid(); }
        this.document = next;
      }
    });
    if (generation !== this.generation || this.blocked) { throw invalid(); }
    return { scope: scope, generation: generation };
  }
  valid(lease: FocusLease): boolean { return this.initialized && !this.blocked && lease.scope === this.document.scope && lease.generation === this.generation; }
  snapshot(lease: FocusLease): FocusDocument { if (!this.valid(lease)) { throw invalid(); } return cloneFocusDocument(this.document); }
  commit(lease: FocusLease, expectedRevision: number, value: FocusDocument): Promise<void> {
    const candidate = cloneFocusDocument(value);
    if (candidate.scope !== lease.scope || candidate.revision !== expectedRevision + 1) { return Promise.reject(invalid()); }
    return this.enqueue(async () => {
      if (!this.valid(lease) || this.document.revision !== expectedRevision || candidate.deviceId !== this.document.deviceId) { throw new Error('本机专注记录已变化，请重新核对。'); }
      for (const original of this.document.operations) {
        const next = candidate.operations.find((item: LocalFocusOperation) => item.request.operation_id === original.request.operation_id);
        if (next !== undefined && (next.recordId !== original.recordId || JSON.stringify(next.request) !== JSON.stringify(original.request))) { throw invalid(); }
      }
      await this.driver.write(JSON.stringify(candidate));
      if (!this.valid(lease)) { throw invalid(); }
      this.document = candidate;
    });
  }
  clear(): Promise<void> {
    this.generation++; this.blocked = true;
    return this.enqueue(async () => {
      try { await this.driver.remove(); this.document = emptyDocument(); this.initialized = true; this.blocked = false; }
      catch { throw new Error('本机专注记录清理未完成，不能切换账号继续写入。'); }
    });
  }
}
