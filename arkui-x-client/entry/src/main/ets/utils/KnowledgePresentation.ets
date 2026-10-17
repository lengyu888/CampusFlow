import { KnowledgeHit, KnowledgeSearch, DataEvidence } from '../model/ApiModels';
import { publicSourceUrl } from './EvidencePresentation';

export function validKnowledgeHit(value: KnowledgeHit): boolean {
  if (value === null || typeof value !== 'object' || typeof value.source_id !== 'string' ||
    !/^[A-Za-z0-9._:-]{1,128}$/.test(value.source_id) || typeof value.title !== 'string' || value.title.trim().length === 0 || value.title.length > 300 ||
    typeof value.section !== 'string' || value.section.length > 300 || typeof value.summary !== 'string' || value.summary.length > 3000 ||
    typeof value.excerpt !== 'string' || value.excerpt.length > 1000 || typeof value.school !== 'string' || value.school.length > 150 ||
    typeof value.campus !== 'string' || value.campus.length > 150 || typeof value.reviewed_at !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}$/.test(value.reviewed_at) || publicSourceUrl(value.url) === null) { return false; }
  const date = new Date(`${value.reviewed_at}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value.reviewed_at;
}
export function validKnowledgeSearch(value: KnowledgeSearch, query: string): boolean {
  return value !== null && typeof value === 'object' && value.query === query && ['found', 'missing', 'unsupported'].includes(value.status) &&
    typeof value.message === 'string' && value.message.length <= 2000 && Array.isArray(value.hits) && value.hits.length <= 3 &&
    (value.status === 'found' ? value.hits.length > 0 : value.hits.length === 0) && value.hits.every(validKnowledgeHit) &&
    new Set(value.hits.map((item: KnowledgeHit) => item.source_id)).size === value.hits.length && Array.isArray(value.evidence);
}
export function knowledgeEvidence(hit: KnowledgeHit): DataEvidence[] {
  return [{ source_id: hit.source_id, label: `${hit.title} · ${hit.section}`, kind: 'reference', status: 'unverified',
    updated_at: null, expires_at: null, url: publicSourceUrl(hit.url),
    note: `官方参考资料，整理核对日 ${hit.reviewed_at}；核对日期不等于原文发布日期或现行有效期，不用于断言实时开放、座位、考试或个人信息。` }];
}
