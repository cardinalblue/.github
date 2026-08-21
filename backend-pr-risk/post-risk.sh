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
# ADJUSTMENT HISTORY. When a `/risk` reply moves an axis, the table shows the new value and
# a `> [!NOTE]` block at the end records what moved and why. The history ACCUMULATES across
# runs, so the comment carries both the conclusion and how it got there — and nobody has to
# read the thread to find out.
#
# That history is never parsed back out of the rendered markdown. Each run writes a hidden,
# base64-encoded state blob into the comment and reads it on the next run. Parsing our own
# prose would break the first time a reason contained a pipe or a newline.
#
# Never fails the caller, and never posts a level it did not compute — a missing or
# malformed judgment leaves the previous comment untouched and says so in the log. "Risk
# unknown" is not a thing this bot says.
set -uo pipefail

REPO="" PR="" SHA="" RISK_FILE="" REPLIES_FILE="" PRIOR_BODY_FILE="" DRY_RUN=0 MAX_NOTES=5
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift ;;
    --pr) PR="$2"; shift ;;
    --sha) SHA="$2"; shift ;;
    --risk-file) RISK_FILE="$2"; shift ;;
    --replies-file) REPLIES_FILE="$2"; shift ;;
    # Test hook: read the previous comment from a file instead of the API, so the whole
    # adjustment path can be exercised with --dry-run and no network.
    --prior-body-file) PRIOR_BODY_FILE="$2"; shift ;;
    --max-notes) MAX_NOTES="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$REPO" ] && [ -n "$PR" ] || { echo "--repo and --pr required" >&2; exit 2; }

case "$MAX_NOTES" in
  ''|*[!0-9]*) echo "::warning::--max-notes '${MAX_NOTES}' is not a number; using 5."; MAX_NOTES=5 ;;
esac

MARKER='<!-- cb-pr-risk:summary -->'
STATE_PREFIX='<!-- cb-pr-risk:state '
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
        before:         (.before_merge | clean(300)),
        # Why an axis moved. The SCRIPT decides what moved, by comparing state; the model
        # only explains it. A model that claims an adjustment which did not happen gets it
        # dropped — the history has to be true even when the judgment is wrong.
        adjustments:    ( [ (.adjustments // [])[]
                            | select(type == "object")
                            | { axis: ((.axis // "") | tostring),
                                why: (.why | clean(260)),
                                source_url: (((.source_url // "") | tostring)[0:300]) } ] )
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
ADJUSTMENTS="$(printf '%s' "$JUDGMENT" | jq -c '.adjustments // []')"

REPLY_COUNT=0
if [ -n "$REPLIES_FILE" ] && [ -s "$REPLIES_FILE" ]; then
  REPLY_COUNT="$(jq 'length' "$REPLIES_FILE" 2>/dev/null || echo 0)"
fi

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
# 3. Find the existing comment and recover the previous state.
#
# Done BEFORE rendering, because the note block is built by comparing this run's values
# with the last run's, and because the accumulated history lives in that comment.
# ---------------------------------------------------------------------------
EXISTING_ID=""
PRIOR_BODY=""
if [ -n "$PRIOR_BODY_FILE" ] && [ -f "$PRIOR_BODY_FILE" ]; then
  PRIOR_BODY="$(cat "$PRIOR_BODY_FILE")"
elif [ "$DRY_RUN" -eq 0 ]; then
  if ! LIST="$(gh api --paginate "repos/${REPO}/issues/${PR}/comments" 2>/tmp/_risk-list-err)"; then
    # Never fall through to POST on a failed listing: that creates a SECOND sticky, and
    # then does it again on every push. Skipping one update is the smaller harm.
    echo "::warning::could not list PR comments; leaving the risk comment untouched this run."
    sed 's/^/    /' /tmp/_risk-list-err >&2 || true
    exit 0
  fi
  # Author-scoped: the marker alone would also match a human who quoted the comment in a
  # reply, and this token can edit anyone's comment.
  EXISTING="$(printf '%s' "$LIST" | jq -c --arg m "$MARKER" \
    '[ (if type == "array" then .[] else . end)
       | select(.user.type == "Bot")
       | select((.body // "") | contains($m)) ] | .[0] // {}' 2>/dev/null || echo '{}')"
  EXISTING_ID="$(printf '%s' "$EXISTING" | jq -r '.id // ""')"
  PRIOR_BODY="$(printf '%s' "$EXISTING" | jq -r '.body // ""')"
fi

# The hidden state blob, base64 so a reason containing `-->` or a newline can neither
# corrupt the comment nor break the next parse.
PRIOR_STATE='{}'
if [ -n "$PRIOR_BODY" ]; then
  ENCODED="$(printf '%s' "$PRIOR_BODY" | grep -o "${STATE_PREFIX}[A-Za-z0-9+/=]*" | tail -n 1 | sed "s|${STATE_PREFIX}||" || true)"
  if [ -n "${ENCODED:-}" ]; then
    DECODED="$(printf '%s' "$ENCODED" | base64 --decode 2>/dev/null || true)"
    if [ -n "$DECODED" ] && printf '%s' "$DECODED" | jq -e 'type == "object"' >/dev/null 2>&1; then
      PRIOR_STATE="$DECODED"
    fi
  fi
fi

pget() { printf '%s' "$PRIOR_STATE" | jq -r --arg k "$1" '.[$k] // ""'; }
PRIOR_LEVEL="$(pget level)"
PRIOR_BLAST="$(pget blast)"; PRIOR_REV="$(pget reversibility)"; PRIOR_DET="$(pget detectability)"
PRIOR_HAD_BEFORE="$(pget had_before)"
PRIOR_NOTES="$(printf '%s' "$PRIOR_STATE" | jq -c '.notes // []' 2>/dev/null || echo '[]')"

# ---------------------------------------------------------------------------
# 4. Build the new note lines.
#
# Only when a `/risk` reply exists. A level that moves because the CODE changed is already
# visible in the diff and needs no note; a level that moves because a person said something
# does — that is the context the team asked not to lose.
# ---------------------------------------------------------------------------
NEW_NOTES='[]'
if [ "$REPLY_COUNT" -gt 0 ] && [ -n "$PRIOR_LEVEL" ]; then
  NEW_NOTES="$(jq -n \
    --argjson adj "$ADJUSTMENTS" \
    --arg pl "$PRIOR_LEVEL" --arg nl "$LEVEL" \
    --arg pb "$PRIOR_BLAST" --arg nb "$BLAST" \
    --arg prev "$PRIOR_REV" --arg nr "$REV" \
    --arg pd "$PRIOR_DET" --arg nd "$DET" \
    --arg phb "$PRIOR_HAD_BEFORE" --arg nbefore "$BEFORE" '
    # `label` is a jq keyword — naming this def `label` fails to compile, and the guarded
    # fallback then silently produced a note with no structure. Verified before shipping.
    def axis_name($axis): {blast_radius:"Blast radius", reversibility:"Reversibility",
                       detectability:"Detectability", before_merge:"Before merge"}[$axis] // $axis;
    def emoji($v): if ($v | IN("internal","revert-clean","immediate")) then "🟢"
                   elif ($v | IN("feature","needs-a-step","delayed")) then "🟡" else "🔴" end;
    def why($axis): ([ $adj[] | select(.axis == $axis) | .why ] | map(select(. != "")) | .[0] // "");
    def src($axis): ([ $adj[] | select(.axis == $axis) | .source_url ]
                     | map(select(startswith("http"))) | .[0] // "");
    def link($axis): (src($axis) | if . == "" then "" else " ([reply](\(.)))" end);
    def moved($axis; $from; $to):
      if $from == "" or $from == $to then empty
      else "**\(axis_name($axis))** \(emoji($from)) `\($from)` → \(emoji($to)) `\($to)`"
           + (why($axis) | if . == "" then "." else " — \(.)" end)
           + link($axis)
      end;
    def rank($l): {low:0, medium:1, high:2}[$l] // -1;

    [ moved("blast_radius";  $pb;   $nb),
      moved("reversibility"; $prev; $nr),
      moved("detectability"; $pd;   $nd),
      ( if $phb == "yes" and $nbefore == "" then
          "**Before merge** cleared"
          + (why("before_merge") | if . == "" then "." else " — \(.)" end)
          + link("before_merge")
        else empty end )
    ]
    | if length > 0 and $pl != $nl then
        [ (if rank($nl) < rank($pl) then "Risk lowered" else "Risk raised" end)
          + " from **\($pl)** to **\($nl)**." ] + .
      else . end' 2>/dev/null || echo '[]')"

  # A reply arrived and nothing moved. Say so ONCE, rather than leaving the reader to
  # wonder whether the bot read it — but only while the note block is still empty. Every
  # later push re-reads the same replies and moves nothing, so without the guard this line
  # was appended again on each one until it filled the block.
  if [ "$(printf '%s' "$NEW_NOTES" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ] \
     && [ "$(printf '%s' "$PRIOR_NOTES" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
    NEW_NOTES="$(jq -n --argjson adj "$ADJUSTMENTS" '
      [ $adj[]
        | select(.why != "")
        | .why + (.source_url | if startswith("http") then " ([reply](\(.)))" else "" end) ]
      | .[0:1]
      | if length == 0 then ["A `/risk` reply was read; it does not move any axis."] else . end' \
      2>/dev/null || echo '[]')"
  fi
fi

NOTES="$(jq -n --argjson old "$PRIOR_NOTES" --argjson new "$NEW_NOTES" --argjson max "$MAX_NOTES" \
  '($old + ($new - $old)) | .[-$max:]' 2>/dev/null || echo '[]')"

# ---------------------------------------------------------------------------
# 5. Render.
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

# The adjustment history, oldest first. It stays on the comment for the life of the PR, so
# the conclusion AND how it got there are both in the one thing a reviewer reads.
if [ "$(printf '%s' "$NOTES" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
  NOTE_LINES="$(printf '%s' "$NOTES" | jq -r '.[] | "> \(.)\n>"')"
  BODY="${BODY}

> [!NOTE]
> Adjusted after a \`/risk\` reply:
>
${NOTE_LINES}"
fi

BODY="${BODY}

<sub>Risk triage for \`${SHORT_SHA}\` — what breaks if this is wrong, not whether the code is right. Bugs are the reviewer bot's job, not this comment's. Disagree? Reply with \`/risk\` and the reason, and this comment is re-evaluated.</sub>"

# The state this run hands to the next one.
HAD_BEFORE="no"; [ -n "$BEFORE" ] && HAD_BEFORE="yes"
STATE_B64="$(jq -cn --arg l "$LEVEL" --arg b "$BLAST" --arg r "$REV" --arg d "$DET" \
  --arg hb "$HAD_BEFORE" --argjson n "$NOTES" \
  '{level:$l, blast:$b, reversibility:$r, detectability:$d, had_before:$hb, notes:$n}' \
  | base64 | tr -d '\n')"
BODY="${BODY}
${STATE_PREFIX}${STATE_B64} -->"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "--- level: ${LEVEL} (blast=${BLAST} reversibility=${REV} detectability=${DET} confidence=${CONF} bumped=${BUMPED} replies=${REPLY_COUNT} prior=${PRIOR_LEVEL:-none}) ---"
  echo "$BODY"
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Upsert the one sticky comment.
#
# Edited in place on every run. A comment edit sends no notification, so refreshing the
# level costs the author nothing — while a new comment per push would be the exact noise
# pattern this team already removed once.
# ---------------------------------------------------------------------------
if [ -n "$EXISTING_ID" ]; then
  gh api --method PATCH "repos/${REPO}/issues/comments/${EXISTING_ID}" -f body="$BODY" >/dev/null 2>&1 \
    && echo "Updated risk comment ${EXISTING_ID}: ${LEVEL} (was ${PRIOR_LEVEL:-none}; ${REPLY_COUNT} /risk reply(ies))." \
    || echo "::warning::could not update risk comment ${EXISTING_ID}."
else
  gh api --method POST "repos/${REPO}/issues/${PR}/comments" -f body="$BODY" >/dev/null 2>&1 \
    && echo "Posted risk comment: ${LEVEL}." \
    || echo "::warning::could not post risk comment."
fi
