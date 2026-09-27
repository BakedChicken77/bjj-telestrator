import { useEffect, useState } from 'react';

type Theme = 'system' | 'dark' | 'light';
function read(key: string) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}
function write(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* Current-session preference still works. */
  }
}
export function useAppearance() {
  const [theme, setTheme] = useState<Theme>(() => {
    const saved = read('bjj:theme');
    return saved === 'light' || saved === 'dark' ? saved : 'system';
  });
  const [large, setLarge] = useState(() => read('bjj:largeText') === 'true');
  useEffect(() => {
    const system = matchMedia('(prefers-color-scheme: dark)');
    const update = () => {
      document.documentElement.dataset.theme =
        theme === 'system' ? (system.matches ? 'dark' : 'light') : theme;
    };
    update();
    write('bjj:theme', theme);
    system.addEventListener('change', update);
    return () => system.removeEventListener('change', update);
  }, [theme]);
  useEffect(() => {
    document.documentElement.dataset.largeText = String(large);
    write('bjj:largeText', String(large));
  }, [large]);
  return { theme, setTheme, large, setLarge };
}
export function Appearance({ preferences }: { preferences: ReturnType<typeof useAppearance> }) {
  const { theme, setTheme, large, setLarge } = preferences;
  return (
    <details className="appearance-preferences">
      <summary>Appearance and keyboard help</summary>
      <label>
        Theme{' '}
        <select
          aria-label="Theme"
          value={theme}
          onChange={(event) => setTheme(event.target.value as Theme)}
        >
          <option value="system">Use device theme</option>
          <option value="light">Light</option>
          <option value="dark">Dark</option>
        </select>
      </label>
      <label className="check-label">
        <input
          type="checkbox"
          checked={large}
          onChange={(event) => setLarge(event.target.checked)}
        />{' '}
        Larger editor text
      </label>
      <p>
        Outside text fields: Space plays or pauses; arrows seek; Shift seeks farther; Ctrl/⌘ Z
        undoes; Ctrl Y or ⌘ Shift Z redoes. Escape clears selection or closes a dialog. Focused
        buttons use their usual Space/Enter behavior.
      </p>
      <p>
        These device preferences do not change your project or exported video. Reduced motion
        follows the device setting.
      </p>
    </details>
  );
}
