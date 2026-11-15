#!/bin/bash
# A scripted stand-in for an agent CLI, for filming heed. It prints what an agent prints and reports its state to
# heed through the same hooks claude's settings would run (`heed hook claude <Event>`, JSON on stdin), so heed shows
# working, blocked on a permission (the approvals queue, answered with its real decision), asking and done.
#
#   demo-agent.sh "<prompt>"
#
# Run it as heed's agent (world.sh writes the config: [agents.demo]) or by hand inside a heed pane.
# DEMO_SPEED=0.5 plays twice as fast, DEMO_SPEED=0 with no pauses (tests). macOS bash 3.2 safe.
set -u
PROMPT="${1:-Fix the broken anchors in the docs}"
SPEED="${DEMO_SPEED:-1}"
SID="demo-$$"
CWD="$(pwd)"
HEED="${HEED_BIN:-heed}"
DEMO_ROOT="${DEMO_ROOT:-/tmp/heed-demo}"
PR_URL="https://github.com/acme/docs-toolkit/pull/42"

pause() { sleep "$(awk -v s="$1" -v k="$SPEED" 'BEGIN { printf "%.2f", s * k }')"; }

# Types text the way a model streams it.
say() {
  local text="$1" i
  for ((i = 0; i < ${#text}; i++)); do
    printf '%s' "${text:i:1}"
    [ "$SPEED" = 0 ] || sleep "$(awk -v k="$SPEED" 'BEGIN { printf "%.3f", 0.012 * k }')"
  done
  printf '\n'
}

# json-escape a string for the hook payloads
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS="\\n"} {print}' | sed 's/\\n$//'; }

# hook <Event> [extra json members, with a leading comma]
hook() {
  local event="$1" extra="${2:-}"
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"%s"%s}' "$SID" "$CWD" "$event" "$extra" \
    | "$HEED" hook claude "$event" 2>/dev/null
}

tool_use() { # <Tool> <input json> <label shown> <seconds>
  hook PreToolUse ",\"tool_name\":\"$1\",\"tool_input\":$2"
  printf '\n\033[1;32m●\033[0m \033[1m%s\033[0m\n' "$3"
  pause "$4"
  hook PostToolUse ",\"tool_name\":\"$1\",\"tool_input\":$2,\"tool_response\":{}"
}

# A permission the agent must be given: heed's hook sends it to the approvals queue (gy) and prints the decision.
ask() { # <Tool> <input json> <label shown> <description>
  local payload answer
  payload=",\"permission_mode\":\"default\",\"tool_name\":\"$1\",\"tool_input\":$2"
  hook PreToolUse ",\"tool_name\":\"$1\",\"tool_input\":$2"
  printf '\n\033[1;33m●\033[0m \033[1m%s\033[0m\n' "$3"
  printf '  \033[33m⏸ waiting for permission: %s\033[0m\n' "$4"
  answer="$(hook PermissionRequest "$payload")"
  case "$answer" in
    *'"behavior":"allow"'*)
      printf '  \033[32m✓ allowed\033[0m\n'; pause 0.6
      hook PostToolUse ",\"tool_name\":\"$1\",\"tool_input\":$2,\"tool_response\":{}"
      return 0 ;;
    *'"behavior":"deny"'*)
      printf '  \033[31m✗ denied\033[0m\n'; return 1 ;;
    *)
      # heed passed (not running, timed out): a real agent would ask here
      printf '  Allow? [y/N] '; local reply; read -r reply
      case "$reply" in y | Y) return 0 ;; *) return 1 ;; esac ;;
  esac
}

finish() { # <last words>
  printf '\n'; say "$1"
  hook Stop ",\"last_assistant_message\":\"$(esc "$1")\""
}

turn() { # <prompt>
  hook UserPromptSubmit ",\"prompt\":\"$(esc "$1")\""
  printf '\n'
  pause 0.8
  say "I'll start by finding where the anchors are defined."
  tool_use Grep '{"pattern":"#getting-started","path":"docs"}' 'Grep("#getting-started", docs)' 1.2
  tool_use Read '{"file_path":"docs/guide/install.md"}' 'Read(docs/guide/install.md)' 1
  say "Three links point at an anchor that was renamed. Fixing them."
  tool_use Edit '{"file_path":"docs/guide/install.md","old_string":"#getting-started","new_string":"#get-started"}' \
    'Update(docs/guide/install.md)' 1.2
  if ask Bash '{"command":"git push -u origin fix/broken-anchors","description":"Push the branch to origin"}' \
    'Bash(git push -u origin fix/broken-anchors)' 'Push the branch to origin'; then
    printf '  \033[2mTo github.com:acme/docs-toolkit.git\n   * [new branch]      fix/broken-anchors -> fix/broken-anchors\033[0m\n'
    pause 0.8
    open_pr
    finish "Fixed the three broken anchors in docs/guide/install.md and opened $PR_URL.
heed-summary: Fixed three install-guide links that pointed at a renamed anchor, and opened acme/docs-toolkit#42 for review."
  else
    finish "I did not push. The three anchors are fixed locally on fix/broken-anchors; tell me when to push."
  fi
}

# gh pr create: heed reads the PR's url from the tool's output and tracks it. The fake gh then has the PR open.
open_pr() {
  local cmd='gh pr create --title \"Fix the broken anchors in the install guide\" --fill'
  hook PreToolUse ",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}"
  printf '\n\033[1;32m●\033[0m \033[1mBash(gh pr create --fill)\033[0m\n'
  pause 1.2
  mkdir -p "$DEMO_ROOT/gh" && printf opened >"$DEMO_ROOT/gh/state"
  printf '  \033[2m%s\033[0m\n' "$PR_URL"
  hook PostToolUse ",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"},\"tool_response\":{\"stdout\":\"$PR_URL\\n\"}"
}

clear
printf '\033[1;35m demo-agent\033[0m \033[2mv0.1 · scripted · %s\033[0m\n' "$CWD"
hook SessionStart ',"source":"startup"'
printf '\n\033[1m>\033[0m %s\n' "$PROMPT"
turn "$PROMPT"

# Then wait at the prompt, as an agent does: heed types review feedback and answers here.
while true; do
  printf '\n\033[1m> \033[0m'
  IFS= read -r line || break
  # heed may send several lines at once; take them as one message
  while IFS= read -r -t 1 more; do line="$line $more"; done
  [ -n "$line" ] || continue
  hook UserPromptSubmit ",\"prompt\":\"$(esc "$line")\""
  pause 0.8
  say "Reading the review comment on docs/guide/install.md."
  pause 1
  tool_use Edit '{"file_path":"docs/guide/install.md","old_string":"#getting-started","new_string":"#get-started"}' \
    'Update(docs/guide/install.md)' 1.2
  tool_use Bash '{"command":"git push"}' 'Bash(git push)' 1
  finish "Pointed the link at #get-started and pushed; the review thread is addressed.
heed-summary: Fixed three install-guide links that pointed at a renamed anchor, answered the review, and pushed; acme/docs-toolkit#42 is waiting on checks."
done
