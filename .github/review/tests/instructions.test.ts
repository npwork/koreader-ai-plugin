import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

test("collects trusted AGENTS.md rules and restores instructions before review", () => {
  const dir = mkdtempSync(join(tmpdir(), "review-instructions-"));
  const git = (...args: string[]) => {
    const result = Bun.spawnSync(["git", ...args], { cwd: dir, stdout: "pipe", stderr: "pipe" });
    if (result.exitCode !== 0) throw new Error(result.stderr.toString());
  };
  const write = (path: string, text: string) => writeFileSync(join(dir, path), text);
  try {
    git("init", "-q");
    git("config", "user.email", "test@example.test");
    git("config", "user.name", "Test");
    mkdirSync(join(dir, "src/new"), { recursive: true });
    mkdirSync(join(dir, ".claude"));
    write("AGENTS.md", "trusted root instructions");
    write("src/AGENTS.md", "trusted nested instructions");
    write(".claude/settings.json", "{}");
    write("src/code.ts", "export const value = 1;\n");
    git("add", ".");
    git("commit", "-qm", "base");
    git("branch", "trusted-base");
    write("AGENTS.md", "untrusted root instructions");
    rmSync(join(dir, "src/AGENTS.md"));
    write("src/new/AGENTS.md", "untrusted new instructions");
    write("CLAUDE.md", "untrusted automatic instructions");
    write("src/new/CLAUDE.md", "untrusted nested automatic instructions");
    write(".claude/settings.json", '{"untrusted":true}');
    write("src/code.ts", "export const value = 2;\n");
    git("add", ".");
    git("commit", "-qm", "head");
    const module = resolve(import.meta.dir, "../src/context.ts");
    const script = `
      import { collectContext, restoreBaseRules } from ${JSON.stringify(module)};
      import { readFileSync, existsSync } from "node:fs";
      const context = collectContext({repo:"o/r",number:1,title:"change",body:"",base:"main"}, "trusted-base", "Review", "diff.patch");
      restoreBaseRules("trusted-base");
      console.log(JSON.stringify({
        rules: context.rules, prompt: context.prompt,
        root: readFileSync("AGENTS.md", "utf8"), nested: readFileSync("src/AGENTS.md", "utf8"),
        settings: readFileSync(".claude/settings.json", "utf8"),
        injected: ["src/new/AGENTS.md", "CLAUDE.md", "src/new/CLAUDE.md"].some(existsSync)
      }));
    `;
    const result = Bun.spawnSync([process.execPath, "-e", script], { cwd: dir, stdout: "pipe", stderr: "pipe" });
    expect(result.exitCode).toBe(0);
    const output = JSON.parse(result.stdout.toString());
    expect(output.rules).toEqual(["AGENTS.md", "src/AGENTS.md"]);
    expect(output.prompt).toContain("### AGENTS.md\n\ntrusted root instructions");
    expect(output.prompt).toContain("### src/AGENTS.md\n\ntrusted nested instructions");
    expect(output.root).toBe("trusted root instructions");
    expect(output.nested).toBe("trusted nested instructions");
    expect(output.settings).toBe("{}");
    expect(output.injected).toBe(false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
