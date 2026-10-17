import { ModelCatalog, ModelOption } from '../model/ApiModels';

export function validModelCatalog(value: ModelCatalog): boolean {
  if (value === null || typeof value !== 'object' || !Array.isArray(value.models) || value.models.length > 100 ||
    typeof value.default_model !== 'string') { return false; }
  const ids = new Set<string>();
  for (const model of value.models) {
    if (model === null || typeof model !== 'object' || typeof model.id !== 'string' ||
      !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/.test(model.id) || ids.has(model.id) ||
      typeof model.label !== 'string' || model.label.trim().length === 0 || model.label.length > 160 ||
      typeof model.provider !== 'string' || model.provider.trim().length === 0 || model.provider.length > 100 ||
      typeof model.available !== 'boolean' || typeof model.supports_tools !== 'boolean' ||
      typeof model.supports_streaming !== 'boolean' || typeof model.supports_reasoning !== 'boolean' ||
      typeof model.unavailable_reason !== 'string' || model.unavailable_reason.length > 500) { return false; }
    ids.add(model.id);
  }
  return value.models.length === 0 ? value.default_model === '' : ids.has(value.default_model);
}
export function modelUnavailableReason(model: ModelOption): string {
  if (!model.available) { return model.unavailable_reason.trim() || '服务配置尚未就绪。'; }
  if (!model.supports_tools || !model.supports_streaming) { return '未声明支持本应用所需的工具调用与增量回答。'; }
  return '';
}
export function modelLabel(id: string, models: ModelOption[]): string {
  const option = models.find((item: ModelOption) => item.id === id);
  return option === undefined ? `未核实模型 · ${id}` : option.label;
}
