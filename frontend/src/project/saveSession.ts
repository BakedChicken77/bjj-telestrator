import type { Project } from '../model';
import { ProjectError } from './migrations';
import { newUUID } from '../uuid';
import { recordDiagnostic } from './diagnostics';

export type SaveStatus = 'saved' | 'pending' | 'saving' | 'failed' | 'conflict';
export type Draft = {
  version: 1;
  writerId: string;
  draftId: string;
  project: Project;
  savedAt: string;
};
export type SaveState = { status: SaveStatus; error: string | null };

export function editableContent(project: Project): string {
  const copy = { ...project } as Record<string, unknown>;
  delete copy.revision;
  delete copy.updatedAt;
  function stable(value: unknown): unknown {
    if (Array.isArray(value)) return value.map(stable);
    if (value !== null && typeof value === 'object')
      return Object.fromEntries(
        Object.entries(value)
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([key, item]) => [key, stable(item)]),
      );
    return value;
  }
  return JSON.stringify(stable(copy));
}

export interface SaveDependencies {
  save(project: Project): Promise<Project>;
  read(id: string): Promise<Project>;
  journal(draft: Draft): Promise<void>;
  clear(draft: Draft): Promise<void>;
  acknowledge(target: Project, saved: Project): Project | null;
  notify(state: SaveState): void;
  writerId: string;
}

/** One serialized writer. Edits and lifecycle/export requests share this queue. */
export class SaveSession {
  latest: Project;
  confirmed: Project;
  state: SaveState = { status: 'saved', error: null };
  private queue: Promise<unknown> = Promise.resolve();
  private journals: Promise<void> = Promise.resolve();
  private draft: Draft | null = null;
  private disposed = false;
  constructor(
    initial: Project,
    private readonly deps: SaveDependencies,
  ) {
    this.latest = this.confirmed = initial;
  }
  private report(status: SaveStatus, error: string | null = null) {
    this.state = { status, error };
    if (!this.disposed) this.deps.notify(this.state);
  }
  get dirty() {
    return editableContent(this.latest) !== editableContent(this.confirmed);
  }
  update(project: Project) {
    if (this.disposed || project.projectId !== this.latest.projectId || project === this.latest)
      return;
    this.latest = project;
    if (!this.dirty) return;
    this.draft = {
      version: 1,
      writerId: this.deps.writerId,
      draftId: newUUID(),
      project: { ...project, revision: this.confirmed.revision },
      savedAt: new Date().toISOString(),
    };
    const draft = this.draft;
    this.journals = this.journals.catch(() => undefined).then(() => this.deps.journal(draft));
    void this.journals.catch(() =>
      this.report('failed', 'Recovery storage is unavailable. Keep the app open and retry Save.'),
    );
    if (this.state.status !== 'conflict') this.report('pending');
  }
  flush(): Promise<Project> {
    const work = this.queue
      .catch(() => undefined)
      .then(async () => {
        if (this.disposed)
          throw new ProjectError('SESSION_CLOSED', 'This editing session was closed.');
        if (this.state.status === 'conflict')
          throw new ProjectError(
            'PROJECT_CONFLICT',
            this.state.error ?? 'Resolve the save conflict first.',
          );
        while (this.dirty) {
          const target = { ...this.latest, revision: this.confirmed.revision };
          const draft = this.draft;
          await this.journals.catch(() => undefined);
          this.report('saving');
          let saved: Project;
          try {
            saved = await this.deps.save(target);
          } catch (cause) {
            recordDiagnostic((cause as { code?: string })?.code ?? 'SAVE_FAILED');
            // A lost response may follow a successful commit. Acknowledge only
            // identical content at a newer revision, never merge different edits.
            const durable = await this.deps.read(target.projectId).catch(() => null);
            if (
              durable &&
              durable.revision > target.revision &&
              editableContent(durable) === editableContent(target)
            )
              saved = durable;
            else {
              const isConflict =
                (cause as { code?: string })?.code === 'PROJECT_CONFLICT' ||
                (durable !== null && durable.revision !== target.revision);
              this.report(
                isConflict ? 'conflict' : 'failed',
                isConflict
                  ? 'This project changed in another session. Recover your edits as a copy or reload the saved version.'
                  : cause instanceof Error
                    ? cause.message
                    : 'Unable to save. Keep the app open and retry.',
              );
              throw cause;
            }
          }
          this.confirmed = saved;
          if (this.disposed) return saved;
          this.latest = this.deps.acknowledge(target, saved) ?? this.latest;
          if (draft) await this.deps.clear(draft).catch(() => undefined);
          this.report(this.dirty ? 'pending' : 'saved');
        }
        if (this.draft && !this.dirty) await this.deps.clear(this.draft).catch(() => undefined);
        this.report('saved');
        return this.confirmed;
      });
    this.queue = work;
    return work;
  }
  dispose() {
    this.disposed = true;
  }
}

let active: SaveSession | null = null;
export function setActiveSave(session: SaveSession | null) {
  active = session;
}
export async function flushActiveSave() {
  if (!active) throw new ProjectError('SESSION_CLOSED', 'Open a project before saving.');
  return active.flush();
}
