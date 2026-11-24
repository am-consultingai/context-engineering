#!/usr/bin/env bash
# One-time, interactive: create credentials for the experiment agents and store them in
# $AUTH = ~/.config/context-engineering/ (mode 600). Run this in your own terminal, not through a Claude session.
#
#   ./setup-token.sh            # generate a long-lived OAuth token with `claude setup-token`
#   ./setup-token.sh --api-key  # or paste an Anthropic API key instead
#
# Nothing is written to ~/.claude: setup-token runs with a throwaway config dir.
source "$(dirname "$0")/lib/common.sh"
mkdir -p "$AUTH"; chmod 700 "$AUTH"
[ -t 0 ] || die "run this in an interactive terminal"

if [ "${1:-}" = "--api-key" ]; then
  read -rsp "Paste API key: " key; echo
  [ -n "$key" ] || die "empty key"
  umask 077; printf '%s\n' "$key" > "$AUTH/api-key"; rm -f "$AUTH/oauth-token"
  ok "saved $AUTH/api-key"; exit 0
fi

tmpcfg="$(mktemp -d)"; trap 'rm -rf "$tmpcfg"' EXIT
log "Starting 'claude setup-token' (opens a browser login). Copy the token it prints."
env -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR="$tmpcfg" claude setup-token || die "setup-token failed"
echo
read -rsp "Paste the token here: " tok; echo
tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
[ -n "$tok" ] || die "empty token"
umask 077; printf '%s\n' "$tok" > "$AUTH/oauth-token"; rm -f "$AUTH/api-key"
ok "saved $AUTH/oauth-token. Next: ./setup.sh --verify"
