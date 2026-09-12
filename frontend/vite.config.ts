import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const version = (JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8')) as { version: string }).version;
let build = 'source-archive';
try { build = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch { /* Source ZIP builds have no git directory. */ }

export default defineConfig({
  define: { __APP_VERSION__: JSON.stringify(version), __BUILD_SHA__: JSON.stringify(build) },
  plugins: [react()],
  server: { proxy: { '/api': process.env.BJJ_API_URL ?? 'http://127.0.0.1:8000' } },
  test: { environment: 'node', include: ['src/**/*.test.ts', 'src/**/*.test.tsx'] },
});
