// Turns the reviewer's structured output into what gets posted: which
// findings become inline comments, which only make the summary, and the text
// of both. Everything here is pure; publish.ts does the I/O.

import { createHash } from "node:crypto";
import { hunkFor, type Hunk } from "./diff.ts";

export type Severity = "critical" | "high" | "medium" | "low";
export type Role = "core" | "support" | "drift" | "critical";

export type Finding = {
  path: string;
  startLine: number;
  endLine: number;
  severity: Severity;
  score: number;
  category: string;
  title: string;
  body: string;
  evidence: string;
  existingCode?: string;
  improvedCode?: string;
};

export type ReviewOutput = {
  summary: {
    tldr: string;
    verdict: "looks_good" | "minor_issues" | "needs_changes";
    files: { path: string; role: Role; note?: string }[];
    notReviewed: string[];
  };
  findings: Finding[];
};

/** Findings under this score are dropped: the verifier was not convinced. */
export const MIN_SCORE = 5;
/**
 * A low-severity finding needs this score instead: a minor defect is worth a
 * comment only when it is certain. On the bench this is what kept style and
 * by-design traps off otherwise clean PRs.
 */
export const MIN_SCORE_LOW = 7;
/** The score a finding needs to be posted. */
export const minScoreFor = (f: Pick<Finding, "severity">) => (f.severity === "low" ? MIN_SCORE_LOW : MIN_SCORE);
/** More inline comments than this is noise; the rest go to the summary. */
export const MAX_INLINE = 5;
/** A committable suggestion longer than this is rarely applied as-is. */
export const MAX_SUGGESTION_LINES = 15;

export const SUMMARY_MARKER = "<!-- ai-review:summary -->";
const FP_PREFIX = "ai-review:fp=";

const SEVERITY_RANK: Record<Severity, number> = { critical: 0, high: 1, medium: 2, low: 3 };

/** Stable id of a finding across runs: same file, same defect name. Line
 * numbers are left out on purpose, a push above the finding moves them. */
export function fingerprint(f: Pick<Finding, "path" | "title">): string {
  const title = f.title.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  return createHash("sha1").update(`${f.path}\n${title}`).digest("hex").slice(0, 12);
}

/** Fingerprints embedded in earlier comments of this reviewer. */
export function fingerprintsIn(bodies: string[]): Set<string> {
  const found = new Set<string>();
  const re = new RegExp(`${FP_PREFIX}([0-9a-f]{12})`, "g");
  for (const body of bodies) for (const m of body.matchAll(re)) found.add(m[1]!);
  return found;
}

export type Placed = Finding & { fp: string; suggestion: "committable" | "code" | "none" };

export type Plan = {
  inline: Placed[];
  /** Real findings that could not be anchored or did not fit the inline cap. */
  summaryOnly: (Placed & { why: "unanchored" | "overflow" })[];
  /** Already raised by an earlier run on this PR, skipped. */
  repeated: Placed[];
  droppedLowScore: number;
};

export type PlanInput = {
  findings: Finding[];
  /** RIGHT-side hunks per changed file. Files absent here are not in the diff. */
  hunks: Map<string, Hunk[]>;
  /** Fingerprints already posted on this PR. */
  seen: Set<string>;
  /** Reads a file at HEAD, undefined when it does not exist. */
  readHead: (path: string) => string | undefined;
};

export function plan({ findings, hunks, seen, readHead }: PlanInput): Plan {
  const kept = findings.filter((f) => f.score >= minScoreFor(f));
  const sorted = [...kept].sort(
    (a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity] || b.score - a.score,
  );
  const result: Plan = { inline: [], summaryOnly: [], repeated: [], droppedLowScore: findings.length - kept.length };
  const fpsThisRun = new Set<string>();

  for (const f of sorted) {
    const fp = fingerprint(f);
    if (fpsThisRun.has(fp)) continue;
    fpsThisRun.add(fp);
    const start = Math.min(f.startLine, f.endLine);
    const end = Math.max(f.startLine, f.endLine);
    const hunk = hunkFor(hunks.get(f.path) ?? [], start, end);
    const placed: Placed = { ...f, startLine: start, endLine: end, fp, suggestion: suggestionKind(f, start, end, !!hunk, readHead) };
    if (seen.has(fp)) result.repeated.push(placed);
    else if (!hunk) result.summaryOnly.push({ ...placed, suggestion: placed.suggestion === "committable" ? "code" : placed.suggestion, why: "unanchored" });
    else if (result.inline.length >= MAX_INLINE) result.summaryOnly.push({ ...placed, why: "overflow" });
    else result.inline.push(placed);
  }
  return result;
}

function suggestionKind(
  f: Finding,
  start: number,
  end: number,
  inHunk: boolean,
  readHead: (path: string) => string | undefined,
): Placed["suggestion"] {
  const improved = f.improvedCode?.replace(/\n+$/, "");
  if (!improved?.trim()) return "none";
  if (f.existingCode !== undefined && normalize(f.existingCode) === normalize(improved)) return "none";
  // Either side over the cap makes a suggestion nobody applies as-is.
  const size = Math.max(end - start + 1, improved.split("\n").length);
  if (!inHunk || f.existingCode === undefined || size > MAX_SUGGESTION_LINES) return "code";
  const head = readHead(f.path);
  if (head === undefined) return "code";
  const actual = head.split("\n").slice(start - 1, end).join("\n");
  return normalize(actual) === normalize(f.existingCode) ? "committable" : "code";
}

/** Trailing whitespace and a final newline never decide whether code matches. */
function normalize(code: string): string {
  return code.replace(/\n+$/, "").split("\n").map((l) => l.trimEnd()).join("\n");
}

const SEVERITY_BADGE: Record<Severity, string> = {
  critical: "🔴 critical",
  high: "🟠 high",
  medium: "🟡 medium",
  low: "⚪ low",
};

export function renderInline(f: Placed): string {
  const parts = [`**${f.title}** · ${SEVERITY_BADGE[f.severity]} · ${f.category}`, "", f.body.trim()];
  const fix = renderFix(f);
  if (fix) parts.push("", fix);
  parts.push("", `<details><summary>Evidence</summary>\n\n${f.evidence.trim()}\n\n</details>`);
  parts.push("", `<!-- ${FP_PREFIX}${f.fp} -->`);
  return parts.join("\n");
}

function renderFix(f: Placed): string | undefined {
  const code = f.improvedCode?.replace(/\n+$/, "");
  if (f.suggestion === "committable") return "```suggestion\n" + code + "\n```";
  if (f.suggestion === "code") return "Possible fix:\n\n```\n" + code + "\n```";
  return undefined;
}

const VERDICT: Record<ReviewOutput["summary"]["verdict"], string> = {
  looks_good: "✅ Looks good",
  minor_issues: "🟡 Minor issues",
  needs_changes: "🔴 Needs changes",
};

export type SummaryInput = {
  review: ReviewOutput;
  plan: Plan;
  headSha: string;
  runUrl: string;
  /** Files of this PR as GitHub knows them, for links. */
  fileUrl: (path: string, line: number) => string;
};

export function renderSummary({ review, plan: p, headSha, runUrl, fileUrl }: SummaryInput): string {
  const { summary } = review;
  const out: string[] = [SUMMARY_MARKER, `## AI review · ${VERDICT[summary.verdict]}`, "", summary.tldr.trim(), ""];

  const listed = [...p.inline.map((f) => ({ ...f, where: "inline" })), ...p.summaryOnly.map((f) => ({ ...f, where: f.why }))];
  if (listed.length > 0) {
    out.push("| | Finding | Where |", "|---|---|---|");
    for (const f of listed) {
      const loc = `[${f.path}:${f.startLine}](${fileUrl(f.path, f.startLine)})`;
      const note = f.where === "inline" ? "inline comment" : f.where === "overflow" ? "below (over the inline limit)" : "below (outside the diff)";
      out.push(`| ${SEVERITY_BADGE[f.severity]} | **${escapeCell(f.title)}** · ${loc} | ${note} |`);
    }
    out.push("");
  } else {
    out.push("No findings worth your time.", "");
  }

  for (const f of p.summaryOnly) {
    out.push(`### ${f.title}`, `\`${f.path}:${f.startLine}\` · ${SEVERITY_BADGE[f.severity]} · ${f.category}`, "", f.body.trim(), "");
    const fix = renderFix(f);
    if (fix) out.push(fix, "");
    out.push(`<details><summary>Evidence</summary>\n\n${f.evidence.trim()}\n\n</details>`, "", `<!-- ${FP_PREFIX}${f.fp} -->`, "");
  }

  if (p.repeated.length > 0) {
    out.push(`Still standing from an earlier run, not re-posted: ${p.repeated.map((f) => `**${f.title}** (\`${f.path}\`)`).join(", ")}.`, "");
  }

  const drift = summary.files.filter((f) => f.role === "drift" || f.role === "critical");
  if (drift.length > 0) {
    out.push("<details><summary>Files outside the core change</summary>", "");
    for (const f of drift) out.push(`- \`${f.path}\` · ${f.role}${f.note ? ` · ${f.note}` : ""}`);
    out.push("", "</details>", "");
  }

  const coverage: string[] = [];
  if (summary.notReviewed.length > 0) coverage.push(`Not reviewed: ${summary.notReviewed.join("; ")}.`);
  if (p.droppedLowScore > 0) coverage.push(`${p.droppedLowScore} lower-confidence finding(s) dropped.`);
  if (coverage.length > 0) out.push(`_${coverage.join(" ")}_`, "");

  out.push(`<sub>Reviewed ${headSha.slice(0, 7)} · [run](${runUrl})</sub>`);
  return out.join("\n");
}

export function renderFailure(headSha: string, runUrl: string, reason: string): string {
  return [
    SUMMARY_MARKER,
    "## AI review · ⚠️ did not complete",
    "",
    `${reason} Nothing was posted for this commit; the [run log](${runUrl}) has the details.`,
    "",
    `<sub>Head ${headSha.slice(0, 7)}</sub>`,
  ].join("\n");
}

function escapeCell(s: string): string {
  return s.replace(/\|/g, "\\|").replace(/\n/g, " ");
}

/** Accepts the action's structured_output, rejecting anything the rest of
 * this module would trip over. */
export function parseReview(raw: string): ReviewOutput {
  const data = JSON.parse(raw) as ReviewOutput;
  if (!data?.summary || !Array.isArray(data.findings)) throw new Error("structured output has no summary or findings");
  data.summary.files ??= [];
  data.summary.notReviewed ??= [];
  data.summary.tldr ??= "";
  if (!(data.summary.verdict in VERDICT)) data.summary.verdict = "minor_issues";
  data.findings = data.findings.filter(
    (f) =>
      typeof f?.path === "string" &&
      Number.isInteger(f.startLine) &&
      Number.isInteger(f.endLine) &&
      f.startLine > 0 &&
      f.endLine > 0 &&
      f.severity in SEVERITY_RANK &&
      typeof f.title === "string" &&
      typeof f.body === "string",
  );
  for (const f of data.findings) f.evidence ??= "";
  return data;
}
