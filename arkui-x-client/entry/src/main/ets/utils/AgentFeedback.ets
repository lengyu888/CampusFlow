import { PendingAction, ToolDisplaySummary, ToolTrace } from '../model/ApiModels';

interface ErrorCodePayload {
  code?: string | null;
}

export class CampusFlowRequestError extends Error {
  statusCode: number;
  code: string;

  constructor(statusCode: number, code: string, message: string) {
    super(message);
    this.name = 'CampusFlowRequestError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

function knownErrorMessage(code: string): string {
  switch (code) {
    case 'LOGIN_REQUIRED':
      return '请重新登录行简后再试。';
    case 'MODEL_AUTH_INVALID':
      return '模型服务凭据无效，请在个人设置中检查或更新 API Key。';
    case 'MODEL_KEY_REQUIRED':
      return '尚未配置模型 API Key，请在个人设置中完成配置。';
    case 'MODEL_CONFIG_INVALID':
      return '模型目录配置未通过检查，请联系服务维护者。';
    case 'MODEL_NOT_FOUND':
      return '该模型已移除或未配置，请刷新模型列表后选择。';
    case 'MODEL_CAPABILITY_UNSUPPORTED':
      return '该模型未声明支持本应用所需的工具与增量回答，请选择其他模型。';
    case 'MODEL_PROVIDER_KEY_REQUIRED':
      return '该供应商的服务端凭据尚未配置，请联系服务维护者或选择其他模型。';
    case 'PREFERENCES_CHANGED':
      return '学习偏好已被其他操作修改，当前草稿仍保留，请读取最新值再核对。';
    case 'OPERATION_ID_REUSED':
      return '该操作标识已用于其他内容，请先重新核对当前学习偏好。';
    case 'OPERATION_RETIRED':
      return '这次操作已因偏好清除而失效，请读取最新值后重新核对。';
    case 'MODEL_UNAVAILABLE':
      return '模型服务暂时不可用，请稍后再试。';
    case 'MODEL_RATE_LIMITED':
      return '模型服务请求过于频繁或额度不足，请检查额度后稍后再试。';
    case 'MODEL_REQUEST_REJECTED':
      return '模型服务未接受本次请求，请检查模型配置或调整输入后再试。';
    case 'REQUEST_TIMEOUT':
      return '请求超时，结果尚未确认。请先核对记录，再决定是否重试。';
    case 'ACTION_NOT_FOUND':
      return '未找到此提案，请刷新核对。';
    case 'TASK_NOT_FOUND':
      return '这项任务已不存在，请读取最新安排；不会从旧回执重建任务。';
    case 'TASK_STATUS_OPERATION_NOT_FOUND':
      return '未查到这次状态操作，请核对账号；需要重试时仍使用原操作标识和原内容。';
    case 'TASK_STATUS_OPERATION_REUSED':
      return '这次操作标识已对应另一份内容，请先核对原操作记录。';
    case 'TASK_STALE':
      return '任务或相关安排已经变化，请读取最新内容后重新核对；旧预览不会覆盖新修改。';
    case 'TASK_STATUS_UNCHANGED':
      return '这项任务已经是该状态，请刷新查看；本次没有生成新的完成凭据。';
    case 'TASK_COMPLETION_NOT_TRACKED':
      return '这次完成未保留可核验的凭据，暂时不能使用恢复未完成。';
    case 'TASK_COMPLETION_SUPERSEDED':
      return '这项任务后来已再次完成，旧完成记录不能恢复当前这一次完成。';
    case 'TASK_RECOVERY_PREVIEW_REQUIRED':
      return '恢复未完成需要先读取任务的最新版本，查看预览并确认。';
    case 'TASK_RECOVERY_EXPIRED':
      return '这份恢复预览已过期，请取消原预览，再根据最新安排重新核对。';
    case 'TASK_RECOVERY_CANCELLED':
      return '这份恢复预览已取消，没有执行本次恢复。';
    case 'TASK_STATUS_FAILED':
      return '状态操作结果尚未确认，请先查询原操作记录，不要新建一笔重复提交。';
    case 'RUN_NOT_FOUND':
      return '未找到保留的运行记录，请核对账号和运行标识，不要重复发送。';
    case 'RUN_DELETED':
      return '这次运行所属会话已删除，不能重试或恢复原运行。';
    case 'RUN_ID_REUSED':
      return '运行标识已使用，请先核对这次运行的原始内容。';
    case 'RUN_SESSION_BUSY':
      return '此会话仍在运行，请先查回结果或取消。';
    case 'RUN_WORKER_BUSY':
      return '运行服务正在处理或恢复，请稍后查询已有记录。';
    case 'RUN_LIMIT':
      return '已有两次运行正在处理，请先完成或取消。';
    case 'RUN_TIMEOUT':
      return '已达到本轮总时长上限，已有片段保留，本次未自动重试。';
    case 'RUN_BUDGET_EXCEEDED':
      return '已达到本轮调用或内容预算，已有片段保留，未继续启动步骤。';
    case 'RUN_INTERRUPTED':
      return '运行服务已中断，已有片段保留，本次未自动重新执行。';
    case 'SESSION_NOT_FOUND':
      return '未找到可继续的本人会话，请返回历史列表重新核对。';
    case 'SESSION_DELETED':
      return '此会话已删除，不能重新写回；当前输入仍保留，可用于新对话。';
    case 'SESSION_CONTEXT_CHANGED':
      return '会话内容已在另一处更新，请重新读取后再发送；当前输入仍保留。';
    case 'SESSION_EXISTS':
      return '这个会话已有内容，请核对后选择继续，或明确开始新对话。';
    case 'SESSION_MODE_INVALID':
      return '会话版本条件不完整，请重新核对上下文后发送。';
    case 'RUN_CANCELLED':
      return '运行已取消，未完成的内容仅供查看。';
    case 'RUN_FAILED':
      return '本次运行未完成，请核对服务与模型配置后再试。';
    case 'ACTION_RESOLVED':
      return '此提案已经处理，请核对当前状态。';
    case 'ACTION_FAILED':
      return '提案执行失败，请核对当前状态后再操作。';
    case 'ACTION_EXPIRED':
      return '这份提案已过期，请根据最新日程重新预览后确认。';
    case 'ACTION_LEGACY_UNVERIFIED':
      return '旧版提案缺少可核验的版本记录，请重新生成预览。';
    case 'COURSE_PERMISSION_PREVIEW_REQUIRED':
      return '请在任务设置中选择是否可课内完成，再核对新的安排预览。';
    case 'COURSE_ACK_REQUIRED':
      return '请核对重叠的课程与时段，并明确选择是否仍这样安排。';
    case 'COURSE_ACK_STALE':
      return '课表或任务已经变化，上次课内确认已失效。请重新预览并核对。';
    case 'COURSE_ACK_INVALID':
      return '课内确认与当前候选不一致，请重新核对这份预览。';
    case 'ACTION_STALE':
      return '课程或任务已变化，本次没有执行。请根据最新数据重新预览。';
    case 'ACTION_CONFLICT':
      return '候选安排与课程、已有任务或候选中的其他任务重叠，请调整后重新预览。';
    case 'ACTION_INVALID':
      return '变更内容未通过检查，请核对名称、时间与目标记录。';
    case 'ACTION_UNSUPPORTED':
      return '暂不支持执行此类提案。';
    case 'NETWORK_ERROR':
      return '无法连接行简服务，请检查网络和服务地址。';
    case 'INVALID_RESPONSE':
      return '服务返回了无法识别的结果，请稍后刷新核对。';
    case 'ONBOARDING_STALE':
      return '校园资料或课表已更新，当前输入仍保留。请读取最新资料后重新核对。';
    case 'ONBOARDING_OPERATION_CONFLICT':
      return '这次保存标识已用于另一份资料，请先核对原保存回执。';
    case 'ONBOARDING_OPERATION_NOT_FOUND':
      return '未查到保存回执，可使用原内容和原操作标识重试。';
    case 'ONBOARDING_INVALID':
      return '资料格式未通过检查，请核对输入和保存版本。';
    case 'ONBOARDING_FAILED':
      return '保存结果尚未确认，请先核对回执，当前输入仍保留。';
    case 'ONBOARDING_NOT_FOUND':
      return '未找到当前账号，请重新登录后核对。';
    case 'TIMETABLE_STALE':
      return '课表已被其他操作更新。当前草稿仍保留，请读取最新课表后重新核对。';
    case 'TIMETABLE_OPERATION_CONFLICT':
      return '这次保存标识已用于另一份课表，请先核对保存回执。';
    case 'TIMETABLE_CLEAR_CONFIRMATION_REQUIRED':
      return '清空课表需要再次明确确认。';
    case 'TIMETABLE_INVALID':
      return '课表内容未通过检查，请核对日期、时间、课程名称和重复课程。';
    case 'TIMETABLE_OPERATION_NOT_FOUND':
      return '未找到这次保存的回执，可使用原内容和原操作标识重试。';
    case 'TIMETABLE_SAVE_FAILED':
      return '未能确认课表保存结果，请先核对回执，不要重复新建保存操作。';
    default:
      return '';
  }
}

function httpErrorMessage(statusCode: number): string {
  switch (statusCode) {
    case 401:
      // Old servers may use 401 for model credentials; this alone must never trigger logout.
      return '请求未获授权，请检查账户或服务配置。';
    case 403:
      return '当前操作未获授权，请检查权限。';
    case 404:
      return '未找到请求的内容，请刷新后再试。';
    case 408:
    case 504:
      return knownErrorMessage('REQUEST_TIMEOUT');
    case 409:
      return '当前数据状态已变化，请先刷新核对。';
    case 422:
      return '请求信息不完整或格式不正确，请检查后再试。';
    case 429:
      return '请求过于频繁，请稍后再试。';
    default:
      return statusCode >= 500 ? '行简服务暂时不可用，请稍后再试。'
        : '请求未能完成，请检查输入后再试。';
  }
}

export function requestFailure(statusCode: number, responseText: string): CampusFlowRequestError {
  let code = '';
  try {
    const payload = JSON.parse(responseText) as ErrorCodePayload | null;
    if (payload !== null && typeof payload.code === 'string') {
      code = payload.code;
    }
  } catch {
    // Neither server response bodies nor transport diagnostics are user-facing error messages.
  }
  const message = knownErrorMessage(code);
  return message.length > 0 ? new CampusFlowRequestError(statusCode, code, message)
    : new CampusFlowRequestError(statusCode, 'HTTP_ERROR', httpErrorMessage(statusCode));
}

export function localRequestFailure(code: string, statusCode: number = 0): CampusFlowRequestError {
  const message = knownErrorMessage(code);
  return new CampusFlowRequestError(statusCode, message.length > 0 ? code : 'NETWORK_ERROR',
    message.length > 0 ? message : knownErrorMessage('NETWORK_ERROR'));
}

export function displayToolTraces(traces?: ToolTrace[]): ToolDisplaySummary[] {
  if (!Array.isArray(traces)) {
    return [];
  }
  const allowedStates = ['success', 'empty', 'error', 'unavailable', 'pending', 'unverified', 'demo'];
  return traces.map((trace: ToolTrace): ToolDisplaySummary => {
    const display = trace?.display;
    if (display !== undefined && display !== null && typeof display.label === 'string' &&
      display.label.trim().length > 0 && typeof display.summary === 'string' &&
      display.summary.trim().length > 0 && allowedStates.includes(display.state)) {
      const summary: ToolDisplaySummary = { label: display.label, state: display.state, summary: display.summary };
      // EvidencePanel validates only the public source projection; raw tool arguments/results remain unused.
      if (Array.isArray(display.evidence)) { summary.evidence = display.evidence; }
      return summary;
    }
    return { label: '工具调用', state: 'unverified', summary: '服务未提供可核验的工具摘要。' };
  });
}

export function mergeActions(current: PendingAction[], incoming: PendingAction[]): PendingAction[] {
  const merged: PendingAction[] = [];
  current.concat(incoming).forEach((action: PendingAction) => {
    const index = merged.findIndex((item: PendingAction) => item.proposal_id === action.proposal_id);
    if (index < 0) {
      merged.push(action);
    } else if (merged[index].status !== 'confirmed' && merged[index].status !== 'cancelled') {
      merged[index] = action;
    }
  });
  return merged;
}

export function restoreDraft(current: string, failed: string): string {
  return current.trim().length === 0 ? failed : current;
}
