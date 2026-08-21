#!/usr/bin/env bash
# Collect the `/risk` replies on a PR — the authored context the triage must respect.
#
# The team's rule: the author knows things the diff cannot show ("that consumer is not in
# production yet", "the format was agreed with the other team last week"), so a `/risk`
# comment from a collaborator is TRUSTED input, not evidence to be weighed. This script is
# the channel that carries it.
#
# It runs on EVERY trigger, not only on the comment that caused one. That is the whole
# point: without it, the next push recomputes from the diff alone, silently re-raises the
# level, and the author has to make the same argument again — which is the loop the
# reviewer redesign already had to fix once.
#
# Who counts: any human. Bots are excluded because our own comment advertises `/risk` in
# its footer and would otherwise feed itself.
#
# This deliberately does NOT filter on `author_association`, even though the workflow's
# trigger does. The two see different values for the same comment: the event payload
# reports `MEMBER`, while this listing — made with the Actions `GITHUB_TOKEN` — does not,
# because a private organization membership is invisible to a repository-scoped token.
# Verified on pic-collage-server#4428, where the trigger fired on a MEMBER comment and this
# script then collected zero replies from the same comment 21 seconds later.
#
# Write access is still enforced, once, where the value is trustworthy: the workflow's `if`
# reads it from the event payload. Everyone who can comment on a PR in these private repos
# already has read access granted by the org, so re-checking it here bought nothing and
# silently dropped every reply.
#
# Output: $OUT (JSON array, newest last) and $DIGEST (markdown for the prompt).
# Never fails the caller — no replies and an unreadable listing both produce an empty set.
set -uo pipefail

REPO="" PR="" OUT="/tmp/risk-replies.json" DIGEST="/tmp/risk-replies.md" MAX=10
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift ;;
    --pr) PR="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --digest) DIGEST="$2"; shift ;;
    --max) MAX="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$REPO" ] && [ -n "$PR" ] || { echo "--repo and --pr required" >&2; exit 2; }

case "$MAX" in
  ''|*[!0-9]*) echo "::warning::--max '${MAX}' is not a number; using 10."; MAX=10 ;;
esac

if ! LIST="$(gh api --paginate "repos/${REPO}/issues/${PR}/comments" 2>/tmp/_risk-replies-err)"; then
  echo "::warning::could not list PR comments; treating this run as having no /risk replies."
  sed 's/^/    /' /tmp/_risk-replies-err >&2 || true
  echo '[]' > "$OUT"
  echo "_No \`/risk\` replies on this PR._" > "$DIGEST"
  exit 0
fi

# `contains("/risk")` rather than a word boundary: `/risk`, `/risk please`, and a sentence
# ending `... /risk.` all mean the same thing to the person typing it.
printf '%s' "$LIST" | jq --argjson max "$MAX" '
  (if type == "array" then . else [.] end)
  | [ .[]
      | select(.user.type != "Bot")
      | select((.body // "") | contains("/risk"))
      | { id, login: .user.login, association: .author_association,
          url: .html_url, created_at,
          body: ((.body // "") | .[0:2000]) } ]
  | sort_by(.created_at)
  | .[-$max:]' > "$OUT" 2>/dev/null || echo '[]' > "$OUT"

COUNT="$(jq 'length' "$OUT" 2>/dev/null || echo 0)"

{
  if [ "$COUNT" -eq 0 ]; then
    echo "_No \`/risk\` replies on this PR. Judge the change from the diff alone._"
  else
    echo "## \`/risk\` replies from the author and reviewers"
    echo
    echo "These are TRUSTED. The people who wrote them know context this repository does not"
    echo "show. Respect their judgement: when one of them says a risk does not apply, or"
    echo "gives a fact that changes an axis, take it and record the adjustment."
    echo
    jq -r '.[] | "### \(.login) (\(.association)) — \(.url)\n\n\(.body)\n"' "$OUT" 2>/dev/null
  fi
} > "$DIGEST"

# Logged per reply: a future mismatch between what the trigger saw and what this collected
# should be readable straight from the run, not re-derived from timestamps.
jq -r '.[] | "  kept: \(.login) (\(.association)) \(.url)"' "$OUT" 2>/dev/null || true
echo "Collected ${COUNT} /risk reply(ies) for ${REPO}#${PR}."
