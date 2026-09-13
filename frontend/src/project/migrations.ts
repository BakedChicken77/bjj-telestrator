/** Pure migration registry. Services preserve the original before installation. */
export const SCHEMA_VERSION = 2;
export const CAPABILITIES = ['project.revisions.v1', 'media.hdr-to-sdr.v1'] as const;

export class ProjectError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'ProjectError';
  }
}

type Document = Record<string, unknown>;
export const migrations: Record<number, (document: Document) => Document> = {
  1: (document) => ({
    ...document,
    schemaVersion: 2,
    revision: 1,
    requiredCapabilities: [
      ...new Set([
        ...((document.requiredCapabilities as string[] | undefined) ?? []),
        'project.revisions.v1',
      ]),
    ],
  }),
};

export function migrateDocument(value: unknown): Document {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new ProjectError('PROJECT_CORRUPT', 'The project document is damaged.');
  const document = value as Document;
  const version = document.schemaVersion;
  if (!Number.isSafeInteger(version) || (version as number) < 1)
    throw new ProjectError('PROJECT_CORRUPT', 'The project schema version is invalid.');
  if ((version as number) > SCHEMA_VERSION)
    throw new ProjectError(
      'SCHEMA_UNSUPPORTED',
      'Upgrade required: this project uses a newer format.',
    );
  const capabilities =
    document.requiredCapabilities === undefined ? [] : document.requiredCapabilities;
  if (
    !Array.isArray(capabilities) ||
    capabilities.length > 128 ||
    capabilities.some((c: unknown) => typeof c !== 'string' || !c || c.length > 100) ||
    new Set(capabilities).size !== capabilities.length
  )
    throw new ProjectError('PROJECT_CORRUPT', 'The project capability list is invalid.');
  if (capabilities.some((c: string) => !(CAPABILITIES as readonly string[]).includes(c)))
    throw new ProjectError(
      'CAPABILITY_UNSUPPORTED',
      'Upgrade required: this project needs unsupported capabilities.',
    );
  let result = structuredClone(document);
  while ((result.schemaVersion as number) < SCHEMA_VERSION)
    result = migrations[result.schemaVersion as number](result);
  if (!(result.requiredCapabilities as string[] | undefined)?.includes('project.revisions.v1'))
    throw new ProjectError('PROJECT_CORRUPT', 'The project revision capability is missing.');
  return result;
}
