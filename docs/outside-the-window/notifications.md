---
description: "Notifications when a session starts needing you, with Open and, for Claude's permission prompts, Allow."
---

# Notifications

When a session starts needing you (its agent is [asking or blocked](../concepts/agent-states.md)), Heed posts a macOS
notification: the session's title, the state and why ("Blocked: Bash(rm -rf build)", "Asking: asked a question").
Nothing is posted for the session you are looking at, with Heed in front. macOS asks whether Heed may notify the first
time there is something to say, not when Heed starts; System Settings › Notifications changes your answer later.

- **One per change.** A session gets one notification when it enters a state, not one per hook call while it stays
  there. Once it moves on, its notification is taken out of Notification Center.
- **Bursts come as one.** Changes within a few seconds of each other become a single notification ("3 sessions need
  you") listing them, blocked first. A prompt that clears within those seconds is never shown.
- **Open** (or clicking the notification) brings Heed forward on the session.
- **Allow**, on a Claude permission prompt, answers it with yes without leaving the app you are in. Heed presses Return
  only while the session is still blocked and its screen shows Claude's prompt with the cursor on `1. Yes`; otherwise
  it brings Heed forward on the session instead, so you answer it yourself. macOS asks you to unlock first when the
  screen is locked. Other agents' prompts get Open only.

```toml
[notifications]
enabled = true
asking = true      # questions, a plan to approve
blocked = true     # permission prompts
```

The same switches are in Settings (`⌘,`), under Outside the window.
