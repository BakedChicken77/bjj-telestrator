import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { projectSchema } from '../model';
import { migrateDocument } from './migrations';
const fixtures = JSON.parse(
  readFileSync(
    new URL('../../../tests/fixtures/project-conformance.json', import.meta.url),
    'utf8',
  ),
) as {
  migrationExpected: unknown;
  cases: { name: string; valid: boolean; document: unknown }[];
};
describe('shared project conformance', () => {
  for (const item of fixtures.cases)
    it(item.name, () => {
      expect(projectSchema.safeParse(item.document).success).toBe(item.valid);
    });
  it('migrates without changing optional fields, IDs, assets or timing; repeating is a no-op', () => {
    const original = structuredClone(fixtures.cases[0].document);
    const migrated = projectSchema.parse(original);
    expect(migrated).toEqual(fixtures.migrationExpected);
    expect(projectSchema.parse(migrated)).toEqual(migrated);
    expect(original).toEqual(fixtures.cases[0].document);
    expect(migrateDocument(migrated)).toEqual(migrated);
  });
});
