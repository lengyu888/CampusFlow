import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, extname, join, normalize, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const workspace = resolve(root, '..');
const required = [
  '.arkui-x/arkui-x-config.json5',
  'AppScope/app.json5',
  'build-profile.json5',
  'hvigorfile.ts',
  'entry/build-profile.json5',
  'entry/src/main/module.json5',
  'entry/src/main/ets/entryability/EntryAbility.ets',
  'entry/src/main/ets/services/CampusFlowApi.ets',
  'entry/src/main/ets/pages/Index.ets'
];

const failures = [];
for (const relative of required) {
  if (!existsSync(join(root, relative))) {
    failures.push(`缺少必要文件：${relative}`);
  }
}

function walk(directory) {
  return readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    return statSync(path).isDirectory() ? walk(path) : [path];
  });
}

const files = walk(root);
const arkFiles = files.filter((path) => extname(path) === '.ets' || extname(path) === '.ts');
const configFiles = files.filter((path) => extname(path) === '.json' || extname(path) === '.json5');

for (const path of configFiles) {
  try {
    JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    failures.push(`JSON/JSON5 语法错误：${path.replace(root, '')} (${error.message})`);
  }
}

const importPattern = /from\s+['"](\.\.?\/[^'"]+)['"]/g;
for (const path of arkFiles) {
  const source = readFileSync(path, 'utf8');
  for (const match of source.matchAll(importPattern)) {
    const target = normalize(resolve(dirname(path), match[1]));
    if (!existsSync(`${target}.ets`) && !existsSync(`${target}.ts`) && !existsSync(target)) {
      failures.push(`无法解析导入：${path.replace(root, '')} -> ${match[1]}`);
    }
  }
}

const allSource = arkFiles.map((path) => readFileSync(path, 'utf8')).join('\n');
if (/sk-[A-Za-z0-9]{12,}/.test(allSource)) {
  failures.push('客户端源码中疑似包含真实 API Key。');
}

const moduleConfig = readFileSync(join(root, 'entry/src/main/module.json5'), 'utf8');
if (!moduleConfig.includes('ohos.permission.INTERNET')) {
  failures.push('entry 模块未声明 INTERNET 权限。');
}

const backendApiPath = join(workspace, 'agent-service/src/campusflow_agent/api.py');
if (existsSync(backendApiPath)) {
  const backendApi = readFileSync(backendApiPath, 'utf8');
  const contracts = [
    '/api/v1/auth/login', '/api/v1/auth/register', '/api/v1/onboarding', '/api/v1/me/context',
    '/api/v1/chat', '/api/v1/campus-data/route', '/api/v1/planning', '/api/v1/tasks',
    '/api/v1/skills', '/api/v1/me/settings', '/api/v1/schedule-subscriptions'
  ];
  for (const endpoint of contracts) {
    if (!allSource.includes(endpoint)) {
      failures.push(`客户端缺少接口引用：${endpoint}`);
    }
    if (!backendApi.includes(endpoint)) {
      failures.push(`后端缺少对应接口：${endpoint}`);
    }
  }
}

if (failures.length > 0) {
  console.error(`ArkUI-X 静态验收失败（${failures.length} 项）：`);
  failures.forEach((failure) => console.error(`- ${failure}`));
  process.exit(1);
}

console.log(`ArkUI-X 静态验收通过：${arkFiles.length} 个 ArkTS/TS 文件，${configFiles.length} 个配置文件。`);
console.log('已检查工程骨架、JSON 配置、相对导入、密钥泄漏、网络权限与 FastAPI 接口契约。');
