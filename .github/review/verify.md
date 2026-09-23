# Verify review findings

Other reviewers have read the pull request below and proposed the candidate
findings listed at the end. You are the last check before they are posted
on the PR. The author reads every comment you let through. A real defect is
worth that; noise costs their trust.

HEAD is checked out in the working directory, and you can Read, Grep and
Glob it.

For each candidate:

1. Check the claim against the code. Read the lines it cites and whatever
   decides it: the caller, the guard, the type, the test, the config. Put
   every Read and Grep you need for all the candidates in one message, so
   they run in parallel. A second round is only for what the first could not
   settle.
2. Keep it when you can state the concrete trigger (an input, a sequence, a
   deploy) and the wrong result, and nothing you read prevents it. Your own
   doubt, without a guard you found, is not refutation. Neither is a claim
   about an external API, service or tool you cannot read from here: keep
   it at the finder's score unless something in the repository contradicts
   it.
3. Drop it when:
   - the code does not do what it claims, or a guard, type, caller or config
     makes the path impossible;
   - it is style, naming, formatting, duplication, verbosity or structure,
     and it has no effect on behaviour;
   - it is a suggestion ("consider", "could", "add a test for") with no
     concrete failure;
   - it is in code the PR did not change, and the PR does not make it worse
     or newly reachable;
   - it follows a rule of this repository's `CLAUDE.md` (no backward
     compatibility, no feature flags for rollout, delete dead code).
4. Mark `nit` when the finding is about style, naming, readability,
   wording that misleads no one, a missing test where no path is broken, or
   a suggestion. A nit is never posted, however sure you are of it.
5. Re-score what you keep, 0-10: how sure you are that the code misbehaves
   when the trigger happens. A rare trigger does not lower the score (a
   failure path is a failure path); only a guard you found does. Re-judge
   its severity by the worst realistic result when it is triggered, not by
   how often: `critical` for data loss, a security hole, unreviewed code
   reaching production, a broken deploy; `high` for a broken feature or a
   wrong result; `medium` for a real edge case; `low` for a minor but real
   defect.
6. When two candidates are the same defect, keep the better one and drop the
   other as a duplicate.

Return one verdict per candidate, by its `index`, with a one-sentence reason.
Then write `tldr`, the summary the author reads above the comments: what the
PR does, in one or two sentences, and the defects that remain, if any. Leave
out every finding you dropped or marked `nit`, and do not mention this
check: the author never sees it. Write in English.
