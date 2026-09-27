import { useEffect, useRef, useState } from 'react';
import { isNativeIOS, nativeBridge } from '../native';

export function SupportDialog({ text, onClose }: { text: string; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    dialog.current?.showModal();
  }, []);
  async function share() {
    try {
      if (isNativeIOS()) await nativeBridge.shareDiagnostics({ text });
      else {
        const url = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
        const link = document.createElement('a');
        link.href = url;
        link.download = 'bjj-support.json';
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
      }
    } catch {
      setError('The support summary could not be shared. You can still select and copy it.');
    }
  }
  return (
    <dialog
      ref={dialog}
      className="support-dialog"
      aria-labelledby="support-title"
      onClose={onClose}
    >
      <h2 id="support-title">Inspect support summary</h2>
      <p>
        Only app/build information and recent error codes are included. Review the complete contents
        below before sharing.
      </p>
      <pre tabIndex={0}>{text}</pre>
      {error && <p role="alert">{error}</p>}
      <button onClick={() => void share()}>
        {isNativeIOS() ? 'Share summary' : 'Download summary'}
      </button>
      <button autoFocus onClick={() => dialog.current?.close()}>
        Close
      </button>
    </dialog>
  );
}
