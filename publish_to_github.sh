#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   GITHUB_REPO="https://github.com/<user>/<repo>.git" ./publish_to_github.sh
# Optional:
#   BRANCH="work" REMOTE_NAME="origin" ./publish_to_github.sh

REMOTE_NAME="${REMOTE_NAME:-origin}"
BRANCH="${BRANCH:-$(git branch --show-current)}"
GITHUB_REPO="${GITHUB_REPO:-}"

if [[ -z "${GITHUB_REPO}" ]]; then
  echo "Errore: imposta GITHUB_REPO (es. https://github.com/<user>/<repo>.git)"
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Errore: non sei in una repository git"
  exit 1
fi

current_remote_url="$(git remote get-url "${REMOTE_NAME}" 2>/dev/null || true)"
if [[ -z "${current_remote_url}" ]]; then
  git remote add "${REMOTE_NAME}" "${GITHUB_REPO}"
  echo "Remote ${REMOTE_NAME} aggiunto: ${GITHUB_REPO}"
else
  echo "Remote ${REMOTE_NAME} già presente: ${current_remote_url}"
fi

echo "Push branch '${BRANCH}' su '${REMOTE_NAME}'..."
git push -u "${REMOTE_NAME}" "${BRANCH}"

echo "Fatto. Verifica:"
git remote -v
git log --oneline -n 3