// Runs one review: builds the prompt from the checkout, runs Claude Code
// headless on it, and writes what came back. The same script runs in CI
// (.github/workflows/review.yml) and on a laptop, so a prompt or setting can
// be tried locally on any branch before CI ever sees it.
//
//   bun .github/review/src/run.ts --base origin/main --out /tmp/review \
//     [--title "..." --body "..." --number 42] [--model claude-opus-5-5] [--effort high] \
//     [--lenses .github/review/lenses/security.md] \
//     [--verify .github/review/verify.md --verify-effort low]
//
// Run it from the root of a checkout whose HEAD is the PR head. It writes
// <out>/review.json (the findings, or nothing when the run failed),
// <out>/messages.json (every message of the session) and <out>/metrics.md.
//
// A lens is a second pass run in parallel with the first, the same prompt
// plus the lens file's text. The security lens is what brought the local
// bench (bench/) level with Greptile on this repo's old PRs; running the same
// prompt three times instead only made the review slower.
//
// The verification stage (--verify) runs after the passes: one call that
// checks every merged finding against the code. On the bench it cut the
// false alarms on clean PRs from 4 in 8 to 1 in 8, and kept every serious
// bug, for 7-16 s more.
// It exits 0 even when the review failed: publish.ts says so on the PR.

import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { collectContext, restoreBaseRules } from "./context.ts";
import { mergeSamples } from "./merge.ts";
import { VERIFY_SCHEMA, applyVerdicts, type Verdict } from "./verify.ts";
import { metricsOf, renderMetrics } from "./metrics.ts";
import type { ReviewOutput } from "./review.ts";

const here = dirname(new URL(import.meta.url).pathname);

export const DEFAULT_MODEL = "claude-opus-5-5";

/**
 * Tools the reviewer may use: reading only, and no shell at all. The diff is
 * already in the prompt. A shell allow-list does not hold: `Bash(git grep:*)`
 * also allows `git grep -O<cmd>`, which runs any program, and `git diff
 * --output=<file>` writes one (both tried), and the reviewer runs with
 * CLAUDE_CODE_OAUTH_TOKEN in its environment, reading PR text an attacker
 * may have written. Headless Claude Code refuses everything not allowed here.
 */
export const ALLOWED_TOOLS = ["Read", "Grep", "Glob"];
const DISALLOWED_TOOLS = ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch", "Agent", "Task"];

const { values: args } = parseArgs({
  options: {
    base: { type: "string" },
    out: { type: "string" },
    title: { type: "string", default: "" },
    body: { type: "string", default: "" },
    number: { type: "string", default: "0" },
    repo: { type: "string", default: process.env.GITHUB_REPOSITORY ?? "local" },
    model: { type: "string", default: DEFAULT_MODEL },
    effort: { type: "string", default: "" },
    prompt: { type: "string", default: join(here, "..", "prompt.md") },
    "restore-rules": { type: "boolean", default: false },
    "max-turns": { type: "string", default: "30" },
    samples: { type: "string", default: "1" },
    // Extra passes, one per file: each runs in parallel with the main one,
    // with the file's text appended to the instructions.
    lenses: { type: "string", default: "" },
    // A second stage: one call that tries to refute every merged finding,
    // with this prompt file. Off when empty.
    verify: { type: "string", default: "" },
    "verify-model": { type: "string", default: "" },
    "verify-effort": { type: "string", default: "" },
  },
});
if (!args.base || !args.out) throw new Error("--base and --out are required");
const out = args.out;
mkdirSync(out, { recursive: true });

// The PR may rewrite CLAUDE.md or .claude/; Claude Code would load those from
// the working tree. With --restore-rules (CI) the base versions go back for
// the run, and HEAD's come back after it, for publish.ts to check
// suggestions against. It is opt-in because it would discard uncommitted
// edits to those files in a checkout someone works in.
const restored = args["restore-rules"] ? restoreBaseRules(args.base) : [];
if (restored.length) console.log(`base versions for the run: ${restored.join(", ")}`);

const spillPath = ".review-context/diff.patch";
const baseRef = args.base;
const instructions = readFileSync(args.prompt, "utf8");
const lenses = args.lenses ? args.lenses.split(",").map((p) => readFileSync(p, "utf8")) : [];
// A lens that starts with the standalone marker is a whole prompt of its own;
// any other lens is appended to the main instructions.
const STANDALONE = "<!-- standalone -->";
const lensPrompt = (l: string) => (l.startsWith(STANDALONE) ? l.slice(STANDALONE.length).trimStart() : `${instructions.trimEnd()}\n${l}`);
const plain = lenses.length > 0 ? Math.max(0, Number(args.samples)) : Math.max(1, Number(args.samples));
const passes = [...Array.from({ length: plain }, () => instructions), ...lenses.map(lensPrompt)];
const samples = passes.length;
const meta = { repo: args.repo, number: Number(args.number), title: args.title, body: args.body, base: baseRef };
// Sample i reads the files in a different order (see rotateFiles).
const contexts = passes.map((text, i) => collectContext(meta, baseRef, text, spillPath, i));
const context = contexts[0]!;
if (context.spill !== undefined) {
  mkdirSync(dirname(spillPath), { recursive: true });
  writeFileSync(spillPath, context.spill);
}
writeFileSync(join(out, "prompt.md"), context.prompt);
console.log(
  `prompt: ${Buffer.byteLength(context.prompt)} bytes, ${context.changed.length} files, rules: ${context.rules.join(", ") || "none"}${context.spill === undefined ? "" : `, diff in ${spillPath}`}, ${samples} sample(s)`,
);

const schema = JSON.stringify(JSON.parse(readFileSync(join(here, "..", "findings.schema.json"), "utf8")));

type Message = { type: string; structured_output?: unknown; subtype?: string };
type Run = { messages: Message[]; output?: unknown; seconds: number; code: number };

/** One headless Claude Code call: the prompt on stdin, JSON out per the schema. */
async function claude(prompt: string, schema: string, model: string, effort: string): Promise<Run> {
  const cmd = [
    process.env.CLAUDE_BIN || "claude",
    "-p",
    "--model", model,
    ...(effort ? ["--effort", effort] : []),
    "--output-format", "stream-json",
    "--verbose",
    "--json-schema", schema,
    "--max-turns", args["max-turns"]!,
    "--allowedTools", ALLOWED_TOOLS.join(","),
    "--disallowedTools", DISALLOWED_TOOLS.join(","),
    // No project settings, hooks or MCP servers from the reviewed tree.
    "--setting-sources", "user",
    "--strict-mcp-config",
    "--no-session-persistence",
  ];
  const started = performance.now();
  const proc = Bun.spawn(cmd, { stdin: new Blob([prompt]), stdout: "pipe", stderr: "inherit" });
  const text = await new Response(proc.stdout).text();
  const code = await proc.exited;
  const messages = text
    .split("\n")
    .filter((l) => l.trim().startsWith("{"))
    .flatMap((l) => {
      try {
        return [JSON.parse(l) as Message];
      } catch {
        return [];
      }
    });
  const result = [...messages].reverse().find((m) => m.type === "result");
  if (!result?.structured_output) console.error(`no structured output (exit ${code}, ${result?.subtype ?? "no result"})`);
  return { messages, output: result?.structured_output, seconds: Math.round((performance.now() - started) / 1000), code };
}

const asReview = (o: unknown): ReviewOutput | undefined =>
  o && typeof o === "object" && Array.isArray((o as ReviewOutput).findings) ? (o as ReviewOutput) : undefined;

const started = performance.now();
const results = await Promise.all(contexts.map((c) => claude(c.prompt, schema, args.model!, args.effort!)));
writeFileSync(join(out, "messages.json"), JSON.stringify(results[0]!.messages));
results.forEach((r, i) => i > 0 && writeFileSync(join(out, `messages-${i + 1}.json`), JSON.stringify(r.messages)));

const reviews = results.flatMap((r) => {
  const review = asReview(r.output);
  return review ? [review] : [];
});
let merged: (ReviewOutput & { verification?: unknown }) | undefined;
if (reviews.length > 0) {
  merged = samples > 1 ? mergeSamples(reviews) : reviews[0]!;
  // A pass that returned nothing must not pass for a clean one.
  const failed = results.flatMap((r, i) => (asReview(r.output) ? [] : [i === 0 ? "the general pass" : `pass ${i + 1}`]));
  if (failed.length) merged.summary.notReviewed = [...merged.summary.notReviewed, `${failed.join(", ")} returned nothing (turn limit or error), so this review is partial`];
}

let verifyRun: Run | undefined;
if (merged && args.verify && merged.findings.length > 0) {
  const verifyText = readFileSync(args.verify, "utf8");
  const candidates = merged.findings.map((f, i) => ({ index: i, path: f.path, startLine: f.startLine, endLine: f.endLine, severity: f.severity, score: f.score, title: f.title, body: f.body, evidence: f.evidence }));
  const prompt = `${collectContext(meta, baseRef, verifyText, spillPath, 0).prompt}\n# Candidate findings\n\n\`\`\`json\n${JSON.stringify(candidates, null, 2)}\n\`\`\`\n`;
  verifyRun = await claude(prompt, VERIFY_SCHEMA, args["verify-model"] || args.model!, args["verify-effort"]!);
  writeFileSync(join(out, "messages-verify.json"), JSON.stringify(verifyRun.messages));
  const verified = verifyRun.output as { verdicts?: Verdict[]; tldr?: string } | undefined;
  if (verified?.verdicts) merged = applyVerdicts(merged, verified.verdicts, verified.tldr);
  else merged.summary.notReviewed = [...merged.summary.notReviewed, "the verification step returned nothing, so findings are unverified"];
}

if (restored.length) Bun.spawnSync(["git", "checkout", "HEAD", "--", ...restored]);
if (merged) writeFileSync(join(out, "review.json"), JSON.stringify(merged));

const seconds = Math.round((performance.now() - started) / 1000);
const metrics = [
  ...results.map((r, i) => `${samples > 1 ? `#### Pass ${i + 1}\n\n` : ""}${renderMetrics(metricsOf(r.messages as never))}\nProcess: ${r.seconds}s, exit ${r.code}.\n`),
  ...(verifyRun ? [`#### Verification\n\n${renderMetrics(metricsOf(verifyRun.messages as never))}\nProcess: ${verifyRun.seconds}s, exit ${verifyRun.code}.\n`] : []),
  `Total: ${seconds}s.\n`,
].join("\n");
writeFileSync(join(out, "metrics.md"), metrics);
console.log(metrics);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, metrics);
