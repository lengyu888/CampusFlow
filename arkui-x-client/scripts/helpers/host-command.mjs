import { accessSync, constants, statSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export function findHostCommand(command, { platform = process.platform, env = process.env, cwd = process.cwd() } = {}) {
  const windows = platform === 'win32';
  const executable = candidate => {
    try {
      if (!statSync(candidate).isFile()) return false;
      accessSync(candidate, windows ? constants.F_OK : constants.X_OK);
      return true;
    } catch { return false; }
  };
  if (/[\\/]/.test(command)) {
    const candidate = path.resolve(cwd, command);
    return executable(candidate) ? candidate : undefined;
  }
  const pathKey = Object.keys(env).find(key => key.toUpperCase() === 'PATH');
  const extensionsKey = Object.keys(env).find(key => key.toUpperCase() === 'PATHEXT');
  const extensions = windows ? ['', ...(env[extensionsKey] || '.EXE;.CMD;.BAT;.COM').split(';')].filter((value, index, all) => all.indexOf(value) === index) : [''];
  for (const directory of (env[pathKey] || '').split(windows ? ';' : path.delimiter).filter(Boolean)) {
    for (const extension of extensions) {
      const candidate = path.resolve(cwd, directory.replace(/^"|"$/g, ''), command + extension);
      if (executable(candidate)) return candidate;
    }
  }
  return undefined;
}

// npm CLI launchers on Windows are .cmd files, which CreateProcess cannot run
// directly. Only the internally generated build/probe flags enter the command
// line; the script path travels through an environment variable inside quotes.
export function spawnHostCommandSync(command, args, options = {}) {
  const env = options.env || process.env;
  const executable = findHostCommand(command, { env, cwd: options.cwd }) || command;
  if (process.platform !== 'win32' || !/\.(?:cmd|bat)$/i.test(executable)) {
    return spawnSync(executable, args, { ...options, shell: false });
  }
  if (/["\r\n]/.test(executable) || args.some(arg => !/^[A-Za-z0-9_.:/=+\-]+$/.test(arg))) {
    throw new Error('Windows batch invocation requires a valid path and fixed build/probe flags');
  }
  const interpreter = env.ComSpec || env.COMSPEC || path.join(env.SystemRoot || 'C:\\Windows', 'System32', 'cmd.exe');
  const line = `""%CAMPUSFLOW_COMMAND_SCRIPT%" ${args.map(arg => `"${arg}"`).join(' ')}"`;
  return spawnSync(interpreter, ['/d', '/s', '/v:off', '/c', line], {
    ...options,
    env: { ...env, CAMPUSFLOW_COMMAND_SCRIPT: executable },
    windowsVerbatimArguments: true,
    windowsHide: true,
    shell: false
  });
}
