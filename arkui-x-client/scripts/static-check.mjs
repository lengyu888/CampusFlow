import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Checked against Huawei registry package @ohos/hvigor-ohos-arkui-x-plugin 4.24.2
// and its declared development companion @ohos/hvigor-ohos-plugin 6.24.2:
// package/res/schemas/arkui-x-config-schema.json and
// CoreModuleModelImpl.isIgnoreCrossPlatformCheckModule. This is a versioned
// configuration preflight, not ArkTS compilation or SDK API validation.
export function checkArkUIXConfiguration(config, pluginVersion) {
  const failures = [];
  const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const strings = value => Array.isArray(value) && value.every(item => typeof item === 'string');
  if (pluginVersion !== '4.24.2') {
    failures.push('ArkUI-X 插件版本已变化：请先核对新版本的实际配置 schema，再更新预检。');
  }
  if (!object(config)) { return [...failures, 'ArkUI-X 配置必须是对象。']; }
  for (const key of Object.keys(config)) {
    if (!['crossplatform', 'modules', 'buildOption'].includes(key)) {
      failures.push(`ArkUI-X 顶层配置不支持 ${key}；ignoreCrossPlatform 应位于 buildOption 中。`);
    }
  }
  if (typeof config.crossplatform !== 'boolean') { failures.push('crossplatform 必须是布尔值。'); }
  else if (!config.crossplatform) { failures.push('本项目必须保留 crossplatform: true，不能关闭跨端构建。'); }
  if (!strings(config.modules) || config.modules.length < 1) {
    failures.push('ArkUI-X modules 必须是非空字符串数组。');
  }
  if (Object.hasOwn(config, 'buildOption')) {
    if (!object(config.buildOption)) { failures.push('buildOption 必须是对象。'); }
    else {
      for (const key of Object.keys(config.buildOption)) {
        if (!['resConfigs', 'ignoreCrossPlatform'].includes(key)) {
          failures.push(`ArkUI-X buildOption 不支持 ${key}。`);
        }
      }
      if (Object.hasOwn(config.buildOption, 'resConfigs') && !strings(config.buildOption.resConfigs)) {
        failures.push('buildOption.resConfigs 必须是字符串数组。');
      }
      if (Object.hasOwn(config.buildOption, 'ignoreCrossPlatform') && typeof config.buildOption.ignoreCrossPlatform !== 'boolean') {
        failures.push('buildOption.ignoreCrossPlatform 必须是布尔值。');
      }
    }
  }
  return failures;
}

export function runStaticCheck() {
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
      const ignoredDirectories = new Set([
        '.git', '.gradle', '.hvigor', 'build', 'DerivedData', 'node_modules', 'oh_modules', 'Pods'
      ]);
      if (statSync(path).isDirectory()) {
        return ignoredDirectories.has(name) ? [] : walk(path);
      }
      return [path];
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

  try {
    const arkUIXConfig = JSON.parse(readFileSync(join(root, '.arkui-x/arkui-x-config.json5'), 'utf8'));
    const hvigorConfig = JSON.parse(readFileSync(join(root, 'hvigor/hvigor-config.json5'), 'utf8'));
    failures.push(...checkArkUIXConfiguration(arkUIXConfig, hvigorConfig.dependencies?.['@ohos/hvigor-ohos-arkui-x-plugin']));
  } catch (error) {
    failures.push(`无法执行 ArkUI-X 插件配置预检：${error.message}`);
  }

  const importPattern = /from\s+['"](\.\.?\/[^'"]+)['"]|import\(\s*['"](\.\.?\/[^'"]+)['"]\s*\)/g;
  for (const path of arkFiles) {
    const source = readFileSync(path, 'utf8');
    for (const match of source.matchAll(importPattern)) {
      const imported = match[1] ?? match[2];
      const target = normalize(resolve(dirname(path), imported));
      if (!existsSync(`${target}.ets`) && !existsSync(`${target}.ts`) && !existsSync(target)) {
        failures.push(`无法解析导入：${path.replace(root, '')} -> ${imported}`);
      }
    }
    if (source.includes('@kit.CoreSpeechKit') &&
        path !== join(root, 'entry/src/main/ets/services/HarmonyVoiceDriver.ets')) {
      failures.push(`鸿蒙语音 API 必须隔离在 HarmonyVoiceDriver，不能直接载入共享页面：${path.replace(root, '')}`);
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

  return { failures, arkFileCount: arkFiles.length, configFileCount: configFiles.length };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = runStaticCheck();
  if (result.failures.length > 0) {
    console.error(`ArkUI-X 工程文件与契约预检失败（${result.failures.length} 项）：`);
    result.failures.forEach(failure => console.error(`- ${failure}`));
    process.exitCode = 1;
  } else {
    console.log(`ArkUI-X 工程文件与契约预检通过：${result.arkFileCount} 个 ArkTS/TS 文件，${result.configFileCount} 个配置文件。`);
    console.log('已检查工程骨架、JSON 语法、固定版本跨端配置、相对导入、密钥泄漏、网络权限与 FastAPI 接口引用。');
    console.log('未执行 ArkTS 类型检查、原生编译、SDK API 验证或设备验证。');
  }
}
