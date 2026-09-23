// Which lines of a pull request GitHub will accept a review comment on.
//
// A review comment on the RIGHT side must sit on a line the diff shows: an
// added line or a context line, inside one hunk. A multi-line comment must
// also start and end in the same hunk. Anything else is a 422 for the whole
// review, which is why placement is decided here before anything is posted.

export type Hunk = { lines: Set<number> };

const HUNK_HEADER = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/;

/** Parses a unified-diff `patch` (as the pulls/files API returns it) into
 * the RIGHT-side lines each hunk shows. */
export function parsePatch(patch: string): Hunk[] {
  const hunks: Hunk[] = [];
  let current: Hunk | undefined;
  let line = 0;
  for (const raw of patch.split("\n")) {
    const header = HUNK_HEADER.exec(raw);
    if (header) {
      line = Number(header[1]);
      current = { lines: new Set() };
      hunks.push(current);
      continue;
    }
    if (!current) continue;
    if (raw.startsWith("-") || raw.startsWith("\\")) continue;
    // "+" added, " " context. An empty string is the tail of the split.
    if (raw.startsWith("+") || raw.startsWith(" ")) {
      current.lines.add(line);
      line += 1;
    }
  }
  return hunks.filter((h) => h.lines.size > 0);
}

/** The hunk that contains both lines, if one does. */
export function hunkFor(hunks: Hunk[], startLine: number, endLine: number): Hunk | undefined {
  return hunks.find((h) => h.lines.has(startLine) && h.lines.has(endLine));
}
