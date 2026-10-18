import { FocusInterval, FocusGap } from './FocusModels';

export type ReviewPeriod = 'day' | 'week';
export interface ReviewTask {
  task_id: string;
  title: string;
  task_version: number;
  status: 'pending' | 'completed';
  created_at: string;
  start_at: string | null;
  end_at: string | null;
  completed_at: string | null;
  completion_operation_id: string | null;
  completion_evidence: 'operation_receipt' | 'current_task_time' | 'unattributed' | 'pending';
}
export interface ReviewAllocation {
  record_id: string;
  task_id: string;
  task_title: string | null;
  task_missing: boolean;
  record_revision: number;
  interval: FocusInterval;
  span_us: number;
  clip_from_us: number;
  clip_to_us: number;
  allocated_elapsed_ms: number;
}
export interface ReviewUnknownGap {
  record_id: string;
  task_id: string;
  task_title: string | null;
  task_missing: boolean;
  record_revision: number;
  gap: FocusGap;
}
export interface ReviewTotals {
  current_completed_count: number;
  current_unscheduled_count: number;
  confirmed_elapsed_ms: number;
  unknown_gap_count: number;
}
export interface ReviewSnapshot {
  contract_version: number;
  user_id: string;
  period: ReviewPeriod;
  anchor: string;
  timezone: 'Asia/Shanghai';
  timezone_policy: 'fixed_utc_plus_08';
  period_start: string;
  period_end: string;
  as_of: string;
  snapshot_digest: string;
  totals: ReviewTotals;
  completed_tasks: ReviewTask[];
  unscheduled_tasks: ReviewTask[];
  unattributed_completed_tasks: ReviewTask[];
  focus_intervals: ReviewAllocation[];
  unknown_gaps: ReviewUnknownGap[];
}
export interface ReviewFacts { completed: boolean; unscheduled: boolean; focus: boolean; }
export interface ReviewGateway {
  review(period: ReviewPeriod, anchor: string): Promise<ReviewSnapshot>;
}
