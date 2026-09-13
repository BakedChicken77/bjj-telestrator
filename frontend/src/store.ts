import { create } from 'zustand';
import {
  projectSchema,
  editedProjectSchema,
  retainValidatedProject,
  type Project,
  type Tool,
} from './model';
import { editableContent } from './project/saveSession';
import { shareUnchanged } from './project/shareUnchanged';

interface EditorStore {
  project: Project | null;
  selectedId: string | null;
  tool: Tool;
  currentTime: number;
  playing: boolean;
  recording: boolean;
  past: Project[];
  future: Project[];
  revision: number;
  session: number;
  error: string | null;
  setProject: (project: Project | null) => void;
  acknowledge: (target: Project, saved: Project) => Project | null;
  edit: (recipe: (draft: Project) => void) => void;
  select: (id: string | null) => void;
  setTool: (tool: Tool) => void;
  setTime: (time: number) => void;
  setPlaying: (playing: boolean) => void;
  setRecording: (recording: boolean) => void;
  setError: (error: string | null) => void;
  undo: () => void;
  redo: () => void;
}

export const useEditor = create<EditorStore>((set, get) => ({
  project: null,
  selectedId: null,
  tool: 'select',
  currentTime: 0,
  playing: false,
  recording: false,
  past: [],
  future: [],
  revision: 0,
  session: 0,
  error: null,
  setProject: (project) =>
    set({
      project: project ? retainValidatedProject(projectSchema.parse(project)) : null,
      selectedId: null,
      tool: 'select',
      currentTime: 0,
      playing: false,
      recording: false,
      past: [],
      future: [],
      revision: 0,
      session: get().session + 1,
      error: null,
    }),
  acknowledge: (target, saved) => {
    const current = get().project;
    if (!current || current.projectId !== saved.projectId) return null;
    const project =
      editableContent(current) === editableContent(target)
        ? shareUnchanged(current, saved)
        : { ...current, revision: saved.revision };
    set({ project: retainValidatedProject(project) });
    return project;
  },
  edit: (recipe) => {
    const state = get();
    if (!state.project) return;
    const draft = structuredClone(state.project);
    recipe(draft);
    draft.revision = state.project.revision;
    if (JSON.stringify(draft) === JSON.stringify(state.project)) return;
    draft.updatedAt = new Date().toISOString();
    const result = editedProjectSchema.safeParse(shareUnchanged(state.project, draft));
    if (!result.success) {
      set({ error: result.error.issues.map((issue) => issue.message).join('; ') });
      return;
    }
    set({
      project: retainValidatedProject(shareUnchanged(state.project, result.data)),
      past: [...state.past.slice(-99), state.project],
      future: [],
      revision: state.revision + 1,
      error: null,
    });
  },
  select: (selectedId) => set({ selectedId }),
  setTool: (tool) => set({ tool }),
  setTime: (currentTime) =>
    set({
      currentTime: Math.max(0, Math.min(currentTime, get().project?.source.durationSec ?? 0)),
    }),
  setPlaying: (playing) => set({ playing }),
  setRecording: (recording) => set({ recording }),
  setError: (error) => set({ error }),
  undo: () => {
    const state = get();
    const previous = state.past.at(-1);
    if (!previous || !state.project) return;
    set({
      project: {
        ...previous,
        revision: state.project.revision,
        updatedAt: new Date().toISOString(),
      },
      past: state.past.slice(0, -1),
      future: [state.project, ...state.future],
      revision: state.revision + 1,
      error: null,
    });
  },
  redo: () => {
    const state = get();
    const next = state.future[0];
    if (!next || !state.project) return;
    set({
      project: { ...next, revision: state.project.revision, updatedAt: new Date().toISOString() },
      past: [...state.past, state.project],
      future: state.future.slice(1),
      revision: state.revision + 1,
      error: null,
    });
  },
}));
