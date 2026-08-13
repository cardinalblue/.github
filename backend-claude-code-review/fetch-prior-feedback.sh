#!/usr/bin/env bash
# Collect every point that has ALREADY been made on this PR, so the reviewer can avoid
# repeating it. This is the memory that makes a per-push reviewer terminate: without it,
# every push re-derives the same findings from scratch and the author sees them forever.
#
# Two sources, because a point can already be on the PR in two shapes:
#   1. review threads — the resolvable inline threads this reviewer posts, PLUS threads
#                       opened by human reviewers (never duplicate a human either).
#   2. review bodies  — findings from an earlier round that could not be anchored to a
#                       changed line and were routed into the review's summary body. Those
#                       are NOT threads, so they appear in neither of the other lists; left
#                       out, they were re-derived on every single push.
#
# Deliberately NOT a source: claude[bot] issue comments. Filtering by that author cannot
# distinguish the old single-comment reviews from answers written by the `@claude` mention
# workflow (claude.yml, present in all caller repos). Feeding a developer's @claude
# conversation in as "already said" would gag the reviewer on anything it touched.
#
# Output: one JSON array at $OUT, entries shaped for the reviewer prompt.
# shellcheck disable=SC2016  # $owner/$name/$pr are GraphQL variables, not shell expansions
set -euo pipefail

REPO="" PR="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift ;;
    --pr) PR="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$REPO" ] && [ -n "$PR" ] && [ -n "$OUT" ] || { echo "--repo, --pr, --out required" >&2; exit 2; }

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# Bodies are truncated: the reviewer needs enough text to recognise "this point was already
# made", not the full argument.
#
# NOTE on `gh api graphql --paginate`: the query MUST declare `$endCursor: String` and
# select `pageInfo { hasNextPage endCursor }` for gh to walk pages. gh runs the --jq filter
# once PER PAGE and concatenates the output, so an array-wrapped filter would emit
# `[...][...]` — invalid JSON. Emit a FLAT object stream and slurp with `jq -s`.
gh api graphql --paginate \
  -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
  -f query='
    query($owner:String!, $name:String!, $pr:Int!, $endCursor:String) {
      repository(owner:$owner, name:$name) {
        pullRequest(number:$pr) {
          reviewThreads(first: 100, after: $endCursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              isResolved
              isOutdated
              path
              line
              comments(first: 1) { nodes { author { login } body } }
            }
          }
        }
      }
    }' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | (.comments.nodes[0].body // "") as $body
        | { source: "review_thread",
            author: (.comments.nodes[0].author.login // "unknown"),
            path: .path,
            line: .line,
            resolved: .isResolved,
            outdated: .isOutdated,
            # Computed on the FULL body: the marker sits at the end, so truncation below
            # would eat it. This is how the status comment counts how many of OUR earlier
            # findings are still outstanding, without depending on the posting identity.
            ours: ($body | contains("<!-- cb-backend-review:finding -->")),
            point: ($body[0:600]) }' \
  | jq -s '.' > /tmp/_prior-threads.json

# Review summary bodies that carry findings. Matched by marker, not by author, so this keeps
# working if the posting identity changes.
# `gh api --jq` takes no --arg, so the marker is inlined into the filter.
gh api --paginate "repos/${REPO}/pulls/${PR}/reviews" \
  --jq '.[]
        | select((.body // "") | contains("<!-- cb-backend-review:finding -->"))
        | { source: "review_body",
            author: .user.login,
            submitted_at: .submitted_at,
            point: ((.body // "")[0:1500]) }' \
  | jq -s '.' > /tmp/_prior-bodies.json || echo '[]' > /tmp/_prior-bodies.json

jq -s '.[0] + .[1]' /tmp/_prior-threads.json /tmp/_prior-bodies.json > "$OUT"

echo "Collected $(jq 'length' "$OUT") prior feedback item(s) for PR #${PR} \
($(jq '[.[] | select(.source == "review_thread")] | length' "$OUT") thread(s), \
$(jq '[.[] | select(.source == "review_body")] | length' "$OUT") review body/bodies)."
