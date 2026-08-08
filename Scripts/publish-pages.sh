#!/usr/bin/env bash
set -euo pipefail

# Publish only the de-identified site payload to the dedicated public Pages repository.
# The private source repository cannot host Pages on every GitHub plan, and copying the
# whole worktree would disclose source. This script uses an explicit public-file layout.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="$ROOT/site"
PAGES_REPOSITORY="${LAUNCHAGAIN_PAGES_REPOSITORY:-odonnellmatt/LaunchAgain-site}"

for tool in git gh; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required tool not found: $tool" >&2
    exit 1
  }
done

if find "$SITE" -type l -print -quit | grep -q .; then
  echo "error: site/ must not contain symbolic links" >&2
  exit 1
fi

if [ "$(gh repo view "$PAGES_REPOSITORY" --json isPrivate --jq .isPrivate)" != "false" ]; then
  echo "error: Pages repository is missing or is not public: $PAGES_REPOSITORY" >&2
  exit 1
fi

publish_root="$(mktemp -d "${TMPDIR:-/tmp}/launchagain-pages.XXXXXX")"
cleanup() { /usr/bin/trash "$publish_root" >/dev/null 2>&1 || true; }
trap cleanup EXIT

git clone --quiet "https://github.com/$PAGES_REPOSITORY.git" "$publish_root/repository"
destination="$publish_root/repository"

(
  cd "$destination"
  git rm -r --ignore-unmatch --quiet -- .
  mkdir -p public .github/workflows
  find "$SITE" -maxdepth 1 -type f ! -name README.md -exec cp {} public/ \;
  cp "$SITE/README.md" README.md
  cp "$SITE/.github/workflows/pages.yml" .github/workflows/pages.yml
  git add -A

  if git diff --cached --quiet; then
    echo "Pages site is already current."
    exit 0
  fi

  version="$(sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' "$ROOT/CHANGELOG.md" | head -1)"
  git -c user.name='LaunchAgain Maintainers' \
      -c user.email='maintainers@users.noreply.github.com' \
      commit --quiet -m "Publish LaunchAgain documentation ${version:-update}"
  git push origin HEAD:main
)
