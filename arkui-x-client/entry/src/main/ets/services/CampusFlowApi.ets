import http from '@ohos.net.http';
import {
  AdminUserSummary,
  AuthResponse,
  CampusDataSnapshot,
  CampusMapSummary,
  CampusRoute,
  ChatResponse,
  ClassroomSearchResponse,
  ClassroomUsageResponse,
  ConfirmActionResponse,
  HistoryMessage,
  HDUHelpConnectResponse,
  HDUHelpConnectionStatus,
  HDUHelpDataResponse,
  HDUHelpSyncResponse,
  ElectricityOverview,
  OnboardingResponse,
  OnboardingSnapshot,
  OnboardingSaveReceipt,
  PendingAction,
  PlanningOverview,
  PlanningActionRequest,
  PlanningConflictReport,
  PlanningTask,
  ReplanPreview,
  RunStartRequest,
  RunSnapshot,
  RunEventsPage,
  ScheduleSubscriptionStatus,
  ScheduleSubscriptionPreview,
  SkillSummary,
  SessionSummary,
  SyncResponse,
  TimetableEntry,
  TimetableSnapshot,
  TimetableSaveReceipt,
  UserContextResponse,
  UserProfile,
  WeatherForecast, ModelCatalog, LearningPreferenceSnapshot, LearningPreferenceWrite, LearningPreferenceDelete, KnowledgeSearch, KnowledgeHit
} from '../model/ApiModels';
import { CampusFlowRequestError, localRequestFailure, requestFailure } from '../utils/AgentFeedback';

interface SettingsPayload {
  display_name: string;
  school: string;
  campus: string;
  semester: string;
  api_key?: string;
}

interface TaskCreatePayload {
  title: string;
  start_at: string | null;
}

interface RequestHeaders {
  'Accept': string;
  'Content-Type': string;
  'Authorization': string;
}

interface ApiErrorPayload {
  detail?: string;
  message?: string;
}

const PATCH_METHOD: http.RequestMethod = 'PATCH' as http.RequestMethod;

export class CampusFlowApi {
  private baseUrl: string;
  private accessToken: string;

  constructor(baseUrl: string, accessToken: string = '') {
    this.baseUrl = baseUrl.replace(/\/$/, '');
    this.accessToken = accessToken;
  }

  async models(): Promise<ModelCatalog> { return this.request('/api/v1/models', http.RequestMethod.GET); }
  async learningPreferences(): Promise<LearningPreferenceSnapshot> { return this.request('/api/v1/learning-preferences', http.RequestMethod.GET); }
  async saveLearningPreferences(payload: LearningPreferenceWrite): Promise<LearningPreferenceSnapshot> {
    return this.request('/api/v1/learning-preferences', http.RequestMethod.PUT, JSON.stringify(payload));
  }
  async clearLearningPreferences(payload: LearningPreferenceDelete): Promise<LearningPreferenceSnapshot> {
    return this.request('/api/v1/learning-preferences', http.RequestMethod.DELETE, JSON.stringify(payload));
  }
  async searchKnowledge(query: string): Promise<KnowledgeSearch> {
    return this.request(`/api/v1/knowledge/search?q=${encodeURIComponent(query)}`, http.RequestMethod.GET);
  }
  async knowledgeSource(id: string): Promise<KnowledgeHit> {
    return this.request(`/api/v1/knowledge/sources/${encodeURIComponent(id)}`, http.RequestMethod.GET);
  }

  private formatError(responseCode: number, text: string): string {
    let detail = text.trim();
    if (detail.length > 0) {
      try {
        const payload = JSON.parse(detail) as ApiErrorPayload;
        detail = payload.detail ?? payload.message ?? detail;
      } catch {
        // Preserve existing validation and campus-service messages outside Agent requests.
      }
    }
    if (detail.length === 0) {
      detail = '服务暂时不可用，请稍后重试。';
    }
    return `请求失败（${responseCode}）：${detail}`;
  }

  private async request<T>(path: string, method: http.RequestMethod, body: string = ''): Promise<T> {
    const client = http.createHttp();
    const headers: RequestHeaders = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': this.accessToken.length > 0 ? `Bearer ${this.accessToken}` : ''
    };
    try {
      let response: http.HttpResponse;
      try {
        response = await client.request(`${this.baseUrl}${path}`, {
          method: method,
          header: headers,
          extraData: body,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 12000,
          readTimeout: 90000
        });
      } catch {
        throw localRequestFailure('NETWORK_ERROR');
      }
      const text = response.result as string;
      if (response.responseCode < 200 || response.responseCode >= 300) {
        if (path === '/api/v1/onboarding' || path.startsWith('/api/v1/onboarding/') || path === '/api/v1/models' || path === '/api/v1/learning-preferences' || path.startsWith('/api/v1/knowledge/') || path === '/api/v1/chat' || path.startsWith('/api/v1/agent-runs') || path.startsWith('/api/v1/actions/') || path.startsWith('/api/v1/planning/') ||
          path === '/api/v1/tasks' || path.startsWith('/api/v1/tasks/') ||
          path === '/api/v1/me/timetable' || path.startsWith('/api/v1/me/timetable/') || path.startsWith('/api/v1/weather?')) {
          throw requestFailure(response.responseCode, text);
        }
        throw new CampusFlowRequestError(response.responseCode, 'HTTP_ERROR', this.formatError(response.responseCode, text));
      }
      if (response.responseCode === 204) {
        return undefined as T;
      }
      try {
        return JSON.parse(text) as T;
      } catch {
        throw localRequestFailure('INVALID_RESPONSE', response.responseCode);
      }
    } finally {
      client.destroy();
    }
  }

  async login(email: string, password: string): Promise<AuthResponse> {
    return this.request<AuthResponse>('/api/v1/auth/login', http.RequestMethod.POST,
      JSON.stringify({ email: email, password: password }));
  }

  async logout(): Promise<void> {
    // HarmonyOS NetStack may reject an empty-string payload before sending a POST.
    // Use an empty JSON object for body-less API actions so the request reliably
    // reaches the service (most importantly, so logout revokes the server token).
    await this.request<void>('/api/v1/auth/logout', http.RequestMethod.POST, '{}');
  }

  async weather(date: string): Promise<WeatherForecast> {
    return this.request<WeatherForecast>(`/api/v1/weather?date=${encodeURIComponent(date)}`, http.RequestMethod.GET);
  }

  async register(email: string, password: string, displayName: string, apiKey?: string): Promise<AuthResponse> {
    return this.request<AuthResponse>('/api/v1/auth/register', http.RequestMethod.POST,
      JSON.stringify({ email: email, password: password, display_name: displayName, api_key: apiKey && apiKey.trim().length > 0 ? apiKey : undefined }));
  }

  async onboardingSnapshot(): Promise<OnboardingSnapshot> {
    return this.request<OnboardingSnapshot>('/api/v1/onboarding', http.RequestMethod.GET);
  }

  async onboardingOperation(operationId: string): Promise<OnboardingSaveReceipt> {
    return this.request<OnboardingSaveReceipt>(`/api/v1/onboarding/operations/${encodeURIComponent(operationId)}`,
      http.RequestMethod.GET);
  }

  async completeOnboarding(school: string, campus: string, semester: string,
    timetable: TimetableEntry[], campusMap: CampusMapSummary, operationId?: string,
    expectedRevision?: string): Promise<OnboardingResponse> {
    return this.request<OnboardingResponse>('/api/v1/onboarding', http.RequestMethod.PUT, JSON.stringify({
      school: school,
      campus: campus,
      semester: semester,
      timetable: timetable,
      campus_map: campusMap,
      operation_id: operationId,
      expected_revision: expectedRevision
    }));
  }

  async context(): Promise<UserContextResponse> {
    return this.request<UserContextResponse>('/api/v1/me/context', http.RequestMethod.GET);
  }

  async timetable(): Promise<TimetableSnapshot> {
    return this.request<TimetableSnapshot>('/api/v1/me/timetable', http.RequestMethod.GET);
  }

  async saveTimetable(entries: TimetableEntry[], expectedRevision: string,
    operationId: string, confirmClear: boolean = false): Promise<TimetableSaveReceipt> {
    return this.request<TimetableSaveReceipt>('/api/v1/me/timetable', http.RequestMethod.PUT,
      JSON.stringify({ entries: entries, expected_revision: expectedRevision,
        operation_id: operationId, confirm_clear: confirmClear }));
  }

  async timetableOperation(operationId: string): Promise<TimetableSaveReceipt> {
    return this.request<TimetableSaveReceipt>(`/api/v1/me/timetable/operations/${encodeURIComponent(operationId)}`,
      http.RequestMethod.GET);
  }

  async chat(sessionId: string, model: string, message: string): Promise<ChatResponse> {
    return this.request<ChatResponse>('/api/v1/chat', http.RequestMethod.POST,
      JSON.stringify({ session_id: sessionId, model: model, message: message }));
  }

  async startAgentRun(request: RunStartRequest): Promise<RunSnapshot> {
    return this.request<RunSnapshot>('/api/v1/agent-runs', http.RequestMethod.POST, JSON.stringify(request));
  }

  async agentRun(runId: string): Promise<RunSnapshot> {
    return this.request<RunSnapshot>(`/api/v1/agent-runs/${encodeURIComponent(runId)}`, http.RequestMethod.GET);
  }

  async agentRunEvents(runId: string, afterSeq: number): Promise<RunEventsPage> {
    return this.request<RunEventsPage>(`/api/v1/agent-runs/${encodeURIComponent(runId)}/events?after_seq=${afterSeq}`,
      http.RequestMethod.GET);
  }

  async cancelAgentRun(runId: string): Promise<RunSnapshot> {
    return this.request<RunSnapshot>(`/api/v1/agent-runs/${encodeURIComponent(runId)}/cancel`, http.RequestMethod.POST, '{}');
  }

  async recentAgentRuns(limit: number = 20): Promise<RunSnapshot[]> {
    return this.request<RunSnapshot[]>(`/api/v1/agent-runs?limit=${limit}`, http.RequestMethod.GET);
  }

  async previewPlanningAction(payload: PlanningActionRequest): Promise<PendingAction> {
    return this.request<PendingAction>('/api/v1/planning/actions', http.RequestMethod.POST, JSON.stringify(payload));
  }

  async confirmAction(proposalId: string): Promise<ConfirmActionResponse> {
    return this.request<ConfirmActionResponse>(`/api/v1/actions/${encodeURIComponent(proposalId)}/confirm`,
      http.RequestMethod.POST, '{}');
  }

  async cancelAction(proposalId: string): Promise<ConfirmActionResponse> {
    return this.request<ConfirmActionResponse>(`/api/v1/actions/${encodeURIComponent(proposalId)}/cancel`,
      http.RequestMethod.POST, '{}');
  }

  async actionStatus(proposalId: string): Promise<PendingAction> {
    return this.request<PendingAction>(`/api/v1/actions/${encodeURIComponent(proposalId)}`,
      http.RequestMethod.GET);
  }

  async campusRoute(origin: string, destination: string): Promise<CampusRoute> {
    return this.request<CampusRoute>(
      `/api/v1/campus-data/route?origin=${encodeURIComponent(origin)}&destination=${encodeURIComponent(destination)}`,
      http.RequestMethod.GET
    );
  }

  async campusData(): Promise<CampusDataSnapshot> {
    return this.request<CampusDataSnapshot>('/api/v1/campus-data', http.RequestMethod.GET);
  }

  async sessions(): Promise<SessionSummary[]> {
    return this.request<SessionSummary[]>('/api/v1/sessions', http.RequestMethod.GET);
  }

  async history(sessionId: string): Promise<HistoryMessage[]> {
    return this.request<HistoryMessage[]>(`/api/v1/sessions/${encodeURIComponent(sessionId)}/history`,
      http.RequestMethod.GET);
  }

  async deleteSession(sessionId: string): Promise<void> {
    await this.request<void>(`/api/v1/sessions/${encodeURIComponent(sessionId)}`,
      http.RequestMethod.DELETE, '{}');
  }

  async adminUsers(): Promise<AdminUserSummary[]> {
    return this.request<AdminUserSummary[]>('/api/v1/admin/users', http.RequestMethod.GET);
  }

  async planning(): Promise<PlanningOverview> {
    return this.request<PlanningOverview>('/api/v1/planning', http.RequestMethod.GET);
  }

  async planningConflicts(): Promise<PlanningConflictReport> {
    return this.request<PlanningConflictReport>('/api/v1/planning/conflicts', http.RequestMethod.GET);
  }

  async previewReplan(): Promise<ReplanPreview> {
    return this.request<ReplanPreview>('/api/v1/planning/replans', http.RequestMethod.POST, '{}');
  }

  async replanStatus(id: string): Promise<ReplanPreview> {
    return this.request<ReplanPreview>(`/api/v1/planning/replans/${encodeURIComponent(id)}`, http.RequestMethod.GET);
  }

  async confirmReplan(id: string): Promise<ReplanPreview> {
    return this.request<ReplanPreview>(`/api/v1/planning/replans/${encodeURIComponent(id)}/confirm`, http.RequestMethod.POST, '{}');
  }

  async createTask(title: string, startAt: string | null = null): Promise<PlanningTask> {
    const payload: TaskCreatePayload = { title: title, start_at: startAt };
    return this.request<PlanningTask>('/api/v1/tasks', http.RequestMethod.POST, JSON.stringify(payload));
  }

  async updateTask(taskId: string, completed: boolean): Promise<PlanningTask> {
    return this.request<PlanningTask>(`/api/v1/tasks/${encodeURIComponent(taskId)}`, PATCH_METHOD,
      JSON.stringify({ completed: completed }));
  }

  async deleteTask(taskId: string): Promise<void> {
    await this.request<void>(`/api/v1/tasks/${encodeURIComponent(taskId)}`,
      http.RequestMethod.DELETE, '{}');
  }

  async deletePlan(planId: string): Promise<void> {
    await this.request<void>(`/api/v1/plans/${encodeURIComponent(planId)}`,
      http.RequestMethod.DELETE, '{}');
  }

  async skills(): Promise<SkillSummary[]> {
    return this.request<SkillSummary[]>('/api/v1/skills', http.RequestMethod.GET);
  }

  async installSkill(skill: SkillSummary): Promise<SkillSummary> {
    const permissions: string[] = skill.permissions.map((item) => item.code);
    return this.request<SkillSummary>(`/api/v1/skills/${encodeURIComponent(skill.skill_id)}/install`,
      http.RequestMethod.POST, JSON.stringify({ accepted_permissions: permissions }));
  }

  async setSkillEnabled(skillId: string, enabled: boolean): Promise<SkillSummary> {
    return this.request<SkillSummary>(`/api/v1/skills/${encodeURIComponent(skillId)}`, PATCH_METHOD,
      JSON.stringify({ enabled: enabled }));
  }

  async me(): Promise<UserProfile> {
    return this.request<UserProfile>('/api/v1/me', http.RequestMethod.GET);
  }

  async updateSettings(displayName: string, school: string, campus: string, semester: string,
    apiKey: string): Promise<UserProfile> {
    let payload: SettingsPayload = {
      display_name: displayName,
      school: school,
      campus: campus,
      semester: semester
    };
    if (apiKey.length > 0) {
      payload.api_key = apiKey;
    }
    return this.request<UserProfile>('/api/v1/me/settings', http.RequestMethod.PUT, JSON.stringify(payload));
  }

  async subscriptionStatus(): Promise<ScheduleSubscriptionStatus> {
    return this.request<ScheduleSubscriptionStatus>('/api/v1/schedule-subscriptions', http.RequestMethod.GET);
  }

  async previewSubscription(url: string): Promise<ScheduleSubscriptionPreview> {
    return this.request<ScheduleSubscriptionPreview>('/api/v1/schedule-subscriptions/preview', http.RequestMethod.POST,
      JSON.stringify({ url: url }));
  }

  async saveSubscription(url: string): Promise<SyncResponse> {
    return this.request<SyncResponse>('/api/v1/schedule-subscriptions', http.RequestMethod.PUT,
      JSON.stringify({ url: url }));
  }

  async syncSubscription(): Promise<SyncResponse> {
    return this.request<SyncResponse>('/api/v1/schedule-subscriptions/sync', http.RequestMethod.POST, '{}');
  }

  async hduHelpStatus(): Promise<HDUHelpConnectionStatus> {
    return this.request<HDUHelpConnectionStatus>('/api/v1/hduhelp/status', http.RequestMethod.GET);
  }

  async hduHelpData(): Promise<HDUHelpDataResponse> {
    return this.request<HDUHelpDataResponse>('/api/v1/hduhelp/data', http.RequestMethod.GET);
  }

  async connectHduHelp(): Promise<HDUHelpConnectResponse> {
    return this.request<HDUHelpConnectResponse>('/api/v1/hduhelp/connect', http.RequestMethod.POST, '{}');
  }

  async connectHduHelpPat(pat: string): Promise<HDUHelpSyncResponse> {
    return this.request<HDUHelpSyncResponse>('/api/v1/hduhelp/pat', http.RequestMethod.PUT,
      JSON.stringify({ pat: pat }));
  }

  async syncHduHelp(): Promise<HDUHelpSyncResponse> {
    return this.request<HDUHelpSyncResponse>('/api/v1/hduhelp/sync', http.RequestMethod.POST, '{}');
  }

  async disconnectHduHelp(): Promise<void> {
    await this.request<void>('/api/v1/hduhelp/connection', http.RequestMethod.DELETE, '{}');
  }

  async unusedClassrooms(buildingId: string, sections: number[]): Promise<ClassroomSearchResponse> {
    let query = `limit=30&building_id=${encodeURIComponent(buildingId)}`;
    sections.forEach((section: number) => {
      query += `&section=${section}`;
    });
    return this.request<ClassroomSearchResponse>(`/api/v1/campus-services/classrooms?${query}`,
      http.RequestMethod.GET);
  }

  async electricity(): Promise<ElectricityOverview> {
    return this.request<ElectricityOverview>('/api/v1/campus-services/electricity', http.RequestMethod.GET);
  }

  async classroomUsage(locationId: string): Promise<ClassroomUsageResponse> {
    return this.request<ClassroomUsageResponse>(
      `/api/v1/campus-services/classrooms/${encodeURIComponent(locationId)}/usage`, http.RequestMethod.GET);
  }
}
