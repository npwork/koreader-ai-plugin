// The verification stage: one call that reads the merged findings of the
// review passes and tries to refute each one, so what gets posted is what
// survived a second, sceptical reading. run.ts runs it with --verify.

import { MIN_SCORE, minScoreFor, type ReviewOutput } from "./review.ts";

export type Verdict = { index: number; keep: boolean; nit: boolean; score: number; severity: "critical" | "high" | "medium" | "low"; reason: string };

export const VERIFY_SCHEMA = JSON.stringify({
  type: "object",
  additionalProperties: false,
  required: ["verdicts", "tldr"],
  properties: {
    tldr: { type: "string" },
    verdicts: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["index", "keep", "nit", "score", "severity", "reason"],
        properties: {
          index: { type: "integer", minimum: 0 },
          keep: { type: "boolean" },
          nit: { type: "boolean" },
          score: { type: "integer", minimum: 0, maximum: 10 },
          severity: { type: "string", enum: ["critical", "high", "medium", "low"] },
          reason: { type: "string" },
        },
      },
    },
  },
});

/**
 * Drops what the verifier refuted or called a nit, and takes its score and
 * severity for the rest. A finding the verifier did not mention stays as it
 * was.
 *
 * A kept finding the finder had posted does not sink under MIN_SCORE: the
 * verifier removes a finding by refuting it, not by doubting it. On the bench
 * it once kept a real deploy-breaking bug at score 4 because it could not
 * check the external API the bug was about.
 */
export function applyVerdicts<T extends ReviewOutput>(review: T, verdicts: Verdict[], tldr?: string): T & { verification: (Verdict & { title: string })[] } {
  const byIndex = new Map(verdicts.map((v) => [v.index, v]));
  const findings = review.findings.flatMap((f, i) => {
    const v = byIndex.get(i);
    if (!v) return [f];
    if (!v.keep || v.nit) return [];
    return [{ ...f, score: Math.max(v.score, Math.min(f.score, MIN_SCORE)), severity: v.severity }];
  });
  // The finders' summary may name findings that were just dropped: take the
  // verifier's, and judge the verdict by what will be posted.
  const posted = findings.filter((f) => f.score >= minScoreFor(f));
  const verdict = posted.length === 0 ? "looks_good" : posted.some((f) => f.severity === "critical" || f.severity === "high") ? "needs_changes" : "minor_issues";
  return {
    ...review,
    summary: { ...review.summary, verdict, tldr: tldr?.trim() ? tldr : review.summary.tldr },
    findings,
    verification: verdicts.map((v) => ({ ...v, title: review.findings[v.index]?.title ?? "?" })),
  };
}
