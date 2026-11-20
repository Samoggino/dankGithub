#!/usr/bin/env bash
# Prints every page of the repo list as JSON, one page per line block, separated by "@@PAGE@@".
# On failure prints "ERR:<reason>". The token is looked up in this order: $GH_TOKEN, the system
# keyring (Secret Service, stored by the plugin settings), `gh auth token`. It is passed to curl
# through stdin, so it never shows up in the process list.
tok="${GH_TOKEN:-}"
if [ -z "$tok" ] && command -v secret-tool >/dev/null 2>&1; then
    tok="$(secret-tool lookup service dankGithub account token 2>/dev/null)"
fi
if [ -z "$tok" ] && command -v gh >/dev/null 2>&1; then
    tok="$(gh auth token 2>/dev/null)"
fi
tok="$(printf '%s' "$tok" | tr -d '\r\n')"
if [ -n "${GH_USER:-}" ] && ! [[ "$GH_USER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]]; then
    echo "ERR:invalid GitHub username"
    exit 0
fi
if [ -n "$tok" ]; then
    base="https://api.github.com/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100"
elif [ -n "${GH_USER:-}" ]; then
    base="https://api.github.com/users/${GH_USER}/repos?type=owner&sort=pushed&per_page=100"
else
    base=""
fi
if [ -z "$base" ] && [ -z "${GH_EXTRA:-}" ]; then
    echo "ERR:no username or token configured"
    exit 0
fi

# GET helper: prints the body, returns the HTTP code in $code
gh_get() {
    local out
    if [ -n "$tok" ]; then
        out="$(printf 'Authorization: Bearer %s\n' "$tok" | curl -sS --max-time 20 -H @- -H 'Accept: application/vnd.github+json' -w '\n%{http_code}' "$1" 2>&1)"
    else
        out="$(curl -sS --max-time 20 -H 'Accept: application/vnd.github+json' -w '\n%{http_code}' "$1" 2>&1)"
    fi
    code="${out##*$'\n'}"
    body="${out%$'\n'*}"
}
if [ -n "$base" ]; then
    for page in $(seq 1 20); do
        gh_get "$base&page=$page"
        if [ "$code" != "200" ]; then
            case "$code" in
                401) echo "ERR:invalid token (401)" ;;
                403) echo "ERR:rate limited or forbidden (403)" ;;
                404) echo "ERR:user not found (404)" ;;
                *) echo "ERR:request failed (${code:-no response})" ;;
            esac
            exit 0
        fi
        compact="$(printf '%s' "$body" | tr -d '[:space:]')"
        [ "$compact" = "[]" ] && break
        printf '%s\n@@PAGE@@\n' "$body"
    done
fi

# Extra repositories added by hand ("owner/name", one per line): each is printed as a
# one-element page; the ones that cannot be fetched are listed in a final @@MISSING@@ line.
missing=""
while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    if ! [[ "$repo" =~ ^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$ ]]; then
        missing="$missing $repo"
        continue
    fi
    gh_get "https://api.github.com/repos/$repo"
    if [ "$code" = "200" ]; then
        printf '[%s]\n@@PAGE@@\n' "$body"
    else
        missing="$missing $repo"
    fi
done <<< "${GH_EXTRA:-}"
[ -n "$missing" ] && printf '@@MISSING@@%s\n' "$missing"
exit 0
