// Posts one AI review on a pull request from the reviewer's structured output.
//
// Run by .github/workflows/review.yml after src/run.ts. The reviewer
// itself cannot write to GitHub; this script is the only thing that does, and
// it posts only what it could check: inline comments on lines the diff shows,
// committable suggestions whose "before" text matches HEAD. It posts them as a
// single review (one notification, not one per comment) and keeps one summary
// comment per PR, edited in place on every run.
//
// Env: GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, HEAD_SHA, RUN_URL,
// REVIEW_FILE (run.ts's review.json; missing when the reviewer produced
// nothing), DRY_RUN ("true": print what would be posted instead of posting it).

import { existsSync, readFileSync } from "node:fs";
import { parsePatch, type Hunk } from "./diff.ts";
import {
  SUMMARY_MARKER,
  fingerprintsIn,
  parseReview,
  plan,
  renderFailure,
  renderInline,
  renderSummary,
  type ReviewOutput,
} from "./review.ts";

const REVIEWER_LOGIN = "github-actions[bot]";

function env(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

const token = env("GITHUB_TOKEN");
const repo = env("GITHUB_REPOSITORY");
const pr = Number(env("PR_NUMBER"));
const headSha = env("HEAD_SHA");
const runUrl = env("RUN_URL");
const api = `https://api.github.com/repos/${repo}`;
const dryRun = process.env.DRY_RUN === "true";

async function gh(method: string, path: string, body?: unknown): Promise<Response> {
  const res = await fetch(path.startsWith("https://") ? path : `${api}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return res;
}

async function ok(res: Response, what: string): Promise<Response> {
  if (!res.ok) throw new Error(`${what}: ${res.status} ${await res.text()}`);
  return res;
}

async function all<T>(path: string): Promise<T[]> {
  const items: T[] = [];
  let url: string | undefined = `${api}${path}${path.includes("?") ? "&" : "?"}per_page=100`;
  while (url) {
    const res = await ok(await gh("GET", url), `GET ${path}`);
    items.push(...((await res.json()) as T[]));
    url = /<([^>]+)>;\s*rel="next"/.exec(res.headers.get("link") ?? "")?.[1];
  }
  return items;
}

async function upsertSummary(body: string): Promise<void> {
  if (dryRun) {
    console.log(`--- summary (dry run, not posted) ---\n${body}`);
    return;
  }
  const comments = await all<{ id: number; body?: string; user?: { login: string } }>(`/issues/${pr}/comments`);
  const mine = comments.find((c) => c.user?.login === REVIEWER_LOGIN && c.body?.includes(SUMMARY_MARKER));
  if (mine) await ok(await gh("PATCH", `/issues/comments/${mine.id}`, { body }), "update summary");
  else await ok(await gh("POST", `/issues/${pr}/comments`, { body }), "create summary");
}

function readHead(path: string): string | undefined {
  // The workflow checks out HEAD_SHA, so the working tree is the PR head.
  return existsSync(path) ? readFileSync(path, "utf8") : undefined;
}

async function main(): Promise<void> {
  const file = env("REVIEW_FILE");
  if (!existsSync(file)) {
    await upsertSummary(renderFailure(headSha, runUrl, "The reviewer returned no findings, usually a turn limit or a spent subscription window; the run log says which."));
    return;
  }
  const raw = readFileSync(file, "utf8");
  let review: ReviewOutput;
  try {
    review = parseReview(raw);
  } catch (e) {
    await upsertSummary(renderFailure(headSha, runUrl, `The reviewer output could not be read (${(e as Error).message}).`));
    return;
  }

  const files = await all<{ filename: string; patch?: string }>(`/pulls/${pr}/files`);
  const hunks = new Map<string, Hunk[]>(files.map((f) => [f.filename, f.patch ? parsePatch(f.patch) : []]));
  // Only inline comments count as already raised: they stay on the PR. The
  // summary is rewritten on every run, so what it listed is listed again.
  const earlier = await all<{ body?: string; user?: { login: string } }>(`/pulls/${pr}/comments`);
  // A dry run shows everything it found, whatever an earlier run posted.
  const seen = dryRun ? new Set<string>() : fingerprintsIn(earlier.filter((c) => c.user?.login === REVIEWER_LOGIN).map((c) => c.body ?? ""));
  const p = plan({ findings: review.findings, hunks, seen, readHead });
  const fileUrl = (path: string, line: number) => `https://github.com/${repo}/blob/${headSha}/${path}#L${line}`;

  if (p.inline.length > 0) {
    const comments = p.inline.map((f) => ({
      path: f.path,
      body: renderInline(f),
      side: "RIGHT",
      line: f.endLine,
      ...(f.startLine < f.endLine ? { start_line: f.startLine, start_side: "RIGHT" } : {}),
    }));
    const review = {
      commit_id: headSha,
      event: "COMMENT",
      body: `AI review: ${p.inline.length} comment(s). The summary comment on this PR has the rest.`,
      comments,
    };
    if (dryRun) {
      for (const c of comments) console.log(`--- inline ${c.path}:${c.line} (dry run, not posted) ---\n${c.body}`);
    }
    const res = dryRun ? new Response(null, { status: 201 }) : await gh("POST", `/pulls/${pr}/reviews`, review);
    if (res.status === 422) {
      // Placement is checked against the diff first, so this should not
      // happen; if GitHub still refuses a line, keep the findings rather
      // than lose them, and say why in the log.
      console.warn(`review refused (${await res.text()}); moving inline findings to the summary`);
      p.summaryOnly.unshift(...p.inline.map((f) => ({ ...f, why: "unanchored" as const, suggestion: f.suggestion === "committable" ? ("code" as const) : f.suggestion })));
      p.inline = [];
    } else {
      await ok(res, "create review");
    }
  }

  await upsertSummary(renderSummary({ review, plan: p, headSha, runUrl, fileUrl }));
  console.log(
    `${dryRun ? "would post" : "posted"}: ${p.inline.length} inline, ${p.summaryOnly.length} summary-only, ${p.repeated.length} repeated, ${p.droppedLowScore} dropped`,
  );
}

await main();
