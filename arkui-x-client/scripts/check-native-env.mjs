import { accessSync, constants, existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { findHostCommand, spawnHostCommandSync } from './helpers/host-command.mjs';
import { fileURLToPath } from 'node:url';

// Read-only prerequisite discovery. Do not invoke ACE, Gradle, Hvigor, SDK
// managers, installers or signing tools here: they may modify local state.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const windows = process.platform === 'win32';
const mac = process.platform === 'darwin';
const checks = [];
const add = (id, state, detail) => checks.push({ id, state, detail });
const directory = (path) => {
  try { return Boolean(path) && statSync(path).isDirectory(); } catch { return false; }
};
const executable = (path) => {
  try {
    if (!statSync(path).isFile()) return false;
    accessSync(path, windows ? constants.F_OK : constants.X_OK);
    return true;
  } catch { return false; }
};
const firstDirectory = (paths) => paths.filter(Boolean).find(directory);
const findCommand = name => findHostCommand(name);
const probe = (command, args) => spawnHostCommandSync(command, args, {
  encoding: 'utf8', timeout: 5000, maxBuffer: 64 * 1024, windowsHide: true, shell: false
});
const commandFile = (id, name) => {
  const path = findCommand(name);
  add(id, path ? 'present' : 'missing', path
    ? `发现命令 ${path}；未执行，不代表 SDK 或构建可用。` : `PATH 中未发现 ${name}。`);
  return path;
};

const product = JSON.parse(readFileSync(join(root, 'build-profile.json5'), 'utf8')).app.products[0];
const requestedApi = /\((\d+)\)/.exec(String(product.targetSdkVersion))?.[1];
add('project-sdk', 'present', `工程声明 ${product.runtimeOS} ${product.targetSdkVersion}；此项只读取工程配置。`);
add('node', 'present', `${process.version} (${process.execPath})；未验证与本机 ACE/Hvigor 的版本配套。`);
commandFile('ace', 'ace');
commandFile('ohpm', 'ohpm');
commandFile('hdc', 'hdc');

const devEco = firstDirectory([
  process.env.DEVECO_STUDIO_HOME,
  ...(mac ? ['/Applications/DevEco-Studio.app', '/Applications/deveco-studio.app'] : []),
  ...(windows && process.env.ProgramFiles ? [join(process.env.ProgramFiles, 'Huawei', 'DevEco Studio')] : [])
]);
add('deveco', devEco ? 'present' : 'missing', devEco
  ? `发现安装目录 ${devEco}；未启动或验证 IDE 版本。`
  : '显式环境变量及标准安装位置未发现 DevEco Studio；自定义位置需设置 DEVECO_STUDIO_HOME。');

const javaCandidates = [
  process.env.JAVA_HOME && join(process.env.JAVA_HOME, 'bin', windows ? 'java.exe' : 'java'),
  devEco && (mac ? join(devEco, 'Contents', 'jbr', 'Contents', 'Home', 'bin', 'java')
    : join(devEco, 'jbr', 'bin', windows ? 'java.exe' : 'java')),
  findCommand('java')
].filter(Boolean);
const java = javaCandidates.find(executable);
if (java) {
  const result = probe(java, ['-version']);
  const version = /(?:openjdk|java) version "([^"]+)"/i.exec(`${result.stdout || ''}\n${result.stderr || ''}`)?.[1];
  add('java', result.status === 0 && version ? 'present' : 'missing', result.status === 0 && version
    ? `Java ${version} (${java})；仍需核对构建工具兼容性。`
    : `发现 ${java}，但未获得可用 Java 版本；系统占位程序不算已安装运行时。`);
} else {
  add('java', 'missing', 'JAVA_HOME、DevEco 内置路径和 PATH 中均未发现可执行 Java。');
}

const arkRoot = firstDirectory([
  process.env.ARKUIX_SDK_HOME,
  ...(mac ? [join(homedir(), 'Library', 'ArkUI-X', 'Sdk')] : []),
  ...(windows && process.env.LOCALAPPDATA ? [join(process.env.LOCALAPPDATA, 'ArkUI-X', 'Sdk'),
    join(process.env.LOCALAPPDATA, 'Huawei', 'ArkUI-X', 'Sdk')] : [])
]);
const arkMarker = arkRoot && requestedApi && join(arkRoot, requestedApi, 'arkui-x', 'sdkConfig.json');
add('arkui-x-sdk', arkMarker && existsSync(arkMarker) ? 'present' : arkRoot ? 'unknown' : 'missing',
  arkMarker && existsSync(arkMarker)
    ? `发现 API ${requestedApi} 标记 ${arkMarker}；未校验 SDK 完整性，请用匹配版本的 ace check -v。`
    : arkRoot ? `发现 ${arkRoot}，但未找到工程对应 API 标记；目录层级、版本或完整性待核对。`
      : '显式环境变量及标准位置未发现 ArkUI-X SDK 根目录；IDE 内自定义路径未扫描。');

const harmonyRoot = firstDirectory([
  process.env.DEVECO_SDK_HOME, process.env.OHOS_SDK_HOME,
  devEco && join(devEco, ...(mac ? ['Contents', 'sdk'] : ['sdk'])),
  ...(mac ? [join(homedir(), 'Library', 'Huawei', 'Sdk'), join(homedir(), 'Library', 'OpenHarmony', 'Sdk')] : [])
]);
add('harmony-sdk', harmonyRoot ? 'unknown' : 'missing', harmonyRoot
  ? `发现候选目录 ${harmonyRoot}；尚未确认包含工程所需 HarmonyOS ${product.targetSdkVersion}，OpenHarmony SDK 不视为等价。`
  : '显式环境变量及标准位置未发现 HarmonyOS SDK；未检查 IDE 私有配置。');

const androidRoot = firstDirectory([
  process.env.ANDROID_HOME, process.env.ANDROID_SDK_ROOT,
  ...(mac ? [join(homedir(), 'Library', 'Android', 'sdk')] : []),
  ...(windows && process.env.LOCALAPPDATA ? [join(process.env.LOCALAPPDATA, 'Android', 'Sdk')] : []),
  ...(process.platform === 'linux' ? [join(homedir(), 'Android', 'Sdk')] : [])
]);
const androidBuild = readFileSync(join(root, '.arkui-x', 'android', 'app', 'build.gradle'), 'utf8');
const compileSdk = /compileSdkVersion\s+(\d+)/.exec(androidBuild)?.[1];
const buildTools = /buildToolsVersion\s+"([^"]+)"/.exec(androidBuild)?.[1];
add('android-sdk', androidRoot ? 'present' : 'missing', androidRoot
  ? `发现目录 ${androidRoot}；目录存在不代表 Android 构建通过。`
  : '显式环境变量及标准位置未发现 Android SDK。');
for (const [id, relative, version] of [
  ['android-platform', ['platforms', `android-${compileSdk}`, 'android.jar'], compileSdk],
  ['android-build-tools', ['build-tools', buildTools || '', windows ? 'aapt2.exe' : 'aapt2'], buildTools]
]) {
  const path = androidRoot && join(androidRoot, ...relative);
  add(id, !version ? 'unknown' : path && existsSync(path) ? 'present' : 'missing', !version
    ? '未能从 Gradle 配置识别请求版本。' : path && existsSync(path)
      ? `发现版本 ${version} 的必要文件；未执行编译。` : `未发现工程声明的版本 ${version} 必要文件。`);
}
commandFile('adb', 'adb');
if (!windows) {
  const wrapper = join(root, '.arkui-x', 'android', 'gradlew');
  add('gradlew-permission', executable(wrapper) ? 'present' : 'missing', executable(wrapper)
    ? 'Gradle wrapper 具有 Unix 执行权限；未执行或下载 Gradle。' : 'Gradle wrapper 缺少 Unix 执行权限。');
}

if (mac) {
  const xcodebuild = findCommand('xcodebuild');
  const result = xcodebuild && probe(xcodebuild, ['-version']);
  const version = result && /\bXcode\s+([\d.]+)/.exec(result.stdout || '')?.[1];
  add('xcode', result?.status === 0 && version ? 'present' : 'missing', result?.status === 0 && version
    ? `Xcode ${version}；未验证 iOS SDK、模拟器运行时或签名。`
    : '未获得完整 Xcode 的有效版本；只有 CommandLineTools 或 xcodebuild 命令占位不算可用。');
  const select = findCommand('xcode-select');
  const selected = select && probe(select, ['-p']);
  add('xcode-selection', selected?.status === 0 ? 'present' : 'unknown', selected?.status === 0
    ? `当前开发工具目录：${selected.stdout.trim()}` : '无法读取当前 Xcode 开发工具选择。');
  const plutil = findCommand('plutil');
  for (const file of ['app/Info.plist', 'app.xcodeproj/project.pbxproj']) {
    const lint = plutil && probe(plutil, ['-lint', join(root, '.arkui-x', 'ios', file)]);
    add(`ios-syntax:${file}`, !plutil ? 'unknown' : lint.status === 0 ? 'present' : 'unknown', !plutil
      ? '未找到 plutil，未核对文件语法。' : lint.status === 0
        ? 'plutil 语法检查通过；不代表 Xcode 构建或运行通过。' : 'plutil 检查未通过，请单独查看该文件诊断。');
  }
} else {
  add('xcode', 'missing', 'iOS 原生构建需要 macOS 和完整 Xcode；当前宿主不支持。');
}

add('native-build', 'unknown', '本次未构建、未安装、未运行三端应用；以上结果均为前置条件诊断。');
const report = { platform: process.platform, architecture: process.arch, checks,
  suggestedCommands: ['ace check -v', 'ace build hap --debug', 'ace build apk --debug',
    'ace build ios --debug --simulator --nosign'] };
if (process.argv.includes('--json')) {
  console.log(JSON.stringify(report, null, 2));
} else {
  console.log('CampusFlow 原生构建前置条件诊断（只读，不代表构建验收）');
  for (const { id, state, detail } of checks) console.log(`[${state}] ${id}: ${detail}`);
  console.log('\n环境齐备后，在 arkui-x-client 运行（先核对本机 ace build --help）：');
  for (const command of report.suggestedCommands) console.log(`  ${command}`);
  console.log('present = 找到文件或只读探测成功；missing = 缺少已探测前置项；unknown = 尚未验证。');
}
process.exitCode = checks.some(({ state }) => state === 'missing') ? 1 : 0;
