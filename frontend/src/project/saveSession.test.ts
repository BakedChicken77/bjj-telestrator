import { describe, expect, it, vi } from 'vitest';
import { fixture } from '../testFixtures';
import { useEditor } from '../store';
import { ProjectError } from './migrations';
import { editableContent, SaveSession, type SaveDependencies } from './saveSession';
import type { Project } from '../model';
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
function setup(save?: SaveDependencies['save']) {
  const initial = fixture();
  const deps: SaveDependencies = {
    save: save ?? vi.fn(async (p) => ({ ...p, revision: p.revision + 1 })),
    read: vi.fn(async () => initial),
    journal: vi.fn(async () => undefined),
    clear: vi.fn(async () => undefined),
    acknowledge: (target, saved) =>
      editableContent(session.latest) === editableContent(target)
        ? saved
        : { ...session.latest, revision: saved.revision },
    notify: vi.fn(),
    writerId: crypto.randomUUID(),
  };
  const session = new SaveSession(initial, deps);
  return { initial, session, deps };
}
describe('authoritative save queue', () => {
  it('serializes rapid edits and exports against the final acknowledged revision', async () => {
    const gate = deferred<Project>();
    const calls: Project[] = [];
    const { session, initial } = setup(async (p) => {
      calls.push(p);
      return calls.length === 1 ? gate.promise : { ...p, revision: p.revision + 1 };
    });
    session.update({ ...initial, projectName: 'first' });
    const pending = session.flush();
    await vi.waitFor(() => expect(calls).toHaveLength(1));
    session.update({ ...initial, projectName: 'second' });
    const also = session.flush();
    gate.resolve({ ...calls[0], revision: 2 });
    expect((await pending).projectName).toBe('second');
    expect((await also).revision).toBe(3);
    expect(calls.map((p) => p.revision)).toEqual([1, 2]);
    expect(session.state.status).toBe('saved');
  });
  it('preserves a failed draft, retries explicitly, and never reports Saved on failure', async () => {
    const { initial, session, deps } = setup(
      vi
        .fn()
        .mockRejectedValueOnce(new Error('offline'))
        .mockImplementation(async (p: Project) => ({ ...p, revision: 2 })),
    );
    session.update({ ...initial, projectName: 'keep me' });
    await expect(session.flush()).rejects.toThrow('offline');
    expect(session.state.status).toBe('failed');
    expect(deps.clear).not.toHaveBeenCalled();
    expect((await session.flush()).revision).toBe(2);
  });
  it('acknowledges a lost successful save response only when the durable content matches', async () => {
    const { initial, session, deps } = setup(async () => {
      throw new Error('response lost');
    });
    const draft = { ...initial, projectName: 'committed' };
    deps.read = async () => ({ ...draft, revision: 2 });
    session.update(draft);
    expect((await session.flush()).revision).toBe(2);
    expect(session.state.status).toBe('saved');
  });
  it('blocks stale writes and further automatic retries without dropping either version', async () => {
    const save = vi.fn(async () => {
      throw new ProjectError('PROJECT_CONFLICT', 'conflict');
    });
    const { initial, session, deps } = setup(save);
    deps.read = async () => ({ ...initial, projectName: 'other tab', revision: 2 });
    session.update({ ...initial, projectName: 'my edit' });
    await expect(session.flush()).rejects.toThrow();
    session.update({ ...initial, projectName: 'still mine' });
    await expect(session.flush()).rejects.toThrow();
    expect(save).toHaveBeenCalledTimes(1);
    expect(deps.clear).not.toHaveBeenCalled();
    expect(session.latest.projectName).toBe('still mine');
    expect(session.state.status).toBe('conflict');
  });
  it('saves even when draft storage fails and guards a newly opened session from late acknowledgments', async () => {
    const gate = deferred<Project>();
    const { initial, session, deps } = setup(() => gate.promise);
    deps.journal = async () => {
      throw new Error('storage full');
    };
    const ack = vi.fn(deps.acknowledge);
    deps.acknowledge = ack;
    session.update({ ...initial, projectName: 'retained' });
    const saved = session.flush();
    await vi.waitFor(() => expect(session.state.status).toBe('saving'));
    session.dispose();
    gate.resolve({ ...initial, projectName: 'retained', revision: 2 });
    await saved;
    expect(ack).not.toHaveBeenCalled();
    expect(deps.clear).not.toHaveBeenCalled();
  });
  it('never restores storage revisions through undo/redo or arbitrary edit recipes', () => {
    const initial = fixture();
    useEditor.getState().setProject(initial);
    useEditor.getState().edit((p) => {
      p.projectName = 'edit';
      p.revision = 999;
    });
    const target = useEditor.getState().project!;
    expect(target.revision).toBe(1);
    useEditor.getState().acknowledge(target, { ...target, revision: 2 });
    useEditor.getState().undo();
    expect(useEditor.getState().project!.revision).toBe(2);
    useEditor.getState().redo();
    expect(useEditor.getState().project!.revision).toBe(2);
  });
});
