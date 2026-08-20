# Backend PR Risk Triage

One sticky comment per pull request that tells the reviewer **how much attention this PR
deserves, and where to spend it**.

It exists because diff size answers that question badly in both directions. A 1,200-line
locale sync needs a skim. A two-line change that drops a preserved field, raises a limit or
adds a backfill can be the riskiest PR of the week — and reads as trivial in the file list.

It is **not** a reviewer. It never reports a bug, a style point, a suggestion or a question.
`backend-claude-code-review.yml` is the only thing on these repos that reports findings.

## The three axes

| axis | 🟢 | 🟡 | 🔴 |
|---|---|---|---|
| **Blast radius** — who is exposed on deploy | `internal` — nothing user-visible changes | `feature` — one endpoint or flow | `wide` — every request, boot config, authz, or a cross-service contract |
| **Reversibility** — what it takes to undo | `revert-clean` — revert and redeploy | `needs-a-step` — rebuild an index, set a variable, order against a client release | `one-way` — destructive migration, bulk write, sent push, deleted object |
| **Detectability** — how fast we find out | `immediate` — raises, or is obviously wrong | `delayed` — needs real traffic; visible in hours | `metrics-only` — a wrong result still looks plausible |

## The level

Computed in `post-risk.sh`, never by the model:

```
High    reversibility is one-way
        OR detectability is metrics-only and blast is feature/wide
        OR blast is wide and detectability is delayed
Low     revert-clean AND immediate AND blast is internal/feature
Medium  everything else
then    a low-confidence judgment is raised one level, never lowered
```

Risk is the **worst** axis, not the average. `chore(db): drop unused announcements table` is
17 lines with an `internal` blast radius, and it is High, because `drop_table` takes the rows
with it and the `down` block only restores an empty table.

## Shape

```
extract-signals.sh   facts    — production reach, buckets, fan-in, risky operations in ADDED lines
      ↓
   the model         judgment — three axis values, three reasons, three prose fields. Nothing else.
      ↓
   post-risk.sh      output   — the level, the rendered comment, one upserted sticky comment
```

The model never writes the comment and never picks the level. That is what makes the format
identical on every PR, and it means the level rule can be re-tuned without re-prompting
anything.

## Properties worth keeping

- **Low renders two lines and no table.** Most PRs are Low. A three-row table on a
  locale-only PR is the noise the backend reviewer was rewritten to stop producing.
- **One comment, edited in place on every push.** Comment edits do not notify, so keeping
  the level current costs the author nothing.
- **No ratchet.** Unlike the iOS tier classifier, the level may fall when an author drops
  the migration. This is information, not a gate.
- **Fail-open and silent.** A missing or malformed judgment posts nothing and leaves the
  previous comment in place. "Risk unknown" is not a thing this bot says. A stale level with
  an older sha in its footer is honest; an invented one is not.
- **Operations are candidates, not verdicts.** `update_all` in a migration is a backfill;
  the same call in a test factory is nothing. The regex finds them; the model decides.
  They are only scanned in files that a production process actually loads — a
  `.rubocop_todo.yml` listing old migration filenames used to look like a destructive
  migration.

## Calling it

```yaml
jobs:
  risk-triage:
    if: github.event.pull_request.draft == false
    uses: cardinalblue/.github/.github/workflows/backend-pr-risk.yml@main
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

Triggered on `opened`, `ready_for_review` and `synchronize`. Bot-authored PRs are included
on purpose: a human still merges them and needs the same routing.

A repo whose layout the shared bucket table gets wrong can add
`.github/pr-risk-path-rules.json` — a JSON array of `{"re","bucket","prod"}` objects checked
before the built-in rules. Malformed overlays are ignored with a warning, because the file
lives in the PR's own head commit.
