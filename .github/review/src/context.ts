// Builds the reviewer's prompt with the pull request already in it.
//
// Each turn of the reviewer is a model round trip, and the first several used
// to go on fetching what this script can hand over for free: the PR text, the
// commits, the diff, the CLAUDE.md rules. With them in the prompt the model
// starts on the review itself and spends its tools only on what the diff does
// not show (callers, the rest of a file, a grep).
//
// run.ts calls collectContext; everything above it is pure and tested.

/** Files whose diff is noise to a reviewer; named in the prompt, not shown. */
const GENERATED = [/(^|\/)bun\.lockb?$/, /(^|\/)package-lock\.json$/, /(^|\/)yarn\.lock$/, /(^|\/)pnpm-lock\.yaml$/, /\.snap$/];

/**
 * A diff past this many bytes goes to a file the prompt points at, so the
 * model reads it in slices instead of paying for all of it up front.
 */
export const INLINE_LIMIT = 300_000;

export type Meta = { repo: string; number: number; title: string; body: string; base: string; head: string };

export type ContextInput = {
  meta: Meta;
  instructions: string;
  commits: string;
  stat: string;
  diff: string;
  /** CLAUDE.md files from the base branch, by path. */
  rules: { path: string; text: string }[];
  /** Changed files left out of the diff as generated. */
  skipped: string[];
};

export type Context = { prompt: string; spill?: string };

export const isGenerated = (path: string) => GENERATED.some((re) => re.test(path));

/** Every directory from the root down to each changed file, in order. */
export function ruleDirs(paths: string[]): string[] {
  const dirs = new Set<string>([""]);
  for (const path of paths) {
    const parts = path.split("/").slice(0, -1);
    for (let i = 1; i <= parts.length; i++) dirs.add(parts.slice(0, i).join("/"));
  }
  return [...dirs].sort((a, b) => a.split("/").length - b.split("/").length || a.localeCompare(b));
}

export function buildContext(input: ContextInput, spillPath: string, limit = INLINE_LIMIT): Context {
  const { meta } = input;
  const head = [
    `Repository: ${meta.repo}`,
    `Pull request: #${meta.number}`,
    `Base: ${meta.base}`,
    `HEAD: ${meta.head} (checked out)`,
    "",
    input.instructions.trim(),
    "",
  ];
  const rules = input.rules.length
    ? input.rules.map((r) => `### ${r.path || "CLAUDE.md"}\n\n${r.text.trim()}\n`)
    : ["(none)"];
  const before = [
    "# The pull request",
    "",
    `## Title\n\n${meta.title.trim()}`,
    "",
    `## Description (the author's claims)\n\n${meta.body.trim() || "(empty)"}`,
    "",
    `## Commits\n\n${input.commits.trim()}`,
    "",
    "## Rules: CLAUDE.md files on the path of the changed files, from the base branch",
    "",
    ...rules,
    "",
    `## Changed files\n\n\`\`\`\n${input.stat.trimEnd()}\n\`\`\``,
    ...(input.skipped.length ? ["", `Generated, not shown and not to be reviewed: ${input.skipped.join(", ")}.`] : []),
    "",
  ];
  const diff = numberDiff(input.diff).trimEnd();
  const fence = "`".repeat(Math.max(3, longestRun(diff, "`") + 1));
  const inline = [
    ...head,
    ...before,
    `## Diff (\`git diff -U10 ${meta.base}...HEAD\`, HEAD line numbers on the left)`,
    "",
    fence,
    diff,
    fence,
    "",
  ].join("\n");
  if (Buffer.byteLength(inline) <= limit) return { prompt: inline };
  return {
    prompt: [
      ...head,
      ...before,
      "## Diff",
      "",
      `Too large to include here: it is in \`${spillPath}\` (${diff.split("\n").length} lines, HEAD line numbers on the left). Read it first, in parallel slices of about 1500 lines.`,
      "",
    ].join("\n"),
    spill: diff,
  };
}

/**
 * The diff with each line's HEAD line number in a left column, so the
 * reviewer anchors a finding without counting from the hunk header or
 * opening the file. Removed lines get no number: they are not in HEAD.
 */
export function numberDiff(diff: string): string {
  const header = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/;
  let line = 0;
  let inHunk = false;
  return diff
    .split("\n")
    .map((raw) => {
      const h = header.exec(raw);
      if (h) {
        line = Number(h[1]);
        inHunk = true;
        return raw;
      }
      if (raw.startsWith("diff --git")) inHunk = false;
      if (!inHunk) return raw;
      if (raw.startsWith("+") || raw.startsWith(" ")) return `${String(line++).padStart(5)} ${raw}`;
      if (raw.startsWith("-")) return `${"".padStart(5)} ${raw}`;
      return raw;
    })
    .join("\n");
}

/**
 * The diff with its files in a different order: file `k` first, wrapping
 * around. Independent samples then read the files in different orders, which
 * is where one sample's attention runs out and another's does not.
 */
export function rotateFiles(diff: string, k: number): string {
  const blocks = diff.split(/(?=^diff --git )/m).filter((b) => b.length > 0);
  if (blocks.length < 2 || k % blocks.length === 0) return diff;
  const n = k % blocks.length;
  return [...blocks.slice(n), ...blocks.slice(0, n)].map((b) => (b.endsWith("\n") ? b : `${b}\n`)).join("");
}

function longestRun(text: string, ch: string): number {
  let best = 0;
  let run = 0;
  for (const c of text) {
    run = c === ch ? run + 1 : 0;
    if (run > best) best = run;
  }
  return best;
}

function git(...args: string[]): string {
  const res = Bun.spawnSync(["git", ...args], { stdout: "pipe", stderr: "pipe" });
  if (res.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${res.stderr.toString()}`);
  return res.stdout.toString();
}

function gitMaybe(...args: string[]): string | undefined {
  const res = Bun.spawnSync(["git", ...args], { stdout: "pipe", stderr: "ignore" });
  return res.exitCode === 0 ? res.stdout.toString() : undefined;
}

export type Collected = Context & { changed: string[]; rules: string[] };

/**
 * Reads the PR out of the checkout in the working directory: HEAD is the PR
 * head, `baseRef` (e.g. `origin/main`) the branch it goes into.
 */
export function collectContext(meta: Omit<Meta, "head">, baseRef: string, instructions: string, spillPath: string, rotate = 0): Collected {
  const range = `${baseRef}...HEAD`;
  const changed = git("diff", "--name-only", range).split("\n").filter(Boolean);
  const skipped = changed.filter(isGenerated);
  const pathspec = ["--", ".", ...skipped.map((p) => `:(exclude)${p}`)];
  const rules = ruleDirs(changed).flatMap((dir) => {
    const path = dir ? `${dir}/CLAUDE.md` : "CLAUDE.md";
    const text = gitMaybe("show", `${baseRef}:${path}`);
    return text === undefined ? [] : [{ path, text }];
  });
  const context = buildContext(
    {
      meta: { ...meta, head: git("rev-parse", "HEAD").trim() },
      instructions,
      commits: git("log", "--format=- %h %s", `${baseRef}..HEAD`),
      stat: git("diff", "--stat=120", range),
      diff: rotateFiles(git("diff", "-U10", range, ...pathspec), rotate),
      rules,
      skipped,
    },
    spillPath,
  );
  return { ...context, changed, rules: rules.map((r) => r.path) };
}

/**
 * Puts every CLAUDE.md and `.claude/` back to the base version, so Claude
 * Code's own discovery of them in the working tree cannot load the PR's
 * rewritten rules or settings. The prompt already quotes the base rules.
 */
export function restoreBaseRules(baseRef: string): string[] {
  const touched: string[] = [];
  const atHead = git("ls-files", "--", "CLAUDE.md", "**/CLAUDE.md", ".claude").split("\n").filter(Boolean);
  const atBase = new Set(git("ls-tree", "-r", "--name-only", baseRef, "--", "CLAUDE.md", ".claude").split("\n").filter(Boolean));
  for (const path of git("ls-tree", "-r", "--name-only", baseRef).split("\n")) {
    if (path.endsWith("/CLAUDE.md")) atBase.add(path);
  }
  for (const path of new Set([...atHead, ...atBase])) {
    if (atBase.has(path)) {
      if (gitMaybe("diff", "--quiet", baseRef, "--", path) === undefined) {
        git("checkout", baseRef, "--", path);
        touched.push(path);
      }
    } else {
      git("rm", "-q", "--cached", "--", path);
      Bun.spawnSync(["rm", "-f", "--", path]);
      touched.push(path);
    }
  }
  return touched;
}
