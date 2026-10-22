# Standard gate, sourced first by every scripts/check.sh:  . "$(dirname "$0")/gate.sh" "$@"
#   scripts/check.sh            hygiene, secret scan, the standard's own audit, then the project's checks
#   scripts/check.sh --report   same, then posts the result as the "check" commit status that branch
#                               protection requires before merging (needs gh, a clean tree, HEAD
#                               pushed to GitHub, and the standard's audit)
# Identical in every project: copy it from asieke/workspace templates/common/scripts/gate.sh; do not edit.
# check.sh must not set its own EXIT trap: --report uses it to post the result.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
gate_report=; [ "${1:-}" != --report ] || gate_report=1

if [ -n "$gate_report" ]; then
  [ -z "$(git status --porcelain)" ] || { echo "check: --report needs a clean tree" >&2; exit 1; }
  gate_sha=$(git rev-parse HEAD)
  gate_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || { echo "check: --report needs gh signed in to GitHub" >&2; exit 1; }
  gh api "repos/$gate_repo/commits/$gate_sha" --silent 2>/dev/null || { echo "check: --report needs ${gate_sha:0:7} pushed to GitHub first" >&2; exit 1; }
  gate_post() {
    if gh api -X POST "repos/$gate_repo/statuses/$gate_sha" -f state="$1" -f context=check -f description="$2" --silent; then
      echo "check: reported $1 for ${gate_sha:0:7}"
    else
      echo "check: could not report $1 for ${gate_sha:0:7}" >&2
    fi
  }
  trap 'rc=$?; if [ $rc -eq 0 ]; then gate_post success "scripts/check.sh passed on $(hostname -s)"; else gate_post failure "scripts/check.sh failed on $(hostname -s)"; fi; exit $rc' EXIT
fi

if git grep -nE '^(<{7}|={7}|>{7})( |$)' -- . ':(exclude)*scripts/gate.sh'; then
  echo "merge conflict markers found" >&2; exit 1
fi
if git grep -nE 'BEGIN [A-Z0-9 ]*PRIVATE KEY' -- . ':(exclude)*scripts/gate.sh'; then
  echo "private key found" >&2; exit 1
fi
while IFS= read -r f; do
  [ -f "$f" ] && [ "$(wc -c <"$f")" -gt 25600000 ] && { echo "file over 25 MB: $f" >&2; exit 1; }
done < <(git ls-files)

# Secret scan of every commit not yet on origin/main. Put false positives in .gitleaksignore.
gate_gitleaks() {
  command -v gitleaks && return
  local ver=8.21.2 os sum dir
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)              os=linux_x64    sum=5bc41815076e6ed6ef8fbecc9d9b75bcae31f39029ceb55da08086315316e3ba;;
    Linux-aarch64|Linux-arm64) os=linux_arm64  sum=654c935542c89f565aabe7bf7c6c500830f116c114f0aeb509d2460c1ac2e6da;;
    Darwin-arm64)              os=darwin_arm64 sum=cad3de5dc9a4d5447d967a70a4d49499c557f04db028274cc324f9ff983f6502;;
    Darwin-x86_64)             os=darwin_x64   sum=5b42c6e4b1fd693eaeb2b5b7faa5f17a1434299d4deb2de63d4b2efd7c753128;;
    *) return 1;;
  esac
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/gitleaks-$ver"
  if [ ! -x "$dir/gitleaks" ]; then
    mkdir -p "$dir" || return 1
    curl -sSfL -o "$dir/gitleaks.tar.gz" "https://github.com/gitleaks/gitleaks/releases/download/v$ver/gitleaks_${ver}_$os.tar.gz" || return 1
    [ "$( (sha256sum "$dir/gitleaks.tar.gz" 2>/dev/null || shasum -a 256 "$dir/gitleaks.tar.gz") | cut -d' ' -f1)" = "$sum" ] \
      || { rm -f "$dir/gitleaks.tar.gz"; echo "check: gitleaks download failed its checksum" >&2; return 1; }
    tar -xzf "$dir/gitleaks.tar.gz" -C "$dir" gitleaks && rm -f "$dir/gitleaks.tar.gz" || return 1
  fi
  echo "$dir/gitleaks"
}
gate_range=HEAD; git rev-parse --verify -q origin/main >/dev/null && gate_range=origin/main..HEAD
if gate_gl=$(gate_gitleaks); then
  "$gate_gl" git --redact --no-banner --log-level=warn --log-opts="$gate_range" . \
    || { echo "check: gitleaks found secrets in $gate_range (false positives go in .gitleaksignore)" >&2; exit 1; }
elif [ -n "$gate_report" ]; then
  echo "check: could not get gitleaks, and --report requires the secret scan" >&2; exit 1
else
  echo "check: WARNING: could not get gitleaks; secret scan skipped (--report will require it)" >&2
fi

# The standard's own audit of this checkout (scripts/audit.sh --gate from asieke/workspace's newest main,
# kept per commit in the cache), so everything that merges meets the version of the standard that
# PROJECT.md names. Any FAIL fails the check; a requirement that a newer version added waits until the
# project's standard reaches it. asieke/workspace audits itself with its own copy.
gate_standard() {
  local sha dir tmp
  if [ -x scripts/audit.sh ] && [ -f templates/common/scripts/gate.sh ]; then pwd; return; fi
  # asieke/workspace's tests point GATE_WORKSPACE at their copy; --report always uses the real standard.
  if [ -n "${GATE_WORKSPACE:-}" ] && [ -z "$gate_report" ]; then echo "$GATE_WORKSPACE"; return; fi
  # Never stop to ask for a login: without one, the fetch just fails.
  export GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0
  sha=$(gh api repos/asieke/workspace/commits/main -H 'Accept: application/vnd.github.sha' 2>/dev/null) \
    || sha=$(git ls-remote https://github.com/asieke/workspace.git refs/heads/main 2>/dev/null | cut -f1)
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/asieke-workspace/$sha"
  if [ ! -x "$dir/scripts/audit.sh" ]; then
    tmp=$(mktemp -d) || return 1
    if { gh repo clone asieke/workspace "$tmp/w" -- --quiet --depth 1 || git clone --quiet --depth 1 https://github.com/asieke/workspace.git "$tmp/w"; } </dev/null >/dev/null 2>&1; then
      sha=$(git -C "$tmp/w" rev-parse HEAD); dir="${dir%/*}/$sha"
      mkdir -p "${dir%/*}" && { [ -e "$dir" ] || mv "$tmp/w" "$dir"; }
      # Drop the copies of older commits.
      find "${dir%/*}" -mindepth 1 -maxdepth 1 -type d ! -name "$sha" -mtime +7 -exec rm -rf {} + 2>/dev/null || :
    fi
    rm -rf "$tmp"
    [ -x "$dir/scripts/audit.sh" ] || return 1
  fi
  echo "$dir"
}
if gate_wow=$(gate_standard); then
  gate_out=$("$gate_wow/scripts/audit.sh" --gate .) \
    || { printf '%s\n' "$gate_out" >&2; echo "check: the standard's audit failed: fix each FAIL above (STANDARD.md in asieke/workspace says what it requires)" >&2; exit 1; }
  gate_warns=$(grep -c '^WARN' <<<"$gate_out" || :)
  echo "check: the standard's audit passed (asieke/workspace at $(git -C "$gate_wow" rev-parse --short HEAD 2>/dev/null || echo "an unknown commit")$([ "$gate_warns" = 0 ] || echo ", $gate_warns warning(s): its scripts/audit.sh lists them"))" >&2
elif [ -n "$gate_report" ]; then
  echo "check: could not get the standard's audit from asieke/workspace, and --report requires it" >&2; exit 1
else
  echo "check: WARNING: could not get the standard's audit from asieke/workspace; skipped (--report will require it)" >&2
fi
