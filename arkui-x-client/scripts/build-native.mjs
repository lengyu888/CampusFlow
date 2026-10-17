#!/usr/bin/env node
// Print a reviewable build plan by default. No SDK installation, ace create/repair, or device command.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
const root = resolve(import.meta.dirname, '..');
const argumentsIn = process.argv.slice(2);
const platform = argumentsIn[0];
const allowed = new Set(['--execute', '--release']);
if (!['harmony', 'android', 'ios'].includes(platform) || argumentsIn.slice(1).some(value => !allowed.has(value))) {
  console.error('用法：node scripts/build-native.mjs harmony|android|ios [--release] [--execute]');
  process.exit(2);
}
const execute = argumentsIn.includes('--execute');
const mode = argumentsIn.includes('--release') ? '--release' : '--debug';
const target = {harmony:'hap',android:'apk',ios:'ios'}[platform];
const args = ['build', target, mode, ...(platform === 'ios' ? ['--nosign'] : [])];
for (const path of ['.arkui-x/arkui-x-config.json5','build-profile.json5','entry/src/main/module.json5']) {
  JSON.parse(readFileSync(resolve(root, path), 'utf8'));
}
console.log(`工作目录：${root}`);
console.log(`构建命令：ace ${args.join(' ')}`);
console.log('需预先配置匹配的 ArkUI-X/Harmony SDK；Android 另需 JDK/Android SDK，iOS 另需 macOS/Xcode。');
console.log('此命令不安装、修复或部署到设备；iOS 产物不签名，HAP/Android 签名由本地工具链管理。');
if (!execute) { console.log('当前只显示命令，未调用任何原生工具。确认环境就绪后可加 --execute。'); process.exit(0); }
if (platform === 'ios' && process.platform !== 'darwin') { console.error('iOS 构建需要 macOS。'); process.exit(2); }
const cli = process.env.CAMPUSFLOW_ACE_BIN || 'ace';
if (process.env.CAMPUSFLOW_ACE_BIN && !existsSync(cli)) { console.error('CAMPUSFLOW_ACE_BIN 指向的现有工具不存在。'); process.exit(2); }
const checked = spawnSync(cli, ['--version'], {cwd:root, encoding:'utf8', shell:false, timeout:15000});
if (checked.error || checked.status !== 0) { console.error('找不到可用的现有 ace CLI；未尝试安装。'); process.exit(2); }
console.log(`现有 ace 版本：${checked.stdout.trim().slice(0,200)}`);
console.log('开始调用已有工具链；其本身可能解析/下载项目构建依赖，SDK 与原生环境须由开发者预先准备。');
const result = spawnSync(cli, args, {cwd:root, stdio:'inherit', shell:false});
if (result.error || result.status !== 0) { console.error('构建未确认成功，请以工具链错误修复环境/源码，不能据静态检查宣称可安装。'); process.exit(result.status || 1); }
const stamp = {platform, command:[cli,...args], ace:checked.stdout.trim().slice(0,200), completed_at:new Date().toISOString(), verification:'native_build_command_succeeded', device_verified:false};
writeFileSync(resolve(root, `.native-build-${platform}.local.json`), JSON.stringify(stamp,null,2)+'\n');
console.log('构建命令返回成功；请核对工具输出的实际产物与签名。安装/运行/权限及后台送达仍未验证。');
