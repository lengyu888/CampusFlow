import { createRequire, syncBuiltinESMExports } from 'node:module';

// Child-process boundary: emulate a clean CI host without altering real files.
// The declared repository TypeScript package and its standard library remain accessible.
const fs = createRequire(import.meta.url)('node:fs');
const exists = fs.existsSync;
fs.existsSync = value => /deveco|ets-loader[\\/]node_modules[\\/]typescript/i.test(String(value)) ? false : exists(value);
syncBuiltinESMExports();
