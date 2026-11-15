#!/bin/bash
# Builds a throwaway world for filming heed, and prints where it is. Nothing here touches the real home, config,
# sessions or memory: heed is launched (launch.sh) with HOME and CFFIXED_USER_HOME on <root>/home, which moves
# ~/Library/Application Support, ~/Library/Caches, ~/.config and the app's preferences with it.
#
#   docs/reels/demo/world.sh [root]        root defaults to /tmp/heed-demo (keep it short: unix socket paths)
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="${1:-${DEMO_ROOT:-/tmp/heed-demo}}"
home="$root/home"

rm -rf "$root"
mkdir -p "$home/.config/heed" "$home/Projects" "$home/code/wt" "$root/bin" "$root/gh"
cp "$here/gh" "$root/bin/gh"
cp "$here/demo-agent.sh" "$root/bin/demo-agent"
chmod +x "$root/bin/gh" "$root/bin/demo-agent"

# A repo with invented names. The origin is never contacted: it only gives heed the slug acme/docs-toolkit.
repo="$home/Projects/docs-toolkit"
mkdir -p "$repo/docs/guide"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git -C "$repo" init -q -b main
git -C "$repo" config user.name "Ada Example"
git -C "$repo" config user.email "ada@acme.example"
git -C "$repo" config commit.gpgsign false
printf '# Install\n\nSee [getting started](#getting-started).\n\n## Get started\n' >"$repo/docs/guide/install.md"
printf '# docs-toolkit\n' >"$repo/README.md"
git -C "$repo" add -A
git -C "$repo" commit -q -m "Add the install guide"
git -C "$repo" remote add origin git@github.com:acme/docs-toolkit.git

cat >"$home/.config/heed/config.toml" <<TOML
[worktrees]
root = "$home/code/wt"
repo_roots = ["$home/Projects"]
offer_trust = false

[sessions]
default_agent = "demo"
resume_on_launch = "never"
persist = "none"
name_sessions = false

[start_work]
smart_guesses = false
size_check = false

[updates]
check = false

[llm]
enabled = false

[mindmap]
enabled = false

[telemetry]
enabled = false

[tools]
gh = "$root/bin/gh"
path = ["$root/bin"]

[agents.demo]
command = "$root/bin/demo-agent"
prompt = "argument"
TOML

echo "world: $root"
echo "  home   $home   (HOME and CFFIXED_USER_HOME while heed runs)"
echo "  repo   $repo"
echo "  config $home/.config/heed/config.toml"
