import http from '@ohos.net.http';
import {
  AuthResponse,
  CampusRoute,
  ChatResponse,
  ConfirmActionResponse,
  OnboardingResponse,
  PlanningOverview,
  PlanningTask,
  ScheduleSubscriptionStatus,
  SkillSummary,
  SyncResponse,
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

export class CampusFlowApi {
  private baseUrl: string;
  private accessToken: string;

  constructor(baseUrl: string, accessToken: string = '') {
    this.baseUrl = baseUrl.replace(/\/$/, '');
    this.accessToken = accessToken;
  }

  private async request<T>(path: string, method: http.RequestMethod, body: string = ''): Promise<T> {
    const client = http.createHttp();
    const headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': this.accessToken.length > 0 ? `Bearer ${this.accessToken}` : ''
    };
    try {
      const response = await client.request(`${this.baseUrl}${path}`, {
        method: method,
        header: headers,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 12000,
        readTimeout: 90000
      });
      const text = response.result as string;
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`请求失败（${response.responseCode}）：${text}`);
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

  async register(email: string, password: string, displayName: string, apiKey: string): Promise<AuthResponse> {
    return this.request<AuthResponse>('/api/v1/auth/register', http.RequestMethod.POST,
      JSON.stringify({ email: email, password: password, display_name: displayName, api_key: apiKey }));
  }

  async completeOnboarding(school: string, campus: string, semester: string): Promise<OnboardingResponse> {
    return this.request<OnboardingResponse>('/api/v1/onboarding', http.RequestMethod.PUT, JSON.stringify({
      school: school,
      campus: campus,
      semester: semester,
      timetable: [],
      campus_map: { campus_name: `${school}${campus}`, places: [], warnings: ['移动端稍后可继续上传校园地图。'] }
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
      http.RequestMethod.POST);
  }

  async campusRoute(origin: string, destination: string): Promise<CampusRoute> {
    return this.request<CampusRoute>(
      `/api/v1/campus-data/route?origin=${encodeURIComponent(origin)}&destination=${encodeURIComponent(destination)}`,
      http.RequestMethod.GET
    );
  }

  async planning(): Promise<PlanningOverview> {
    return this.request<PlanningOverview>('/api/v1/planning', http.RequestMethod.GET);
  }

  async createTask(title: string): Promise<PlanningTask> {
    return this.request<PlanningTask>('/api/v1/tasks', http.RequestMethod.POST, JSON.stringify({ title: title }));
  }

  async updateTask(taskId: string, completed: boolean): Promise<PlanningTask> {
    return this.request<PlanningTask>(`/api/v1/tasks/${encodeURIComponent(taskId)}`, http.RequestMethod.PATCH,
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
    return this.request<SkillSummary>(`/api/v1/skills/${encodeURIComponent(skillId)}`, http.RequestMethod.PATCH,
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
    return this.request<SyncResponse>('/api/v1/schedule-subscriptions/sync', http.RequestMethod.POST);
  }
}
