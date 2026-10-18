// Focus records describe measured foreground intervals, never learning effectiveness.
// Raw monotonic/boot timestamps are local-only and must never enter FocusRequest.
export interface FocusClockSample { wallMs: number; monotonicMs: number; clockSessionId: string; }
export interface FocusClock { sample(): Promise<FocusClockSample>; }
export type FocusKind = 'start' | 'pause' | 'resume' | 'end' | 'delete';
export type FocusRecordState = 'running' | 'paused' | 'ended';
export interface FocusInterval {
  interval_id: string;
  segment_id: string;
  clock_session_id: string;
  sequence: number;
  started_at: string;
  ended_at: string;
  elapsed_ms: number;
}
export interface FocusGap {
  gap_id: string;
  segment_id: string;
  reason: 'process_interrupted' | 'clock_changed' | 'sample_gap' | 'remote_end' | 'storage_failed';
  observed_start_at: string;
  observed_end_at: string | null;
}
export interface FocusRequestBase {
  operation_id: string;
  expected_revision: number;
  device_id: string;
  occurred_at: string;
}
export interface FocusStartRequest extends FocusRequestBase {
  kind: 'start'; task_id: string; clock_session_id: string; target_ms: number | null;
}
export interface FocusResumeRequest extends FocusRequestBase {
  kind: 'resume'; clock_session_id: string;
}
export interface FocusPauseRequest extends FocusRequestBase {
  kind: 'pause'; segment_id: string; clock_session_id: string;
  intervals: FocusInterval[]; unknown_gaps: FocusGap[];
}
export interface FocusEndRequest extends FocusRequestBase {
  kind: 'end'; reason: 'local_end' | 'remote_end';
  segment_id: string | null; clock_session_id: string | null;
  intervals: FocusInterval[]; unknown_gaps: FocusGap[];
}
export interface FocusDeleteRequest extends FocusRequestBase { kind: 'delete'; }
export type FocusRequest = FocusStartRequest | FocusResumeRequest | FocusPauseRequest | FocusEndRequest | FocusDeleteRequest;
export type FocusOperationRequest = FocusRequest;
export interface FocusRecord {
  contract_version: number;
  user_id: string;
  record_id: string;
  task_id: string;
  task_title: string | null;
  task_missing: boolean;
  state: FocusRecordState;
  revision: number;
  creator_device_id: string;
  current_device_id: string;
  clock_session_id: string | null;
  segment_id: string | null;
  started_at: string;
  ended_at: string | null;
  target_ms: number | null;
  confirmed_elapsed_ms: number;
  interval_count: number;
  unknown_gap_count: number;
  created_at: string;
  updated_at: string;
}
export interface FocusReceipt {
  before_revision: number;
  after_revision: number;
  before_state: FocusRecordState | null;
  after_state: FocusRecordState | 'deleted';
  accepted_interval_ids: string[];
  accepted_gap_ids: string[];
  added_elapsed_ms: number;
  applied_at: string;
}
export interface FocusOperation {
  contract_version: number;
  user_id: string;
  operation_id: string;
  record_id: string;
  kind: FocusKind;
  request_digest: string;
  receipt: FocusReceipt;
}
export interface FocusDetail {
  contract_version: number;
  user_id: string;
  record: FocusRecord;
  record_revision: number;
  intervals: FocusInterval[];
  unknown_gaps: FocusGap[];
}
export interface FocusActive { contract_version: number; user_id: string; record: FocusRecord | null; }
export interface FocusList {
  contract_version: number;
  user_id: string;
  records: FocusRecord[];
  next_cursor: string | null;
  snapshot_token: string;
}
export interface FocusGateway {
  submitFocusOperation(recordId: string, request: FocusRequest): Promise<FocusOperation>;
  focusOperation(operationId: string): Promise<FocusOperation>;
  focusActive(): Promise<FocusActive>;
  focusDetail(recordId: string): Promise<FocusDetail>;
  focusList(cursor?: string, snapshotToken?: string, limit?: number): Promise<FocusList>;
}
