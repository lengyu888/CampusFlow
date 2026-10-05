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

export interface PendingAction {
  proposal_id: string;
  action: string;
  kind: string;
  title: string;
  reason: string | null;
  conflicts: string[];
  status: string;
}

export interface ChatResponse {
  session_id: string;
  message: string;
  pending_actions: PendingAction[];
}

export interface ConfirmActionResponse {
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

export interface CampusDataSnapshot {
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
  title: string;
  start_at: string | null;
  end_at: string | null;
  reminder_minutes: number | null;
  location: string | null;
  status: string;
  source: string;
}

export interface PlanningOverview {
  tasks: PlanningTask[];
  total_tasks: number;
  completed_tasks: number;
  due_today: number;
  progress: number;
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
