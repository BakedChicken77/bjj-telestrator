import { useEffect, useRef, type ReactNode } from 'react';

export function Modal({
  className,
  labelledBy,
  returnFocusSelector,
  canClose = true,
  onClose,
  children,
}: {
  className: string;
  labelledBy: string;
  returnFocusSelector?: string;
  canClose?: boolean;
  onClose: () => void;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const dialog = ref.current!;
    dialog.showModal();
    dialog.focus();
    return () => {
      dialog.close();
      const target = returnFocusSelector
        ? document.querySelector<HTMLElement>(returnFocusSelector)
        : previous;
      if (target?.isConnected) target.focus();
    };
  }, [returnFocusSelector]);
  return (
    <dialog
      ref={ref}
      className={`modal ${className}`}
      aria-labelledby={labelledBy}
      tabIndex={-1}
      onCancel={(event) => {
        event.preventDefault();
        if (canClose) onClose();
      }}
    >
      {children}
    </dialog>
  );
}
