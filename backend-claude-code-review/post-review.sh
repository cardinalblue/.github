#!/usr/bin/env bash
# Publish the reviewer's findings.
#
# Shape of the output, and why:
#   * findings  -> inline review threads (pulls/{n}/reviews). Unlike `gh pr comment` issue
#                  comments, these are RESOLVABLE: the author can resolve one, or reply
#                  "won't fix", and that decision is durable. It is also what makes the
#                  never-repeat rule work — an existing thread is the memory.
#   * status    -> ONE sticky issue comment, edited in place on every run. It records which
#                  SHA was reviewed, so nobody has to guess whether a review is stale.
#
#   Zero findings posts NO review at all — only the sticky is updated. Silence is the
#   expected outcome on most pushes, and a stream of "no blockers" reviews would recreate
#   the noise this workflow exists to remove.
#
# Findings JSON: [ { "path": "app/x.rb", "line": 42, "body": "..." }, ... ]
# Always submits COMMENT — never REQUEST_CHANGES or APPROVE. The human is the merge gate,
# and an automated reviewer must never block a PR on its own opinion.
#
# TWO RULES THIS SCRIPT EXISTS TO KEEP, both learned the hard way:
#   1. Never publish a status that is better than the truth. Every finding this run
#      produced — inline, routed to the review body, or dropped by the cap — has to be
#      reflected in the status. Deriving the wording from the inline count alone produced
#      three separate ways to say "No blockers found" while blockers were on screen.
#   2. Never fail the job. A broken reviewer must not put a red X on someone's PR, and must
#      not leave the PR with no status at all. Every jq filter here is total, and every API
#      call is guarded.
set -euo pipefail

REPO="" PR="" SHA="" FINDINGS_FILE="" PRIOR_FILE="" MAX_FINDINGS="5" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift ;;
    --pr) PR="$2"; shift ;;
    --sha) SHA="$2"; shift ;;
    --findings-file) FINDINGS_FILE="$2"; shift ;;
    --prior-file) PRIOR_FILE="$2"; shift ;;
    --max-findings) MAX_FINDINGS="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$REPO" ] && [ -n "$PR" ] && [ -n "$SHA" ] || { echo "--repo, --pr, --sha required" >&2; exit 2; }

# A non-integer cap used to abort the script inside --argjson. Fall back rather than fail.
case "$MAX_FINDINGS" in
  ''|*[!0-9]*) echo "::warning::--max-findings '${MAX_FINDINGS}' is not a non-negative integer; using 5."; MAX_FINDINGS=5 ;;
esac

SUMMARY_MARKER='<!-- cb-backend-review:summary -->'
FINDING_MARKER='<!-- cb-backend-review:finding -->'
SHORT_SHA="${SHA:0:7}"

# Initialised before any conditional path can be skipped: `set -u` turns a counter that is
# only assigned inside an if-branch into a hard abort on the first arithmetic that reads it.
COUNT=0 DROPPED=0 TRUNCATED=0 ANCHORABLE=0 MALFORMED=0 OUTSTANDING=-1 PRIOR_BODY_FINDINGS=0
VALID='[]'
UNANCHORED='[]'
REVIEWED=1

# ---------------------------------------------------------------------------
# 1. Normalise findings.
#
# "The reviewer ran and found nothing" and "the reviewer never ran" are NOT the same thing,
# and conflating them publishes a clean bill of health for a commit nobody looked at. The
# reviewer always writes the file — `[]` when it has no findings — so a MISSING or
# unparseable file means the review did not complete.
#
# Not hypothetical: claude-code-action refuses to run when a PR modifies the caller workflow
# file and exits SUCCESS when it does, so such runs reach this script with no findings file.
# ---------------------------------------------------------------------------
RAW=''
if [ -n "$FINDINGS_FILE" ] && [ -s "$FINDINGS_FILE" ]; then
  # `-s` slurps EVERY JSON document in the file into one array and we take the first. A model
  # that emits two concatenated documents (`[...]\n[]`) otherwise makes every later `jq` emit
  # two values, which turns each `$( )` into a multi-line string and breaks the arithmetic.
  RAW="$(jq -s 'if length == 0 then null else .[0] end' "$FINDINGS_FILE" 2>/dev/null || true)"
fi

if [ -n "$RAW" ] && printf '%s' "$RAW" | jq -e 'type == "array"' >/dev/null 2>&1; then
  # Type-check every field. `select((.body? // "") != "")` used to admit a non-string body,
  # and the later `.body + "\n\n"` then aborted the whole script with a jq type error —
  # no review, no status, and the PR left showing the previous commit's result.
  WELL_FORMED="$(printf '%s' "$RAW" | jq '[ .[]
    | select(type == "object")
    | select((.body? | type) == "string" and (.body | length) > 0) ]')"
  MALFORMED="$(printf '%s' "$RAW" | jq --argjson w "$WELL_FORMED" 'length - ($w | length)')"

  ANCHORED="$(printf '%s' "$WELL_FORMED" | jq '[ .[]
    | select((.path? | type) == "string" and (.path | length) > 0 and (.line? | type) == "number") ]')"
  UNANCHORED="$(printf '%s' "$WELL_FORMED" | jq '[ .[]
    | select(((.path? | type) != "string") or ((.path | length) == 0) or ((.line? | type) != "number")) ]')"

  ANCHORABLE="$(printf '%s' "$ANCHORED" | jq 'length')"
  VALID="$(printf '%s' "$ANCHORED" | jq --arg m "$FINDING_MARKER" --argjson max "$MAX_FINDINGS" \
    '[ .[] | { path: .path, line: (.line | floor), side: "RIGHT", body: (.body + "\n\n" + $m) } ] | .[0:$max]')"
else
  REVIEWED=0
  echo "::warning::No usable findings file — the reviewer did not complete. Reporting that, NOT a clean review."
fi

COUNT="$(printf '%s' "$VALID" | jq 'length')"
DROPPED="$(printf '%s' "$UNANCHORED" | jq 'length')"
TRUNCATED=$(( ANCHORABLE - COUNT ))

# Everything this run raised, wherever it ended up. The status is derived from THIS, not from
# the inline count — findings routed into the review body are still findings.
NEW_TOTAL=$(( COUNT + DROPPED ))
# Findings the reviewer produced that never reached the PR in any form. The author cannot
# act on these, so they must never be summarised as an absence of findings.
UNPUBLISHED=$(( TRUNCATED + MALFORMED ))

[ "$MALFORMED" -gt 0 ] && echo "::warning::${MALFORMED} finding(s) were malformed (missing or non-string body) and could not be published."
[ "$DROPPED" -gt 0 ] && echo "::warning::${DROPPED} finding(s) had no diff line to anchor to; routed into the review body."
# Never truncate silently — a hidden cap reads as "that is everything" when it is not.
[ "$TRUNCATED" -gt 0 ] && echo "::warning::${TRUNCATED} finding(s) beyond the --max-findings=${MAX_FINDINGS} cap were not posted."

# ---------------------------------------------------------------------------
# 2. Read prior state.
#
# `ours` marks threads this reviewer opened (by hidden marker, so it survives the posting
# identity changing). `review_body` entries are findings that could not be anchored in an
# earlier round: they live in a review's summary body, which is NOT a resolvable thread, so
# their state can never be known. Their existence is enough to stop us claiming all-clear.
# ---------------------------------------------------------------------------
if [ -n "$PRIOR_FILE" ] && [ -s "$PRIOR_FILE" ] && jq -e 'type == "array"' "$PRIOR_FILE" >/dev/null 2>&1; then
  OUTSTANDING="$(jq '[ .[] | select(.source == "review_thread" and .ours == true and .resolved != true) ] | length' "$PRIOR_FILE")"
  PRIOR_BODY_FINDINGS="$(jq '[ .[] | select(.source == "review_body") ] | length' "$PRIOR_FILE")"
fi

# ---------------------------------------------------------------------------
# 3. Post the review — only when this run actually raised something.
# ---------------------------------------------------------------------------
gh_guarded() {  # never let an API failure fail the job or skip the status comment
  if ! "$@" >/dev/null 2>/tmp/_gh-err; then
    echo "::warning::GitHub API call failed: $*"
    sed 's/^/    /' /tmp/_gh-err >&2 || true
    return 1
  fi
}

post_review() {
  local body="Reviewed \`${SHORT_SHA}\` — ${COUNT} inline finding(s)."
  if [ "$DROPPED" -gt 0 ]; then
    body="${body}

**Not anchored to a changed line** (so these have no resolvable thread — please handle them here):

$(printf '%s' "$UNANCHORED" | jq -r '.[] | "- " + (.body | gsub("\n"; " "))')

${FINDING_MARKER}"
  fi

  local payload
  payload="$(jq -n --arg sha "$SHA" --arg body "$body" --argjson comments "$VALID" \
    '{ commit_id: $sha, event: "COMMENT", body: $body, comments: $comments }')"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "POST repos/$REPO/pulls/$PR/reviews"; echo "$payload"; return 0
  fi

  # The reviews API 422s the WHOLE review if any inline comment targets a line outside the
  # diff. Fall back to a summary-only review so the findings still reach the author.
  if echo "$payload" | gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input - >/dev/null 2>/tmp/_review-err; then
    echo "Posted COMMENT review with ${COUNT} inline thread(s)."
  else
    echo "::warning::inline review POST failed (a comment likely targets a line outside the diff); posting summary-only."
    cat /tmp/_review-err >&2
    jq -n --arg sha "$SHA" --arg body "Reviewed \`${SHORT_SHA}\`.

$(printf '%s' "$VALID" | jq -r '.[] | "- **" + .path + ":" + (.line | tostring) + "** — " + (.body | gsub("\n"; " "))')

$(printf '%s' "$UNANCHORED" | jq -r '.[] | "- " + (.body | gsub("\n"; " "))')

> ⚠️ These could not be posted inline, so they have no resolvable thread. Please handle them here.

${FINDING_MARKER}" '{ commit_id: $sha, event: "COMMENT", body: $body }' \
      | gh_guarded gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input - || true
  fi
}

if [ "$NEW_TOTAL" -gt 0 ]; then
  post_review
else
  echo "Nothing raised this run — posting no review (sticky status only)."
fi

# ---------------------------------------------------------------------------
# 4. Upsert the sticky status comment (always).
#    Upsert rather than post-new-and-hide-old: nothing to race on, so two overlapping runs
#    converge on last-write-wins instead of stacking comments on the PR.
# ---------------------------------------------------------------------------
if [ "$REVIEWED" -eq 0 ]; then
  STATUS="⚠️ **This commit was not reviewed** — the reviewer produced no result, so nothing here is a clean bill of health. See the workflow run for why."
elif [ "$NEW_TOTAL" -gt 0 ]; then
  STATUS="Found **${NEW_TOTAL} new possible blocker(s)**."
  if [ "$DROPPED" -gt 0 ]; then
    STATUS="${STATUS} ${COUNT} as inline thread(s); ${DROPPED} in the review body, because they could not be anchored to a changed line."
  else
    STATUS="${STATUS} See the inline thread(s) on this PR."
  fi
  STATUS="${STATUS}

Resolve a thread once it is handled, or reply if you disagree. Either way this reviewer will **not** raise that point again."
  if [ "$OUTSTANDING" -gt 0 ]; then
    STATUS="${STATUS}

${OUTSTANDING} earlier thread(s) from this reviewer are also still unresolved."
  fi
elif [ "$UNPUBLISHED" -gt 0 ]; then
  # Findings existed but none reached the PR. "No blockers found" would be false, and so
  # would "no new blockers" — we know there were some, we just could not show them.
  STATUS="⚠️ **This run produced findings that could not be published**, so this is not a clean review. See the workflow run."
elif [ "$OUTSTANDING" -gt 0 ]; then
  STATUS="**No new blockers** in this push — but ${OUTSTANDING} earlier thread(s) from this reviewer are still unresolved."
elif [ "$OUTSTANDING" -eq 0 ] && [ "$PRIOR_BODY_FINDINGS" -eq 0 ]; then
  STATUS="No blockers found."
else
  # Either prior feedback was unreadable, or an earlier round left findings in a review body
  # whose state cannot be tracked. Say only what is certainly true of this push.
  STATUS="No new blockers in this push."
fi

if [ "$MALFORMED" -gt 0 ]; then
  STATUS="${STATUS}

⚠️ ${MALFORMED} finding(s) could not be published because the reviewer emitted them malformed. See the workflow run."
fi
if [ "$TRUNCATED" -gt 0 ]; then
  STATUS="${STATUS}

⚠️ ${TRUNCATED} further finding(s) were held back by the per-run cap of ${MAX_FINDINGS}."
fi

STICKY_BODY="${SUMMARY_MARKER}
### 🤖 Claude review — \`${SHORT_SHA}\`

${STATUS}

<sub>Reviews blockers and obvious mistakes only; style and preference are out of scope. Add the \`skip-claude-review\` label to switch it off for this PR.</sub>"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "--- sticky ---"; echo "$STICKY_BODY"; exit 0
fi

# Author-scoped: the marker alone would also match a human who quote-replied to the sticky,
# and this token can edit anyone's comment.
EXISTING_ID=""
if LIST="$(gh api --paginate "repos/${REPO}/issues/${PR}/comments" 2>/tmp/_gh-err)"; then
  EXISTING_ID="$(printf '%s' "$LIST" | jq -r --arg m "$SUMMARY_MARKER" \
    'if type == "array" then .[] else . end | select(.user.type == "Bot") | select((.body // "") | contains($m)) | .id' | head -n 1 || true)"
else
  # Do NOT fall through to POST here: a failed listing would create a SECOND sticky, and
  # repeat that each push. Skipping one status update is the smaller harm.
  echo "::warning::could not list PR comments; leaving the status comment untouched this run."
  sed 's/^/    /' /tmp/_gh-err >&2 || true
  exit 0
fi

if [ -n "$EXISTING_ID" ]; then
  gh_guarded gh api --method PATCH "repos/${REPO}/issues/comments/${EXISTING_ID}" -f body="$STICKY_BODY" \
    && echo "Updated sticky status comment ${EXISTING_ID}." || true
else
  gh_guarded gh api --method POST "repos/${REPO}/issues/${PR}/comments" -f body="$STICKY_BODY" \
    && echo "Created sticky status comment." || true
fi
