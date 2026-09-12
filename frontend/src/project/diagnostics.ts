/** Allowlisted diagnostics: never copy arbitrary errors, identifiers or media. */
const codes = new Set([
  'PROJECT_CONFLICT',
  'PROJECT_CORRUPT',
  'SCHEMA_UNSUPPORTED',
  'CAPABILITY_UNSUPPORTED',
  'STORAGE_LOW',
  'STORAGE_UNAVAILABLE',
  'ASSET_MISSING',
  'ASSET_CHANGED',
  'ASSET_BUSY',
  'ASSET_RETAINED',
  'ASSET_UNSAFE',
  'EXPORT_INPUT_MISSING',
  'EXPORT_INPUT_INVALID',
  'EXPORT_INTERRUPTED',
  'EXPORT_FAILED',
  'EXPORT_VALIDATION_FAILED',
  'PERMISSION_DENIED',
  'JOB_CANCELLED',
  'CONNECTION_UNAVAILABLE',
  'REQUEST_FAILED',
  'SAVE_FAILED',
]);
const entries: { code: string; at: string }[] = [];
export function recordDiagnostic(code: string) {
  entries.push({ code: codes.has(code) ? code : 'REQUEST_FAILED', at: new Date().toISOString() });
  if (entries.length > 50) entries.shift();
}
export function diagnosticSummary(platform: 'ios' | 'desktop') {
  return JSON.stringify(
    {
      formatVersion: 1,
      app: 'BJJ Telestrator',
      version: __APP_VERSION__,
      build: __BUILD_SHA__,
      platform,
      generatedAt: new Date().toISOString(),
      events: entries,
      includesMedia: false,
    },
    null,
    2,
  );
}
