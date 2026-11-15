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
cp "$here/cue" "$root/bin/cue"
chmod +x "$root/bin/gh" "$root/bin/demo-agent" "$root/bin/cue"
echo none >"$root/gh/state"

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
# A film's config: nothing that calls a model, starts a real agent, asks macOS for a permission or checks for updates.
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

[ui]
menu_bar = false
dock_state = false

[notifications]
enabled = false

[llm]
enabled = false
setup_reminder = false

[nudges]
whats_new = false
gaps = "off"

[telemetry]
enabled = false

[helpers]
agent = ""

# Mindmap on (the seeded campaigns), but nothing asks a model: placement is by words.
[mindmap]
enabled = true

[personas]
built = false
says_done = false
before_pr = false
second_repo = false
long = false
offers = "never"

# The pilot sends review feedback to the session's own agent (no helper starts a real agent) and merges itself.
[pilot]
watch = true
green = "auto"
run_in = "session"
merge = "heed"
quiet_minutes = 0
merge_schedule = "15m"
update_branches = false

[tools]
gh = "$root/bin/gh"
path = ["$root/bin"]

[agents.demo]
command = "$root/bin/demo-agent"
prompt = "argument"
TOML

# What a reel's terminal sources to talk to this world.
cat >"$root/env.sh" <<ENV
export DEMO_ROOT="$root"
export CFFIXED_USER_HOME="$home"
export PATH="$root/bin:\$PATH"
ENV

echo "world: $root"
echo "  home   $home   (HOME and CFFIXED_USER_HOME while heed runs)"
echo "  repo   $repo"
echo "  config $home/.config/heed/config.toml"
