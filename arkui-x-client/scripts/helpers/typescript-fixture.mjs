import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

// Tests use the declared, locked compiler instead of requiring a desktop IDE.
// A deliberate compiler override remains available for native-toolchain comparisons.
export function loadTypeScript() {
  const override = process.env.CAMPUSFLOW_TYPESCRIPT_PATH?.trim();
  try {
    return require(override || 'typescript');
  } catch (cause) {
    throw new Error('Client test compiler unavailable. Run npm ci --ignore-scripts --audit=false --fund=false ' +
      'in arkui-x-client, or set CAMPUSFLOW_TYPESCRIPT_PATH to an existing compiler.', { cause });
  }
}
