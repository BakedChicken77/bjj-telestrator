import { create } from 'zustand';
import { projectSchema, type Project, type Tool } from './model';

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
  error: string | null;
  setProject: (project: Project | null) => void;
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
  error: null,
  setProject: (project) =>
    set({
      project: project ? projectSchema.parse(project) : null,
      selectedId: null,
      tool: 'select',
      currentTime: 0,
      playing: false,
      recording: false,
      past: [],
      future: [],
      revision: 0,
      error: null,
    }),
  edit: (recipe) => {
    const state = get();
    if (!state.project) return;
    const draft = structuredClone(state.project);
    recipe(draft);
    if (JSON.stringify(draft) === JSON.stringify(state.project)) return;
    draft.updatedAt = new Date().toISOString();
    const result = projectSchema.safeParse(draft);
    if (!result.success) {
      set({ error: result.error.issues.map((issue) => issue.message).join('; ') });
      return;
    }
    set({
      project: result.data,
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
      project: { ...previous, updatedAt: new Date().toISOString() },
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
      project: { ...next, updatedAt: new Date().toISOString() },
      past: [...state.past, state.project],
      future: state.future.slice(1),
      revision: state.revision + 1,
      error: null,
    });
  },
}));
