# Is a comment body a `/risk` command? The ONE definition, shared by the workflow's gate job
# and fetch-risk-replies.sh, so a comment can never start a run and then be dropped as a
# reply, or the reverse.
#
# A command is a line that STARTS with `/risk`, ignoring leading spaces and case, like any
# slash command. A bare `contains("/risk")` matched our own footer ("Reply with `/risk` and
# the reason") whenever a person quoted the bot's comment, and that quote then re-ran the
# whole triage as if it were a reply. Seen on pic-collage-stickers#1750 and
# pic-collage-server#4565. A quoted line starts with `>` and an inline mention with a
# backtick, so neither is a line that starts with `/risk`.
def is_risk_command:
  (. // "")
  | gsub("\r"; "")
  | split("\n")
  | any(.[]; sub("^\\s+"; "") | ascii_downcase | test("^/risk([^a-z0-9_-]|$)"));
