import { beforeEach, describe, expect, it } from 'vitest';
import { useEditor } from './store';
import { arrow, fixture } from './testFixtures';

describe('project edit history', () => {
  beforeEach(() => useEditor.getState().setProject(fixture()));
  it('groups a complete pointer gesture into one command and restores geometry through undo/redo', () => {
    useEditor.getState().edit((project) => {
      project.annotations.push(arrow());
    });
    const initial = structuredClone(useEditor.getState().project!.annotations[0]);
    // Pointer previews live outside the project. Only the completed gesture commits.
    useEditor.getState().edit((project) => {
      const item = project.annotations[0];
      if (item.type === 'arrow') {
        item.geometry.x1 = 0.1;
        item.geometry.x2 = 0.9;
        item.strokeColor = '#ffff00';
      }
    });
    expect(useEditor.getState().past).toHaveLength(2);
    useEditor.getState().undo();
    expect(useEditor.getState().project!.annotations[0]).toEqual(initial);
    useEditor.getState().redo();
    expect(useEditor.getState().project!.annotations[0].strokeColor).toBe('#ffff00');
  });
  it('does not record playhead or selection changes, no-op edits, or invalid data', () => {
    useEditor.getState().setTime(7);
    useEditor.getState().select(arrow().id);
    useEditor.getState().edit(() => undefined);
    expect(useEditor.getState().past).toHaveLength(0);
    useEditor.getState().edit((project) => {
      project.annotations.push({ ...arrow(), endSec: 100 });
    });
    expect(useEditor.getState().project!.annotations).toHaveLength(0);
    expect(useEditor.getState().past).toHaveLength(0);
    expect(useEditor.getState().error).toMatch(/after the video/);
  });
  it('clears redo after a new edit and keeps the prior project immutable', () => {
    const previous = useEditor.getState().project!;
    useEditor.getState().edit((project) => {
      project.annotations.push(arrow());
    });
    expect(previous.annotations).toHaveLength(0);
    useEditor.getState().undo();
    expect(useEditor.getState().future).toHaveLength(1);
    useEditor.getState().edit((project) => {
      project.projectName = 'Another round';
    });
    expect(useEditor.getState().future).toHaveLength(0);
  });
});
