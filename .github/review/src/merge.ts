// Merges the findings of several independent review samples of one PR.
//
// Samples of the same prompt miss different bugs (a model reads a diff a
// little differently each time), so their union finds more than any one of
// them. The same defect found twice is kept once, with the higher score, and
// a defect several samples agree on gains confidence.

import type { Finding, ReviewOutput } from "./review.ts";

/** Two findings are the same defect when they sit in the same file within
 * this many lines of each other and share enough of their title words. */
const NEAR_LINES = 3;

function words(title: string): Set<string> {
  return new Set(
    title
      .toLowerCase()
      .replace(/[^a-z0-9_]+/g, " ")
      .split(" ")
      .filter((w) => w.length > 2),
  );
}

export function sameDefect(a: Finding, b: Finding): boolean {
  if (a.path !== b.path) return false;
  const near = a.startLine <= b.endLine + NEAR_LINES && b.startLine <= a.endLine + NEAR_LINES;
  if (!near) return false;
  const wa = words(a.title);
  const wb = words(b.title);
  const shared = [...wa].filter((w) => wb.has(w)).length;
  return shared / Math.max(1, Math.min(wa.size, wb.size)) >= 0.3;
}

export function mergeSamples(samples: ReviewOutput[]): ReviewOutput & { agreement: number[] } {
  if (samples.length === 0) throw new Error("no samples");
  // `by`: the samples that found it. Two findings of one sample that match
  // each other are not agreement.
  const merged: { f: Finding; by: Set<number> }[] = [];
  samples.forEach((sample, i) => {
    for (const f of sample.findings) {
      const hit = merged.find((m) => sameDefect(m.f, f));
      if (!hit) merged.push({ f, by: new Set([i]) });
      else {
        hit.by.add(i);
        if (f.score > hit.f.score) hit.f = f;
      }
    }
  });
  // Found by more than one sample: one point more confident, capped at 10.
  const findings = merged.map(({ f, by }) => ({ ...f, score: Math.min(10, f.score + (by.size > 1 ? 1 : 0)) }));
  const first = samples.find((s) => s.findings.length === Math.max(...samples.map((x) => x.findings.length))) ?? samples[0]!;
  const rank = { looks_good: 0, minor_issues: 1, needs_changes: 2 } as const;
  const verdict = samples.map((s) => s.summary.verdict).sort((a, b) => rank[b] - rank[a])[0]!;
  return {
    summary: { ...first.summary, verdict },
    findings,
    agreement: merged.map((m) => m.by.size),
  };
}
