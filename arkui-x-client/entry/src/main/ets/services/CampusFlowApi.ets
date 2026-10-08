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
  PlanningOverview,
  PlanningTask,
  ScheduleSubscriptionStatus,
  SkillSummary,
  SessionSummary,
  SyncResponse,
  TimetableEntry,
  UserContextResponse,
  UserProfile
} from '../model/ApiModels';

interface SettingsPayload {
  display_name: string;
  school: string;
  campus: string;
  semester: string;
  api_key?: string;
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

  private formatError(responseCode: number, text: string): string {
    let detail = text.trim();
    if (detail.length > 0) {
      try {
        const payload = JSON.parse(detail) as ApiErrorPayload;
        detail = payload.detail ?? payload.message ?? detail;
      } catch {
        // Keep a non-JSON response as the diagnostic message.
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
        throw new Error('无法连接 CampusFlow 服务，请检查服务地址和网络连接。');
      }
      const text = response.result as string;
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(this.formatError(response.responseCode, text));
      }
      if (response.responseCode === 204 || text.length === 0) {
        return undefined as T;
      }
      return JSON.parse(text) as T;
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

  async register(email: string, password: string, displayName: string, apiKey: string): Promise<AuthResponse> {
    return this.request<AuthResponse>('/api/v1/auth/register', http.RequestMethod.POST,
      JSON.stringify({ email: email, password: password, display_name: displayName, api_key: apiKey }));
  }

  async completeOnboarding(school: string, campus: string, semester: string,
    timetable: TimetableEntry[], campusMap: CampusMapSummary): Promise<OnboardingResponse> {
    return this.request<OnboardingResponse>('/api/v1/onboarding', http.RequestMethod.PUT, JSON.stringify({
      school: school,
      campus: campus,
      semester: semester,
      timetable: timetable,
      campus_map: campusMap
    }));
  }

  async context(): Promise<UserContextResponse> {
    return this.request<UserContextResponse>('/api/v1/me/context', http.RequestMethod.GET);
  }

  async chat(sessionId: string, model: string, message: string): Promise<ChatResponse> {
    return this.request<ChatResponse>('/api/v1/chat', http.RequestMethod.POST,
      JSON.stringify({ session_id: sessionId, model: model, message: message }));
  }

  async confirmAction(proposalId: string): Promise<ConfirmActionResponse> {
    return this.request<ConfirmActionResponse>(`/api/v1/actions/${encodeURIComponent(proposalId)}/confirm`,
      http.RequestMethod.POST, '{}');
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

  async createTask(title: string): Promise<PlanningTask> {
    return this.request<PlanningTask>('/api/v1/tasks', http.RequestMethod.POST, JSON.stringify({ title: title }));
  }

  async updateTask(taskId: string, completed: boolean): Promise<PlanningTask> {
    return this.request<PlanningTask>(`/api/v1/tasks/${encodeURIComponent(taskId)}`, PATCH_METHOD,
      JSON.stringify({ completed: completed }));
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
