// How the reviewer spent its run, read from Claude Code's stream-json
// messages: model, turns, wall and API time, and what each turn asked for.
// run.ts prints it to the log and the job summary, where speed is tuned from.

type Block = { type: string; name?: string; input?: Record<string, unknown> };
type Message = {
  type: string;
  subtype?: string;
  model?: string;
  message?: { content?: Block[] | string; model?: string };
  num_turns?: number;
  duration_ms?: number;
  duration_api_ms?: number;
  total_cost_usd?: number;
  permission_denials?: { tool_name: string; tool_input?: unknown }[];
  modelUsage?: Record<string, { inputTokens?: number; outputTokens?: number; cacheReadInputTokens?: number; cacheCreationInputTokens?: number }>;
};

export type Metrics = {
  model: string;
  turns: number;
  seconds: number;
  apiSeconds: number;
  costUsd: number;
  outputTokens: number;
  toolRounds: string[];
  denials: string[];
};

function describe(block: Block): string {
  const input = block.input ?? {};
  const arg = input.command ?? input.file_path ?? input.pattern ?? input.description ?? "";
  return `${block.name}(${String(arg).slice(0, 80)})`;
}

export function metricsOf(messages: Message[]): Metrics {
  const init = messages.find((m) => m.type === "system" && m.subtype === "init");
  const result = [...messages].reverse().find((m) => m.type === "result");
  const toolRounds = messages
    .filter((m) => m.type === "assistant" && Array.isArray(m.message?.content))
    .map((m) => (m.message!.content as Block[]).filter((b) => b.type === "tool_use").map(describe))
    .filter((calls) => calls.length > 0)
    .map((calls) => calls.join(", "));
  const usage = Object.values(result?.modelUsage ?? {});
  return {
    model: Object.keys(result?.modelUsage ?? {}).join(", ") || init?.model || "unknown",
    turns: result?.num_turns ?? 0,
    seconds: Math.round((result?.duration_ms ?? 0) / 1000),
    apiSeconds: Math.round((result?.duration_api_ms ?? 0) / 1000),
    costUsd: result?.total_cost_usd ?? 0,
    outputTokens: usage.reduce((sum, u) => sum + (u.outputTokens ?? 0), 0),
    toolRounds,
    denials: (result?.permission_denials ?? []).map((d) => `${d.tool_name} ${JSON.stringify(d.tool_input ?? {}).slice(0, 120)}`),
  };
}

export function renderMetrics(m: Metrics): string {
  return [
    "### Reviewer run",
    "",
    "| model | turns | wall | API | output tokens | cost (API equivalent) |",
    "|---|---|---|---|---|---|",
    `| ${m.model} | ${m.turns} | ${m.seconds}s | ${m.apiSeconds}s | ${m.outputTokens} | $${m.costUsd.toFixed(2)} |`,
    "",
    `Tool rounds (${m.toolRounds.length}):`,
    "",
    ...m.toolRounds.map((r, i) => `${i + 1}. ${r}`),
    ...(m.denials.length ? ["", `Permission denials (${m.denials.length}):`, "", ...m.denials.map((d) => `- ${d}`)] : []),
    "",
  ].join("\n");
}
