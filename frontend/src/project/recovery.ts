import { projectSchema, type Project } from '../model';
import { isNativeIOS, nativeBridge } from '../native';
import { editableContent, type Draft } from './saveSession';
import { newUUID } from '../uuid';

export const writerId = newUUID();
const prefix = 'bjj:recovery:';
const key = (draft: Draft) => `${prefix}${draft.project.projectId}:${draft.writerId}`;

export async function writeDraft(draft: Draft) {
  const text = JSON.stringify(draft);
  if (text.length > 4 * 1024 * 1024)
    throw new Error('Recovery draft exceeds the local limit. Save now.');
  if (isNativeIOS()) await nativeBridge.writeRecoveryDraft({ draft });
  else localStorage.setItem(key(draft), text);
}
export async function clearDraft(draft: Draft) {
  if (isNativeIOS())
    await nativeBridge.clearRecoveryDraft({
      projectId: draft.project.projectId,
      writerId: draft.writerId,
      draftId: draft.draftId,
    });
  else {
    const text = localStorage.getItem(key(draft));
    if (text && (JSON.parse(text) as Draft).draftId === draft.draftId)
      localStorage.removeItem(key(draft));
  }
}
export async function findDrafts(project: Project): Promise<{ drafts: Draft[]; corrupt: boolean }> {
  const raw: unknown[] = [];
  let corrupt = false;
  if (isNativeIOS())
    raw.push(...(await nativeBridge.getRecoveryDrafts({ projectId: project.projectId })).drafts);
  else {
    for (let index = 0; index < localStorage.length; index++) {
      const name = localStorage.key(index);
      if (!name?.startsWith(`${prefix}${project.projectId}:`)) continue;
      try {
        raw.push(JSON.parse(localStorage.getItem(name)!));
      } catch {
        corrupt = true;
      }
    }
  }
  const drafts: Draft[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') {
      corrupt = true;
      continue;
    }
    const value = item as Draft;
    const parsed = projectSchema.safeParse(value.project);
    const id = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    if (
      value.version !== 1 ||
      !id.test(value.writerId) ||
      !id.test(value.draftId) ||
      !parsed.success ||
      parsed.data.projectId !== project.projectId ||
      !Number.isFinite(Date.parse(value.savedAt))
    ) {
      corrupt = true;
      continue;
    }
    if (editableContent(parsed.data) !== editableContent(project))
      drafts.push({ ...value, project: parsed.data });
  }
  return { drafts: drafts.sort((a, b) => b.savedAt.localeCompare(a.savedAt)), corrupt };
}
