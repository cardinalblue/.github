#!/usr/bin/env bash
# Turn the model's three axis ratings into a level, render the comment, upsert it.
#
# The model never writes the comment and never picks the level. It answers three questions
# and writes three short reasons; everything a reader sees is assembled here. That is what
# makes "consistent format" a property of the system rather than a hope about the prompt,
# and it means the level can be re-tuned in one place without re-prompting anything.
#
# THE LEVEL RULE (the only place it exists):
#   High   reversibility is one-way
#          OR detectability is metrics-only and blast is feature/wide
#          OR blast is wide and detectability is delayed
#   Low    revert-clean AND immediate AND blast is internal/feature
#   Medium everything else
#   then:  a low-confidence judgment is raised one level, never lowered.
#
# Risk is the MAXIMUM over the axes, not their average. One irreversible backfill in an
# otherwise trivial PR makes the PR high — that case (two lines that corrupt data) is the
# whole reason this bot exists, and averaging would hide it.
#
# NO RATCHET, deliberately unlike the iOS tier classifier: when an author drops the
# migration, the level must be allowed to fall. This is information for a reviewer, not a
# gate, so an old high level that cannot come down is just a lie that stays on the PR.
#
# Never fails the caller, and never posts a level it did not compute — a missing or
# malformed judgment leaves the previous comment untouched and says so in the log. "Risk
# unknown" is not a thing this bot says.
set -uo pipefail

REPO="" PR="" SHA="" RISK_FILE="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift ;;
    --pr) PR="$2"; shift ;;
    --sha) SHA="$2"; shift ;;
    --risk-file) RISK_FILE="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$REPO" ] && [ -n "$PR" ] || { echo "--repo and --pr required" >&2; exit 2; }

MARKER='<!-- cb-pr-risk:summary -->'
SHORT_SHA="${SHA:0:7}"

# ---------------------------------------------------------------------------
# 1. Read and validate the judgment.
#
# Strict on the three axes (they decide the level, so a typo must not silently become a
# default), lenient on the prose (trimmed and flattened rather than rejected).
#
# `jq -s ... .[0]` because a model that emits two concatenated JSON documents would
# otherwise make every later filter produce two values and turn each $( ) into a two-line
# string. Learned from post-review.sh.
# ---------------------------------------------------------------------------
if [ -z "$RISK_FILE" ] || [ ! -s "$RISK_FILE" ]; then
  echo "::warning::no judgment file at '${RISK_FILE}' — leaving any existing risk comment untouched."
  exit 0
fi

# A ```json fence around the object is tolerated: models add one habitually, and losing a
# good judgment to three backticks would look exactly like the model failing to answer.
# Prose around the JSON is still an error. (Same call classify-pr makes, for the same
# reason.)
NORMALISED=/tmp/_risk-judgment.json
sed -e 's/^[[:space:]]*```[A-Za-z]*[[:space:]]*$//' "$RISK_FILE" > "$NORMALISED" 2>/dev/null \
  || cp "$RISK_FILE" "$NORMALISED"

JUDGMENT="$(jq -s '
  if length == 0 then null else .[0] end
  | if type != "object" then null else . end
  | if . == null then null
    else
      # Flatten to a single line and cap the length. A newline inside a table cell breaks
      # the table; an unbounded reason turns a 3-second read into a paragraph.
      def clean($max): (. // "") | tostring | gsub("\\s*\n\\s*"; " ")
                       | .[0:$max] | sub("\\s+$"; "");
      # Table cells only. Escaping the pipe everywhere put literal backslashes into the
      # prose lines, which are not in a table — `ENV[...] || X` rendered as `ENV[...] \|\| X`.
      def cell($max): clean($max) | gsub("\\|"; "\\|");
      {
        blast:          (.blast_radius // ""),
        reversibility:  (.reversibility // ""),
        detectability:  (.detectability // ""),
        confidence:     (.confidence // "medium"),
        blast_why:      (.blast_reason | cell(200)),
        rev_why:        (.reversibility_reason | cell(200)),
        det_why:        (.detectability_reason | cell(200)),
        detail:         (.detail | clean(300)),
        where:          (.where_to_look | clean(400)),
        before:         (.before_merge | clean(300))
      }
      | select(
          (.blast         | IN("internal","feature","wide")) and
          (.reversibility | IN("revert-clean","needs-a-step","one-way")) and
          (.detectability | IN("immediate","delayed","metrics-only")) and
          (.confidence    | IN("high","medium","low"))
        )
    end' "$NORMALISED" 2>/dev/null)"

if [ -z "$JUDGMENT" ] || [ "$JUDGMENT" = "null" ]; then
  echo "::warning::judgment file is missing an axis or uses a value outside the allowed set — posting nothing."
  head -c 400 "$NORMALISED" >&2 2>/dev/null || true
  exit 0
fi

get() { printf '%s' "$JUDGMENT" | jq -r --arg k "$1" '.[$k] // ""'; }
BLAST="$(get blast)"; REV="$(get reversibility)"; DET="$(get detectability)"
CONF="$(get confidence)"
BLAST_WHY="$(get blast_why)"; REV_WHY="$(get rev_why)"; DET_WHY="$(get det_why)"
DETAIL="$(get detail)"; WHERE="$(get where)"; BEFORE="$(get before)"

# ---------------------------------------------------------------------------
# 2. The level.
# ---------------------------------------------------------------------------
LEVEL="medium"
if [ "$REV" = "one-way" ] \
   || { [ "$DET" = "metrics-only" ] && [ "$BLAST" != "internal" ]; } \
   || { [ "$BLAST" = "wide" ] && [ "$DET" = "delayed" ]; }; then
  LEVEL="high"
elif [ "$REV" = "revert-clean" ] && [ "$DET" = "immediate" ] && [ "$BLAST" != "wide" ]; then
  LEVEL="low"
fi

BUMPED=0
if [ "$CONF" = "low" ]; then
  case "$LEVEL" in
    low) LEVEL="medium"; BUMPED=1 ;;
    medium) LEVEL="high"; BUMPED=1 ;;
  esac
fi

case "$LEVEL" in
  low)    HEAD_EMOJI="🟢"; HEAD_NAME="Low risk";    ACTION="skim; approve on green CI." ;;
  medium) HEAD_EMOJI="🟡"; HEAD_NAME="Medium risk"; ACTION="read the hunks named below, not the whole diff." ;;
  high)   HEAD_EMOJI="🔴"; HEAD_NAME="High risk";   ACTION="read line-by-line, and settle the rollback story before merge." ;;
esac

emoji_for() {
  case "$1" in
    internal|revert-clean|immediate) printf '🟢' ;;
    feature|needs-a-step|delayed)    printf '🟡' ;;
    *)                               printf '🔴' ;;
  esac
}

# ---------------------------------------------------------------------------
# 3. Render.
#
# Low gets two lines and no table. A three-row table on a locale-only PR is exactly the
# noise the backend reviewer was rewritten to stop producing, and most PRs are Low.
# ---------------------------------------------------------------------------
BODY="${MARKER}
${HEAD_EMOJI} **${HEAD_NAME}** — ${ACTION}"

[ -n "$DETAIL" ] && BODY="${BODY}

${DETAIL}"

if [ "$LEVEL" != "low" ]; then
  BODY="${BODY}

|  |  |  |
|---|---|---|
| **Blast radius** | $(emoji_for "$BLAST") ${BLAST} | ${BLAST_WHY} |
| **Reversibility** | $(emoji_for "$REV") ${REV} | ${REV_WHY} |
| **Detectability** | $(emoji_for "$DET") ${DET} | ${DET_WHY} |"

  [ -n "$WHERE" ] && BODY="${BODY}

**Where to look** — ${WHERE}"
  [ -n "$BEFORE" ] && BODY="${BODY}
**Before merge** — ${BEFORE}"
fi

if [ "$BUMPED" -eq 1 ]; then
  BODY="${BODY}

<sub>⬆︎ Raised one level: the judgment was low-confidence, so this errs toward more scrutiny.</sub>"
fi

BODY="${BODY}

<sub>Risk triage for \`${SHORT_SHA}\` — what breaks if this is wrong, not whether the code is right. Bugs are the reviewer bot's job, not this comment's.</sub>"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "--- level: ${LEVEL} (blast=${BLAST} reversibility=${REV} detectability=${DET} confidence=${CONF} bumped=${BUMPED}) ---"
  echo "$BODY"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Upsert the one sticky comment.
#
# Edited in place on every push. A comment edit sends no notification, so refreshing the
# level costs the author nothing — while a new comment per push would be the exact noise
# pattern this team already removed once.
#
# Author-scoped like post-review.sh: the marker alone also matches a human who quoted the
# comment in a reply, and this token can edit anyone's comment.
# ---------------------------------------------------------------------------
if ! LIST="$(gh api --paginate "repos/${REPO}/issues/${PR}/comments" 2>/tmp/_risk-list-err)"; then
  # Never fall through to POST on a failed listing: that creates a SECOND sticky, and then
  # does it again on every push. Skipping one update is the smaller harm.
  echo "::warning::could not list PR comments; leaving the risk comment untouched this run."
  sed 's/^/    /' /tmp/_risk-list-err >&2 || true
  exit 0
fi

EXISTING_ID="$(printf '%s' "$LIST" | jq -r --arg m "$MARKER" \
  'if type == "array" then .[] else . end
   | select(.user.type == "Bot")
   | select((.body // "") | contains($m))
   | .id' 2>/dev/null | head -n 1 || true)"

if [ -n "$EXISTING_ID" ]; then
  gh api --method PATCH "repos/${REPO}/issues/comments/${EXISTING_ID}" -f body="$BODY" >/dev/null 2>&1 \
    && echo "Updated risk comment ${EXISTING_ID}: ${LEVEL}." \
    || echo "::warning::could not update risk comment ${EXISTING_ID}."
else
  gh api --method POST "repos/${REPO}/issues/${PR}/comments" -f body="$BODY" >/dev/null 2>&1 \
    && echo "Posted risk comment: ${LEVEL}." \
    || echo "::warning::could not post risk comment."
fi
