export interface UserProfile {
  user_id: string;
  email: string;
  display_name: string;
  school: string | null;
  campus: string | null;
  semester: string | null;
  onboarding_complete: boolean;
  role: string;
  api_key_configured: boolean;
  api_key_hint: string | null;
}

export interface AuthResponse {
  user: UserProfile;
  access_token: string;
  token_type: string;
}

export interface TimetableEntry {
  date: string;
  title: string;
  start_time: string;
  end_time: string;
  location: string;
  teacher: string;
}

export interface TimetableSnapshot {
  entries: TimetableEntry[];
  revision: string;
}

export interface TimetableSaveReceipt {
  operation_id: string;
  status: string;
  previous_revision: string;
  revision: string;
  entry_count: number;
  applied_at: string;
}

export interface ScheduleSubscriptionPreview {
  provider: string;
  calendar_name: string;
  event_count: number;
  entries: TimetableEntry[];
  warnings: string[];
}

export interface CampusMapSummary {
  campus_name: string;
  places: CampusPlaceImport[];
  warnings: string[];
}

export interface CampusPlaceImport {
  name: string;
  category: string;
  zone: string;
  aliases: string[];
}

export interface UserContextResponse {
  timetable: TimetableEntry[];
  campus_map: CampusMapSummary;
}

export interface PendingTaskPreview {
  title: string;
  start_at: string | null;
  end_at: string | null;
  reminder_minutes: number | null;
  location: string | null;
}

export interface PendingMilestonePreview {
  title: string;
  due_at: string | null;
  tasks: PendingTaskPreview[];
}

export interface PlanningTaskDraft {
  title: string;
  start_at: string | null;
  end_at: string | null;
  reminder_minutes: number | null;
  location: string | null;
}

export interface PlanningPlanDraft {
  title: string;
  summary: string;
  target_date: string | null;
}

export interface PlanningActionRequest {
  operation: string;
  task_id?: string;
  plan_id?: string;
  task?: PlanningTaskDraft;
  plan?: PlanningPlanDraft;
  reason?: string;
}

export interface ActionReceipt {
  receipt_id: string;
  proposal_id: string;
  action: string;
  kind: string;
  applied_at: string;
  task_ids: string[];
  plan_ids: string[];
  milestone_ids: string[];
  retained_task_ids: string[];
}

export interface PendingActionPayload {
  task?: PlanningTaskDraft;
  plan?: PlanningPlanDraft;
  summary?: string;
  target_date?: string | null;
  location?: string | null;
  milestones?: PendingMilestonePreview[];
}

export interface PendingAction {
  warnings?: string[];
  contract_version?: number;
  created_at?: string;
  expires_at?: string;
  target_task_id?: string | null;
  target_plan_id?: string | null;
  before_task?: PlanningTask | null;
  before_plan?: PlanSummary | null;
  receipt?: ActionReceipt | null;
  proposal_id: string;
  action: string;
  kind: string;
  title: string;
  start_at: string | null;
  end_at: string | null;
  reminder_minutes: number | null;
  reason: string | null;
  payload: PendingActionPayload;
  conflicts: string[];
  status: string;
}

export interface ToolDisplaySummary {
  label: string;
  state: string;
  summary: string;
}

// Only the server's display projection is consumed by the native interface.
export interface ToolTrace {
  tool_call_id: string;
  tool_name: string;
  display?: ToolDisplaySummary | null;
  status?: string | null;
}

export interface ChatResponse {
  session_id: string;
  message: string;
  pending_actions: PendingAction[];
  tool_traces?: ToolTrace[];
}

export interface ConfirmActionResponse {
  receipt?: ActionReceipt | null;
  applied: boolean;
  message: string;
  action: PendingAction;
}

export interface ChatMessage {
  role: string;
  content: string;
}

export interface HistoryMessage {
  role: string;
  content: string;
  created_at: string;
}

export interface SessionSummary {
  session_id: string;
  title: string;
  model_name: string;
  last_message: string;
  message_count: number;
  created_at: string;
  updated_at: string;
}

export interface CampusDataPlace {
  place_id: string;
  name: string;
  category: string;
  zone: string;
  aliases: string[];
  open_now: boolean;
  open_hours: string;
}

export interface CampusDataPackage {
  package_id: string;
  school: string;
  campus: string;
  version: string;
}

export interface CampusDataSnapshot {
  package: CampusDataPackage;
  places: CampusDataPlace[];
}

export interface CampusRoutePoint {
  x: number;
  y: number;
  label: string;
  place_id: string | null;
}

export interface CampusRouteStep {
  index: number;
  instruction: string;
  minutes: number;
}

export interface CampusRoute {
  package_id: string;
  package_version: string;
  origin: CampusDataPlace;
  destination: CampusDataPlace;
  total_minutes: number;
  estimated_distance_meters: number;
  path: CampusRoutePoint[];
  steps: CampusRouteStep[];
  note: string;
}

export interface PlanningTask {
  task_id: string;
  plan_id: string | null;
  milestone_id: string | null;
  title: string;
  start_at: string | null;
  end_at: string | null;
  reminder_minutes: number | null;
  location: string | null;
  status: string;
  source: string;
  created_at: string;
  completed_at: string | null;
}

export interface PlanMilestone {
  milestone_id: string;
  title: string;
  due_at: string | null;
  task_count: number;
  completed_count: number;
}

export interface PlanSummary {
  plan_id: string;
  title: string;
  summary: string;
  target_date: string | null;
  status: string;
  progress: number;
  task_count: number;
  completed_count: number;
  overdue_count: number;
  milestones: PlanMilestone[];
  created_at: string;
}

export interface PlanningOverview {
  plans: PlanSummary[];
  tasks: PlanningTask[];
  total_tasks: number;
  completed_tasks: number;
  due_today: number;
  overdue_tasks: number;
  progress: number;
}

export interface PlanningCourseConflict {
  task_id: string;
  title: string;
  start_at: string;
  end_at: string;
  courses: TimetableEntry[];
}

export interface ReplanUnresolved {
  task_id: string;
  title: string;
  reason: string;
}

export interface PlanningConflictReport {
  checked_at: string;
  policy: string;
  conflicts: PlanningCourseConflict[];
  unchecked: ReplanUnresolved[];
}

export interface ReplanChange {
  task_id: string;
  title: string;
  old_start_at: string;
  old_end_at: string;
  new_start_at: string;
  new_end_at: string;
}

export interface ReplanPreview {
  replan_id: string;
  status: string;
  created_at: string;
  expires_at: string;
  policy: string;
  changes: ReplanChange[];
  unresolved: ReplanUnresolved[];
}

export interface SkillPermission {
  code: string;
  label: string;
  description: string;
  access: string;
}

export interface SkillSummary {
  skill_id: string;
  name: string;
  description: string;
  category: string;
  version: string;
  author: string;
  official: boolean;
  permissions: SkillPermission[];
  capabilities: string[];
  installed: boolean;
  enabled: boolean;
  installed_version: string | null;
  update_available: boolean;
}

export interface ScheduleSubscriptionStatus {
  configured: boolean;
  provider: string | null;
  source_host: string | null;
  event_count: number;
  last_synced_at: string | null;
}

export interface OnboardingResponse {
  user: UserProfile;
  timetable_count: number;
  campus_place_count: number;
}

export interface SyncResponse {
  imported_count: number;
  status: ScheduleSubscriptionStatus;
  warnings: string[];
}

export interface HDUHelpConnectionStatus {
  configured: boolean;
  provider: string | null;
  auth_mode: string | null;
  token_hint: string | null;
  scopes: string[];
  external_name: string | null;
  identity_type: string | null;
  expires_at: string | null;
  connected_at: string | null;
  last_synced_at: string | null;
  last_error: string | null;
  resources: string[];
}

export interface HDUHelpConnectResponse {
  authorize_url: string;
  expires_at: string;
  scopes: string[];
}

export interface HDUHelpSyncResponse {
  status: HDUHelpConnectionStatus;
  synced_resources: string[];
  errors: Record<string, string>;
}

export interface HDUHelpDisplayItem {
  label: string;
  value: string;
  emphasis: boolean;
}

export interface HDUHelpDisplaySection {
  resource: string;
  title: string;
  summary: string;
  items: HDUHelpDisplayItem[];
}

export interface HDUHelpSuggestedPrompt {
  prompt_id: string;
  title: string;
  prompt: string;
  resource: string | null;
}

export interface HDUHelpDataResponse {
  status: HDUHelpConnectionStatus;
  sections: HDUHelpDisplaySection[];
  suggested_prompts: HDUHelpSuggestedPrompt[];
  sync_errors: Record<string, string>;
}

export interface ClassroomItem {
  building_id: string;
  building_name: string;
  location_id: string;
  location_name: string;
  capacity: number;
  self_study: boolean;
  available: boolean;
  school_year: string;
  semester: string;
}

export interface ClassroomSearchResponse {
  query_label: string;
  items: ClassroomItem[];
  total: number;
  has_more: boolean;
}

export interface ClassroomUsageItem {
  week: number;
  weekday: number;
  section: number;
  course_name: string;
  location_name: string;
  start_time: string;
  end_time: string;
}

export interface ClassroomUsageResponse {
  location_id: string;
  items: ClassroomUsageItem[];
}

export interface ElectricityHistoryItem {
  date: string;
  balance: string;
  change: string;
}

export interface ElectricityOverview {
  bound: boolean;
  room_name: string;
  campus_name: string;
  building_name: string;
  floor_name: string;
  meter_hint: string;
  balance: number | null;
  balance_updated_at: string | null;
  daily_average: string;
  history: ElectricityHistoryItem[];
}

export interface AdminUserSummary {
  user_id: string;
  email: string;
  display_name: string;
  school: string | null;
  campus: string | null;
  role: string;
  onboarding_complete: boolean;
  api_key_configured: boolean;
  created_at: string;
  timetable_count: number;
  campus_place_count: number;
}
