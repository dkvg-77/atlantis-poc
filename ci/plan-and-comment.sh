#!/bin/sh
# plan-and-comment.sh
# Runs inside a Devtron Job (alpine container) that is auto-triggered by a
# GitHub Pull Request webhook. It:
#   1. runs `tofu plan` against the PR's checked-out Terraform, and
#   2. posts the plan output as a comment on the PR (via the GitHub API).
#
# No apply, ever. This is the read-only "plan-on-PR" half of Atlantis.
#
# Required env (injected by the Devtron task):
#   GH_TOKEN     - GitHub token with permission to comment on the PR repo
# Optional env:
#   GITHUB_REPO  - "owner/repo" (default: dkvg-77/atlantis-poc)
#   TF_DIR       - terraform dir relative to repo root (default: terraform)

set -eu

GITHUB_REPO="${GITHUB_REPO:-dkvg-77/atlantis-poc}"
TF_DIR="${TF_DIR:-terraform}"
API="https://api.github.com"

echo "==================== tooling ===================="
apk add --no-cache opentofu git curl jq >/dev/null 2>&1 || apk add --no-cache opentofu git curl jq
tofu version

echo "==================== devtron / git env (debug) ===================="
env | sort | grep -iE 'git|webhook|^ci_|commit|branch|pull|comment|checkout|repo' || true

# --- locate the repo checkout (Devtron mounts the PR head here) ----------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
echo "repo root: $REPO_ROOT"
cd "$REPO_ROOT"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"
echo "head sha: $HEAD_SHA"

# --- run tofu plan -------------------------------------------------------------
echo "==================== tofu plan ===================="
cd "$REPO_ROOT/$TF_DIR"
tofu init -no-color -input=false

set +e
PLAN_OUTPUT="$(tofu plan -no-color -input=false -detailed-exitcode 2>&1)"
PLAN_RC=$?
set -e
echo "$PLAN_OUTPUT"
# detailed-exitcode: 0 = no changes, 2 = changes present, 1 = error
case "$PLAN_RC" in
  0) PLAN_STATUS="✅ No changes. Infrastructure is up to date." ;;
  2) PLAN_STATUS="📋 Changes detected (see plan above). **Nothing is applied — this is plan-only.**" ;;
  *) PLAN_STATUS="❌ \`tofu plan\` failed (exit $PLAN_RC)." ;;
esac

# --- find the PR this commit belongs to ----------------------------------------
echo "==================== resolve PR ===================="
PR_NUMBER=""
if [ -n "$HEAD_SHA" ]; then
  PR_NUMBER="$(curl -sf -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$API/repos/$GITHUB_REPO/commits/$HEAD_SHA/pulls" 2>/dev/null \
    | jq -r 'map(select(.state=="open")) | .[0].number // empty')"
fi
# Fallback: newest open PR whose head sha matches.
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER="$(curl -sf -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$API/repos/$GITHUB_REPO/pulls?state=open&sort=updated&direction=desc&per_page=20" 2>/dev/null \
    | jq -r --arg sha "$HEAD_SHA" 'map(select(.head.sha==$sha)) | .[0].number // empty')"
fi

if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: could not resolve an open PR for sha $HEAD_SHA — not commenting."
  exit 1
fi
echo "resolved PR: #$PR_NUMBER"

# --- build the comment body ----------------------------------------------------
# GitHub comments cap at 65536 chars; truncate the plan defensively.
MAX=60000
if [ "$(printf %s "$PLAN_OUTPUT" | wc -c)" -gt "$MAX" ]; then
  PLAN_OUTPUT="$(printf %s "$PLAN_OUTPUT" | head -c "$MAX")
... (truncated)"
fi

BODY="$(jq -Rs --arg status "$PLAN_STATUS" --arg sha "$HEAD_SHA" '
  "### ⚜️ tofu plan (via Devtron Job)\n\n" +
  $status + "\n\n" +
  "<details><summary>Show plan output</summary>\n\n```diff\n" + . + "\n```\n</details>\n\n" +
  "_commit `" + ($sha | .[0:12]) + "` · plan-only, no apply — Atlantis-PoC_"
' <<EOF
$PLAN_OUTPUT
EOF
)"

# --- post the comment ----------------------------------------------------------
echo "==================== post comment ===================="
HTTP_CODE="$(curl -s -o /tmp/resp.json -w "%{http_code}" \
  -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "$API/repos/$GITHUB_REPO/issues/$PR_NUMBER/comments" \
  -d "{\"body\": $BODY}")"

echo "github response: $HTTP_CODE"
if [ "$HTTP_CODE" != "201" ]; then
  echo "ERROR posting comment:"; cat /tmp/resp.json; exit 1
fi
echo "✅ commented on PR #$PR_NUMBER: $(jq -r '.html_url' /tmp/resp.json)"
