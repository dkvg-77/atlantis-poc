#!/bin/sh
# apply-and-comment.sh
# Runs inside a Devtron Job (alpine) auto-triggered when `main` gets a new commit
# (i.e. a PR was merged). It:
#   1. runs `tofu apply -auto-approve` against the remote (GCS) state, and
#   2. posts the apply output as a comment on the PR that was just merged.
#
# Merge IS the approval gate (apply-on-merge). No comment-driven commands.
#
# Required env (injected by the Devtron task):
#   GH_TOKEN     - GitHub token allowed to comment on the repo
# Optional env:
#   GITHUB_REPO  - "owner/repo"     (default: dkvg-77/atlantis-poc)
#   TF_DIR       - tf dir from root (default: terraform)

set -eu

GITHUB_REPO="${GITHUB_REPO:-dkvg-77/atlantis-poc}"
TF_DIR="${TF_DIR:-terraform}"
API="https://api.github.com"

echo "==================== tooling ===================="
apk add --no-cache opentofu git curl jq >/dev/null 2>&1 || apk add --no-cache opentofu git curl jq
tofu version | head -1

echo "==================== env (debug) ===================="
env | sort | grep -iE 'git|webhook|^ci_|commit|branch|sha|repo' || true

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"

# --- merge commit SHA (best effort) -------------------------------------------
MERGE_SHA=""
for v in "${GIT_COMMIT_HASH:-}" "${GIT_COMMIT:-}" "${CI_COMMIT:-}"; do
  if [ -n "$v" ]; then MERGE_SHA="$v"; break; fi
done
if [ -z "$MERGE_SHA" ] && git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  MERGE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
fi
echo "merge sha: ${MERGE_SHA:-<unknown>}"

# --- tofu apply ---------------------------------------------------------------
echo "==================== tofu apply ===================="
cd "$REPO_ROOT/$TF_DIR"
tofu init -no-color -input=false

set +e
APPLY_OUTPUT="$(tofu apply -auto-approve -no-color -input=false 2>&1)"
APPLY_RC=$?
set -e
echo "$APPLY_OUTPUT"
if [ "$APPLY_RC" -eq 0 ]; then
  STATUS_EMOJI="✅"
else
  STATUS_EMOJI="❌ apply failed (exit $APPLY_RC)"
fi

# --- resolve the merged PR ----------------------------------------------------
echo "==================== resolve merged PR ===================="
PR_NUMBER=""
if [ -n "$MERGE_SHA" ]; then
  PR_NUMBER="$(curl -sf -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "$API/repos/$GITHUB_REPO/commits/$MERGE_SHA/pulls" 2>/dev/null \
    | jq -r 'sort_by(.merged_at // .updated_at) | reverse | .[0].number // empty' 2>/dev/null || true)"
fi
# Fallback: most recently merged PR.
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER="$(curl -sf -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "$API/repos/$GITHUB_REPO/pulls?state=closed&sort=updated&direction=desc&per_page=20" 2>/dev/null \
    | jq -r 'map(select(.merged_at != null)) | .[0].number // empty' 2>/dev/null || true)"
  [ -n "$PR_NUMBER" ] && echo "NOTE: resolved PR by most-recently-merged fallback."
fi
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: could not resolve merged PR (sha=${MERGE_SHA:-none}) — not commenting."
  exit "$APPLY_RC"
fi
echo "resolved merged PR: #$PR_NUMBER"

# --- build comment, Atlantis "Ran Apply" style --------------------------------
APPLY_COLORED="$(printf '%s\n' "$APPLY_OUTPUT" | sed -E 's/^([[:space:]]*)([+~-])/\2\1/')"
SUMMARY_LINE="$(printf '%s\n' "$APPLY_OUTPUT" | grep -E '^(Apply complete|No changes|Error:)' | head -1)"
[ -z "$SUMMARY_LINE" ] && SUMMARY_LINE="$STATUS_EMOJI apply finished"
HEADER="Ran Apply for dir: \`$TF_DIR\` workspace: \`default\`"

MAX=60000
if [ "$(printf %s "$APPLY_COLORED" | wc -c)" -gt "$MAX" ]; then
  APPLY_COLORED="$(printf %s "$APPLY_COLORED" | head -c "$MAX")
... (output truncated)"
fi

BODY="$(jq -Rs --arg header "$HEADER" --arg summary "$SUMMARY_LINE" \
               --arg sha "$MERGE_SHA" '
  $header + "\n\n" +
  "<details><summary>Show Output</summary>\n\n```diff\n" + . + "\n```\n</details>\n\n" +
  "**" + $summary + "**\n\n" +
  "_commit `" + (if ($sha|length)>0 then $sha[0:12] else "unknown" end) +
  "` · applied on merge to `main` — Atlantis-PoC (Devtron Job)_"
' <<EOF
$APPLY_COLORED
EOF
)"

echo "==================== post comment ===================="
HTTP_CODE="$(curl -s -o /tmp/resp.json -w "%{http_code}" -X POST \
  -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "$API/repos/$GITHUB_REPO/issues/$PR_NUMBER/comments" \
  -d "{\"body\": $BODY}")"
echo "github response: $HTTP_CODE"
if [ "$HTTP_CODE" != "201" ]; then echo "ERROR posting comment:"; cat /tmp/resp.json; exit 1; fi
echo "✅ commented apply result on PR #$PR_NUMBER: $(jq -r '.html_url' /tmp/resp.json)"
exit "$APPLY_RC"
