/** Reuse equal, already-owned JSON subtrees after validation. History remains
 * ordinary project snapshots; recipes still receive a private mutable clone. */
export function shareUnchanged<T>(previous: T, next: T): T {
  if (Object.is(previous, next)) return previous;
  if (!previous || !next || typeof previous !== 'object' || typeof next !== 'object') return next;
  if (Array.isArray(previous) !== Array.isArray(next)) return next;
  const before = previous as Record<string, unknown>,
    after = next as Record<string, unknown>;
  const keys = Object.keys(after);
  let equal = keys.length === Object.keys(before).length;
  for (const key of keys) {
    if (!Object.hasOwn(before, key)) {
      equal = false;
      continue;
    }
    after[key] = shareUnchanged(before[key], after[key]);
    if (!Object.is(after[key], before[key])) equal = false;
  }
  return equal ? previous : next;
}
