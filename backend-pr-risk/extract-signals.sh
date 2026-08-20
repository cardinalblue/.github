#!/usr/bin/env bash
# Mechanical pass for the PR risk triage. Produces the evidence the judgment is made FROM;
# it never produces the judgment itself.
#
# Splitting it this way is the whole reason the comment can claim a consistent format:
#   this script  -> facts (buckets, line counts, which risky operations appear in the diff)
#   the model    -> three axis ratings + short reasons, nothing else
#   post-risk.sh -> the level (pure function of the three ratings) and the rendered comment
#
# Two facts this collects that no line count can give you, and that the axes lean on:
#   * production reach — which changed files are actually loaded by a running production
#     process. "19 files, one of them ships" is the single most useful sentence this bot
#     writes, and it comes from here, not from the model.
#   * one-way operations — destructive migrations, bulk writes, sent pushes, deleted
#     objects. These decide the reversibility axis, and grepping for them is exactly the
#     kind of work a model does unreliably and a regex does perfectly.
#
# Output: $OUT (JSON, the full signal set) and $DIGEST (markdown, what the prompt embeds).
#
# NEVER fails the caller. Every step that can fail degrades to an empty-but-valid signal
# set; the workflow then decides that no judgment is possible and posts nothing, which is
# the honest outcome. A risk comment is an aid, not a gate.
set -uo pipefail

REPO="" PR="" OUT="/tmp/risk-signals.json" DIGEST="/tmp/risk-digest.md" OVERLAY="" REPO_DIR="."
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift ;;
    --pr) PR="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --digest) DIGEST="$2"; shift ;;
    --overlay) OVERLAY="$2"; shift ;;
    --repo-dir) REPO_DIR="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$REPO" ] && [ -n "$PR" ] || { echo "--repo and --pr required" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 1. Path rules: bucket + production reach.
#
# First match wins, so order is meaningful — the narrow rules come before the broad ones.
# `prod` answers one question only: does a production process load this file? Tests, CI,
# dev tooling and agent docs do not, and a PR made only of those cannot hurt a user no
# matter how many lines it moves.
#
# These are Rails-wide on purpose. Every backend repo here has app/{models,controllers,
# jobs}, db/migrate and config/, so the base set carries all four. A repo with a layout of
# its own passes --overlay (see below) rather than forking this table.
# ---------------------------------------------------------------------------
BASE_RULES='[
  {"re":"^db/migrate/",                          "bucket":"migration",      "prod":true},
  {"re":"^db/(data_migrate|data_migrations)/",   "bucket":"migration",      "prod":true},
  {"re":"^db/.*schema\\.rb$",                    "bucket":"schema",         "prod":false},
  {"re":"^db/seeds",                             "bucket":"seed",           "prod":false},
  {"re":"^lib/tasks/.*\\.rake$",                 "bucket":"data_task",      "prod":true},
  {"re":"^app/(jobs|workers)/",                  "bucket":"job",            "prod":true},
  {"re":"^config/(recurring|queue|cable)\\.yml$","bucket":"job",            "prod":true},
  {"re":"^config/routes",                        "bucket":"controller",     "prod":true},
  {"re":"^app/controllers/",                     "bucket":"controller",     "prod":true},
  {"re":"^app/(adapters|use_cases|services)/.*(presenter|serializer|decorator)",
                                                 "bucket":"api_response",   "prod":true},
  {"re":"^app/(serializers|views)/",             "bucket":"api_response",   "prod":true},
  {"re":"^app/models/",                          "bucket":"model",          "prod":true},
  {"re":"^app/(adapters|use_cases|services|lib)/","bucket":"logic",         "prod":true},
  {"re":"^(lib|app)/",                           "bucket":"logic",          "prod":true},
  {"re":"^config/locales/",                      "bucket":"locale",         "prod":true},
  {"re":"^app/javascript/",                      "bucket":"cms_frontend",   "prod":true},
  {"re":"^(package\\.json|yarn\\.lock|Gemfile\\.lock)$","bucket":"lockfile", "prod":true},
  {"re":"^(Gemfile|Dockerfile|Procfile)",        "bucket":"runtime_config", "prod":true},
  {"re":"^config/",                              "bucket":"runtime_config", "prod":true},
  {"re":"^(test|spec)/",                         "bucket":"test",           "prod":false},
  {"re":"^docs/",                                "bucket":"api_docs",       "prod":false},
  {"re":"^(\\.github|\\.circleci|\\.githooks)/", "bucket":"ci_dev",         "prod":false},
  {"re":"^(bin|script)/",                        "bucket":"ci_dev",         "prod":false},
  {"re":"^tryout-server/",                       "bucket":"ci_dev",         "prod":false},
  {"re":"docker-compose",                        "bucket":"ci_dev",         "prod":false},
  {"re":"^\\.rubocop",                           "bucket":"ci_dev",         "prod":false},
  {"re":"^agent/",                               "bucket":"agent_docs",     "prod":false},
  {"re":"\\.md$",                                "bucket":"docs",           "prod":false}
]'

# A caller repo may prepend rules for a layout the base set gets wrong. Same shape, and it
# is CHECKED — a malformed overlay is ignored with a warning rather than taking the run
# down, because the overlay lives in the PR's own head commit and can be edited by the PR.
RULES="$BASE_RULES"
if [ -n "$OVERLAY" ] && [ -f "$OVERLAY" ]; then
  if MERGED="$(jq -e --argjson base "$BASE_RULES" \
        'if type == "array" and all(.[]; (.re | type) == "string" and (.bucket | type) == "string")
         then . + $base else error("bad overlay") end' "$OVERLAY" 2>/dev/null)"; then
    RULES="$MERGED"
    echo "Applied $(jq 'length' "$OVERLAY") overlay path rule(s) from ${OVERLAY}."
  else
    echo "::warning::overlay '${OVERLAY}' is not a valid rule array; using base rules only."
  fi
fi

# ---------------------------------------------------------------------------
# 2. Fetch the changed files, with their patches.
#
# The files API rather than `gh pr diff`, because it carries per-file status (so renames
# are already identified) and additions/deletions counts we would otherwise have to parse.
# GitHub omits `patch` for very large or binary files — that absence is itself a signal
# ("too big to read"), so it is recorded rather than treated as an error.
# ---------------------------------------------------------------------------
FILES_JSON=/tmp/_risk-pr-files.json
if ! gh api --paginate "repos/${REPO}/pulls/${PR}/files" \
      --jq '.[] | {filename, status, additions, deletions, patch: (.patch // "")}' \
      2>/tmp/_risk-gh-err | jq -s '.' > "$FILES_JSON"; then
  echo "::warning::could not fetch changed files for ${REPO}#${PR}; emitting an empty signal set."
  sed 's/^/    /' /tmp/_risk-gh-err >&2 || true
  echo '{"ok":false,"reason":"file-fetch-failed"}' > "$OUT"
  echo "_No signals: the changed-file list could not be fetched._" > "$DIGEST"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Bucket every file, and scan ADDED lines for one-way and blast-radius operations.
#
# Added lines only. A removed `update_all` is not a bulk write this PR performs, and
# scanning both halves made every refactor that moved a risky call look like a new one.
#
# These patterns are HINTS handed to the judgment, never verdicts. `update_all` in a
# migration is a backfill; the same call in a test factory is nothing. Deciding which is
# which is the model's job — finding the candidates is this script's.
# ---------------------------------------------------------------------------
PATTERNS='[
  {"key":"destructive_migration","re":"\\b(drop_table|remove_column|rename_column|change_column|remove_index|rename_table|drop_view)\\b",
   "note":"destructive or irreversible schema change"},
  {"key":"blocking_index","re":"add_index",
   "note":"index added — check for algorithm: :concurrently on a large table"},
  {"key":"bulk_write","re":"\\b(update_all|delete_all|destroy_all|upsert_all|insert_all|update_column|update_columns)\\b",
   "note":"bulk write that bypasses callbacks and cannot be reverted by redeploying"},
  {"key":"batch_backfill","re":"\\b(find_each|find_in_batches|in_batches)\\b",
   "note":"batched pass over a table — a backfill if it writes"},
  {"key":"outbound_message","re":"(Rpush|deliver_now|deliver_later|Mailer|push_notification|PushNotification)",
   "note":"sends something to users that cannot be recalled"},
  {"key":"object_delete","re":"(\\.purge\\b|delete_object|delete_matched|remove_previously_stored)",
   "note":"deletes stored objects or cache entries"},
  {"key":"search_index","re":"(Elasticsearch|_source_includes|reindex|refresh_index|word_embedding)",
   "note":"touches the search index — rebuilding it is a separate step"},
  {"key":"external_service","re":"(Hopter|OpenAI|Faraday|RestClient|HTTParty|Net::HTTP|Typhoeus|Stripe|Firebase)",
   "note":"calls a third-party or internal service across the network"},
  {"key":"ranking_ml","re":"(embedding|similarity|style_tags|ranking|\\bscore\\b|\\bweight\\b|ab_test|experiment)",
   "note":"affects ranking or model output — wrong results still look plausible"},
  {"key":"entitlement","re":"(subscription|purchase|receipt|entitlement|\\biap\\b|vip)",
   "note":"touches paid entitlement"},
  {"key":"authz","re":"(authenticate|authorize|current_user|admin_only|before_action)",
   "note":"touches an authentication or authorization path"},
  {"key":"gating","re":"(FeatureFlag|feature_flag|XConfig|xconfig|ENV\\[|ENV\\.fetch)",
   "note":"reads a flag or environment variable — check the value exists in every environment"},
  {"key":"caching","re":"(Rails\\.cache|Redis\\.|expires_in|cache_key)",
   "note":"changes cached data — stale entries can outlive a revert"}
]'

jq -n \
  --slurpfile files "$FILES_JSON" \
  --argjson rules "$RULES" \
  --argjson patterns "$PATTERNS" \
  --arg repo "$REPO" --arg pr "$PR" '
  def classify($path):
    ($rules | map(select(. as $r | $path | test($r.re))) | .[0]) // {bucket:"other", prod:true};

  ($files[0] // []) as $fs
  | [ $fs[]
      | classify(.filename) as $c
      | (.patch | split("\n") | map(select(startswith("+") and (startswith("+++") | not))) | join("\n")) as $added
      | {
          filename, status, additions, deletions,
          bucket: $c.bucket,
          prod: $c.prod,
          # A rename with no net line change is a move; the reviewer does not need to read it.
          moved: (.status == "renamed" and (.additions == .deletions)),
          unreadable: (.patch == ""),
          # Production files only. A rubocop_todo.yml listing old migration filenames, or a
          # README naming Elasticsearch, matched these patterns and put "destructive
          # migration" style hints in front of the judgment for a dev-tooling PR.
          hits: (if $c.prod then [ $patterns[] | . as $p | select($added | test($p.re)) | $p.key ] else [] end)
        } ]
  | . as $classified
  | {
      ok: true,
      repo: $repo, pr: $pr,
      totals: {
        files: ($classified | length),
        additions: ([$classified[].additions] | add // 0),
        deletions: ([$classified[].deletions] | add // 0)
      },
      # The second dial: how much of this diff can actually change production behaviour.
      production: {
        files: ([$classified[] | select(.prod)] | length),
        additions: ([$classified[] | select(.prod) | .additions] | add // 0),
        paths: [$classified[] | select(.prod) | .filename]
      },
      non_production: {
        files: ([$classified[] | select(.prod | not)] | length),
        additions: ([$classified[] | select(.prod | not) | .additions] | add // 0),
        buckets: ([$classified[] | select(.prod | not) | .bucket] | unique)
      },
      buckets: ( $classified
                 | group_by(.bucket)
                 | map({ (.[0].bucket): {
                     files: length,
                     additions: ([.[].additions] | add // 0),
                     deletions: ([.[].deletions] | add // 0) } })
                 | add // {} ),
      moved_files: [$classified[] | select(.moved) | .filename],
      unreadable_files: [$classified[] | select(.unreadable) | .filename],
      # Flat hit table: which operation appeared, and in which files. The file list is what
      # makes the model cite a path instead of paraphrasing the pattern name back at us.
      operations: ( [ $patterns[] as $p
                      | ([$classified[] | select(.hits | index($p.key)) | .filename]) as $where
                      | select($where | length > 0)
                      | { key: $p.key, note: $p.note, files: $where } ] )
    }' > "$OUT" 2>/tmp/_risk-jq-err || {
  echo "::warning::signal extraction failed; emitting an empty signal set."
  sed 's/^/    /' /tmp/_risk-jq-err >&2 || true
  echo '{"ok":false,"reason":"classify-failed"}' > "$OUT"
  echo "_No signals: classification failed._" > "$DIGEST"
  exit 0
}

# ---------------------------------------------------------------------------
# 4. Fan-in for the changed production files.
#
# A string-layer approximation, exactly like the iOS classifier's: how many OTHER files
# mention this file's main constant. It separates "one endpoint" from "everything calls
# this" on the blast-radius axis, which line counts cannot.
#
# Guarded and capped: needs a checkout, skipped without one, and never more than 12
# lookups so a 300-file PR cannot turn this into a minute of git grep.
# ---------------------------------------------------------------------------
FANIN='{}'
if [ -d "${REPO_DIR}/app" ] && command -v git >/dev/null 2>&1; then
  FANIN_TSV=/tmp/_risk-fanin.tsv
  : > "$FANIN_TSV"
  while IFS= read -r f; do
    [ -f "${REPO_DIR}/${f}" ] || continue
    # The first top-level class/module in the file — its public name.
    SYM="$(grep -m1 -oE '^[[:space:]]*(class|module) [A-Z][A-Za-z0-9_:]*' "${REPO_DIR}/${f}" 2>/dev/null \
           | awk '{print $2}' | awk -F'::' '{print $NF}')"
    [ -n "${SYM:-}" ] || continue
    N="$(cd "$REPO_DIR" && git grep -l -F -- "$SYM" -- app lib config db 2>/dev/null | grep -cvF "$f")"
    printf '%s\t%s\n' "$SYM" "${N:-0}" >> "$FANIN_TSV"
  done < <(jq -r '.production.paths[]?' "$OUT" 2>/dev/null \
           | grep -E '\.rb$' | head -12 || true)
  # jq -R/-s over the TSV: no shell loop building JSON, so a symbol with a quote in it
  # cannot produce a malformed document.
  FANIN="$(jq -Rs 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber? // 0)}) | add // {}' \
           "$FANIN_TSV" 2>/dev/null || echo '{}')"
fi
jq --argjson f "$FANIN" '. + {fan_in: $f}' "$OUT" > /tmp/_risk-out.json 2>/dev/null \
  && mv /tmp/_risk-out.json "$OUT"

# ---------------------------------------------------------------------------
# 5. The digest — what the prompt actually reads.
#
# Markdown, not JSON: the judgment is three ratings with reasons, and a table of facts
# reads better for that than a nested object. The raw JSON stays available for anything
# that wants to compute on it.
# ---------------------------------------------------------------------------
{
  jq -r '
    "## Mechanical signals for \(.repo)#\(.pr)",
    "",
    "Total: \(.totals.files) file(s), +\(.totals.additions)/-\(.totals.deletions).",
    "**Reaches production: \(.production.files) file(s), +\(.production.additions).** " +
      "Not in production (\((.non_production.buckets // []) | join(", ") | if . == "" then "none" else . end)): " +
      "\(.non_production.files) file(s), +\(.non_production.additions).",
    "",
    "### Changed files by bucket",
    "",
    "| bucket | files | +add | -del |",
    "|---|---|---|---|",
    ( .buckets | to_entries[] | "| \(.key) | \(.value.files) | \(.value.additions) | \(.value.deletions) |" ),
    "",
    "### Files that a production process loads",
    "",
    ( if (.production.paths | length) == 0 then "_none_"
      else (.production.paths[] | "- `\(.)`") end ),
    "",
    "### Operations found in ADDED lines (candidates, not verdicts)",
    "",
    ( if (.operations | length) == 0 then "_none of the tracked operations appear in the added lines._"
      else (.operations[] | "- **\(.key)** — \(.note)\n  - " + (.files | map("`" + . + "`") | join(", ")))
      end ),
    "",
    ( if (.fan_in | length) == 0 then empty
      else "### Fan-in (files elsewhere in the repo mentioning each changed constant)\n",
           (.fan_in | to_entries[] | "- `\(.key)`: \(.value)"), ""
      end ),
    ( if (.moved_files | length) == 0 then empty
      else "### Pure moves/renames (no net line change)\n",
           (.moved_files[] | "- `\(.)`"), ""
      end ),
    ( if (.unreadable_files | length) == 0 then empty
      else "### No patch available (too large or binary) — treat as unread\n",
           (.unreadable_files[] | "- `\(.)`"), ""
      end )
  ' "$OUT" 2>/dev/null || echo "_Signal digest could not be rendered; read the diff directly._"
} > "$DIGEST"

echo "Signals written to ${OUT} ($(jq -r '.totals.files // 0' "$OUT") file(s), \
$(jq -r '.production.files // 0' "$OUT") reaching production, \
$(jq -r '.operations | length' "$OUT" 2>/dev/null || echo 0) operation hit(s)); digest at ${DIGEST}."
