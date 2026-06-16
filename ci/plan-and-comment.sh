#!/bin/sh
# plan-and-comment.sh
# Runs inside a Devtron Job (alpine container) auto-triggered by a GitHub
# Pull Request webhook. It:
#   1. runs `tofu plan` against the PR's checked-out Terraform, and
#   2. posts the plan output as a comment on the PR (via the GitHub API).
#
# No apply, ever. This is the read-only "plan-on-PR" half of Atlantis.
#
# Required env (injected by the Devtron task):
#   GH_TOKEN     - GitHub token allowed to comment on the PR repo
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

echo "==================== devtron/git env (debug) ===================="
# Helps us see exactly what Devtron injects for a webhook PR build.
env | sort | grep -iE 'git|webhook|^ci_|commit|branch|pull|comment|checkout|repo|sha' || true

# --- locate the repo checkout -------------------------------------------------
# Devtron mounts the PR head code at the task mount path; this script lives at
# <root>/ci/plan-and-comment.sh, so root is one level up. Do NOT rely on .git.
SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"
echo "repo root: $REPO_ROOT"

# --- determine the PR head SHA (best effort) ----------------------------------
HEAD_SHA=""
for v in "${GIT_COMMIT_HASH:-}" "${GIT_COMMIT:-}" "${CI_COMMIT:-}" "${WEBHOOK_SOURCE_CHECKOUT:-}"; do
  if [ -n "$v" ]; then HEAD_SHA="$v"; break; fi
done
# Devtron also exposes a CI_CD_EVENT JSON with gitTriggers in some builds.
if [ -z "$HEAD_SHA" ] && [ -n "${CI_CD_EVENT:-}" ]; then
  HEAD_SHA="$(printf %s "$CI_CD_EVENT" | jq -r '[.gitTriggers[]?.Commit, .gitTriggers[]?.WebhookData.Data["source checkout"]] | map(select(. != null and . != "")) | .[0] // empty' 2>/dev/null || true)"
fi
if [ -z "$HEAD_SHA" ] && git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
fi
echo "head sha: ${HEAD_SHA:-<unknown>}"

# --- run tofu plan ------------------------------------------------------------
echo "==================== tofu plan ===================="
cd "$REPO_ROOT/$TF_DIR"
tofu init -no-color -input=false

set +e
PLAN_OUTPUT="$(tofu plan -no-color -input=false -detailed-exitcode 2>&1)"
PLAN_RC=$?
set -e
echo "$PLAN_OUTPUT"
case "$PLAN_RC" in
  0) PLAN_STATUS="✅ No changes. Infrastructure matches the configuration." ;;
  2) PLAN_STATUS="📋 Changes detected (see plan). **Nothing is applied — plan only.**" ;;
  *) PLAN_STATUS="❌ \`tofu plan\` failed (exit $PLAN_RC)." ;;
esac

# --- resolve the PR -----------------------------------------------------------
echo "==================== resolve PR ===================="
PR_NUMBER=""
# 1) by commit -> associated PRs
if [ -n "$HEAD_SHA" ]; then
  PR_NUMBER="$(curl -sf -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "$API/repos/$GITHUB_REPO/commits/$HEAD_SHA/pulls" 2>/dev/null \
    | jq -r 'map(select(.state=="open")) | .[0].number // empty' 2>/dev/null || true)"
fi
# 2) by matching head sha among open PRs
if [ -z "$PR_NUMBER" ] && [ -n "$HEAD_SHA" ]; then
  PR_NUMBER="$(curl -sf -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "$API/repos/$GITHUB_REPO/pulls?state=open&per_page=50" 2>/dev/null \
    | jq -r --arg sha "$HEAD_SHA" 'map(select(.head.sha==$sha)) | .[0].number // empty' 2>/dev/null || true)"
fi
# 3) PoC fallback: if exactly one PR is open, comment on it
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER="$(curl -sf -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "$API/repos/$GITHUB_REPO/pulls?state=open&per_page=50" 2>/dev/null \
    | jq -r 'if length==1 then .[0].number else empty end' 2>/dev/null || true)"
  [ -n "$PR_NUMBER" ] && echo "NOTE: resolved PR by single-open-PR fallback."
fi

if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: could not resolve a PR (sha=${HEAD_SHA:-none}) — not commenting."
  exit 1
fi
echo "resolved PR: #$PR_NUMBER"

# --- build comment body (truncate defensively; GitHub caps at 65536) ----------
MAX=60000
if [ "$(printf %s "$PLAN_OUTPUT" | wc -c)" -gt "$MAX" ]; then
  PLAN_OUTPUT="$(printf %s "$PLAN_OUTPUT" | head -c "$MAX")
... (output truncated)"
fi

BODY="$(jq -Rs --arg status "$PLAN_STATUS" --arg sha "$HEAD_SHA" '
  "### ⚜️ tofu plan (via Devtron Job)\n\n" + $status + "\n\n" +
  "<details><summary>Show plan output</summary>\n\n```diff\n" + . + "\n```\n</details>\n\n" +
  "_commit `" + (if ($sha|length)>0 then $sha[0:12] else "unknown" end) +
  "` · plan-only, no apply — Atlantis-PoC_"
' <<EOF
$PLAN_OUTPUT
EOF
)"

# --- post the comment ---------------------------------------------------------
echo "==================== post comment ===================="
HTTP_CODE="$(curl -s -o /tmp/resp.json -w "%{http_code}" -X POST \
  -H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  "$API/repos/$GITHUB_REPO/issues/$PR_NUMBER/comments" \
  -d "{\"body\": $BODY}")"

echo "github response: $HTTP_CODE"
if [ "$HTTP_CODE" != "201" ]; then echo "ERROR posting comment:"; cat /tmp/resp.json; exit 1; fi
echo "✅ commented on PR #$PR_NUMBER: $(jq -r '.html_url' /tmp/resp.json)"
