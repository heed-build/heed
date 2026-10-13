---
description: Running any command by name from the command line.
---

# The command line

`:` opens the command line. Every command has a name, and `:` runs any of them, with completion.

![The command line, completing view](../images/shots/keyboard/command-line.png)

| Key | |
|---|---|
| `⇥` | Complete |
| `↩` | Run |
| `⎋` | Close |

Short forms work too:

| Typed | Runs |
|---|---|
| `:start <prompt>` | Start work with that prompt |
| `:agent codex` | Start work with that agent |
| `:pr 2841` | Read pull request 2841 |
| `:track <url>` | Track a pull request |
| `:wt sweep` | Run the cleanup sweep |
| `:inbox`, `:prs`, … | Switch view |
| `:import <path>` | Import the worktree at a path |
| `:tutor [lesson]` | The [tutor](../getting-started/tutor.md)'s picker, or a lesson by name |
| `:back`, `:skip` | In the tutor: the step again, or skip it |
| `:help` | Every key |
| `:q` | Quit (in the tutor: leave the tutor) |

The [key reference](reference.md) lists every command name.
