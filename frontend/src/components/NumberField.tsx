import { useEffect, useId, useState } from 'react';

interface NumberFieldProps {
  label: string;
  value: number;
  onCommit: (value: number) => void;
  min: number;
  max: number;
  step?: number;
  help?: string;
}

export function NumberField({
  label,
  value,
  onCommit,
  min,
  max,
  step = 0.1,
  help,
}: NumberFieldProps) {
  const [input, setInput] = useState(String(Number(value.toFixed(4))));
  const [error, setError] = useState('');
  const id = useId();
  useEffect(() => {
    setInput(String(Number(value.toFixed(4))));
    setError('');
  }, [value]);
  const commit = () => {
    if (input === String(Number(value.toFixed(4)))) {
      setError('');
      return;
    }
    const parsed = Number(input);
    if (!input.trim() || !Number.isFinite(parsed) || parsed < min || parsed > max) {
      setError(`Enter a value from ${Number(min.toFixed(3))} to ${Number(max.toFixed(3))}.`);
      return;
    }
    setError('');
    if (parsed !== value) onCommit(parsed);
  };
  return (
    <label className="inspector-field" htmlFor={id}>
      <span>{label}</span>
      <input
        id={id}
        aria-label={label}
        type="number"
        inputMode="decimal"
        min={min}
        max={max}
        step={step}
        value={input}
        aria-invalid={!!error}
        aria-describedby={error || help ? `${id}-help` : undefined}
        onChange={(event) => setInput(event.target.value)}
        onBlur={commit}
        onKeyDown={(event) => {
          if (event.key === 'Enter') {
            event.preventDefault();
            event.currentTarget.blur();
          }
          if (event.key === 'Escape') {
            setInput(String(value));
            setError('');
            event.stopPropagation();
          }
        }}
      />
      {error ? (
        <span id={`${id}-help`} role="alert" className="field-error">
          {error}
        </span>
      ) : (
        help && <small id={`${id}-help`}>{help}</small>
      )}
    </label>
  );
}
