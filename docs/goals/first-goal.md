---
description: "The new-goal wizard: talk the plan through with a big model, have a panel of personas read it, and say what done looks like, before any work starts."
---

# Your first goal

`n` in Goals asks for a title and what you want, then walks the new goal through six steps before any work starts:
**Plan**, **Panel**, **Done looks like**, **Split**, **How careful** and **Go**. The rail on the left shows where you
are: a check on the steps done, a ring on the one you are on. `H` and `L` go back and forth between the steps you
reached, `⌘↩` moves on, and `⎋` leaves the wizard. Leaving keeps its place: `↩` on the goal in the list, or
`:goal.wizard`, comes back to where you were. `:goal.wizard` also walks a goal you made another way.

![The wizard's rail, three steps done](../images/shots/goals/wizard-rail.png)

## 1. Plan: talk it through

heed asks until the plan has what agents need, one question at a time. Each question comes with options: `1`, `2` or
`3` picks one, `i` types your own answer (and "good enough" in it moves on). The questions come from your default
agent on its strongest model (opus for Claude), run headless and read-only in the goal's repos, so it can look at the
code before it asks: the worktrees of the sessions on the goal, and any repo you name in what you write. It may read
and search them; it cannot change a file, and nothing is kept in the agent's own history. A repo it could not read
means it plans from your words alone.

On the right, the plan builds up. Every version is saved as a new version of the goal's `GOAL.md` too: the summary
as the goal, the out-of-scope list as **Not the goal**, your decisions in **Decisions**, and the steps, constraints,
risks and who it is for in sections of their own. Under it, five meters say how complete the plan is: scope,
constraints, risks, who it's for and out of scope, each scored by a cheap model after every answer. heed says when it
thinks the plan is complete enough; **Good enough** (`⌘↩`) moves on whenever you like.

![Plan: heed's questions, the plan in versions, the meters](../images/shots/goals/wizard-plan.png)

The line at the bottom right says what the step's calls cost so far, as the agents reported it; `≈` when part of it
is an estimate or unknown.

## 2. Panel: who reads it

A panel of personas reads the plan, each in its own voice, and says **happy**, **concern** or **not**, with one
quote and, unless happy, one fix. Four always sit: the **Skeptic**, who argues not to do it at all (or much smaller),
the **Purist**, the **Scope keeper** and **UX**. Others are invited by what the goal touches, read from the plan's
words, and the chips at the top say why:

| The goal touches | Who is invited |
|---|---|
| a public package, an SDK, a CLI | DX and Newcomer |
| behaviour or parsing (a format, a default, a migration) | Adversary |
| a service (a deploy, a queue, a database) | Operator |
| a UI | Accessibility |
| auth or the network | Security |
| a hot path (latency, throughput, a cache) | Performance |
| your team's style, once a library persona named "team style" exists | that persona |

`+` invites another: the built-in personas not on the panel, and the ones in your persona library. A cheap model
reads for the whole panel in one call.

![The panel: the Skeptic on top, each persona's verdict, quote and fix](../images/shots/goals/wizard-panel.png)

Then, for up to three rounds:

| Key | |
|---|---|
| `⌘↩` | **Worth it, take the fixes**: the fixes go into the plan (a new version, in `GOAL.md` too) and the panel reads it again. With no fixes left, or after the third round, it moves on. |
| `-` | **Go smaller**: the plan is cut to what gets most of the value, the rest moves out of scope, and the panel reads again. |
| `i` | **Talk to one**: a chat with the persona under the cursor (`j` `k` move); `⎋` closes it. |
| `x` | **Don't do it**: type why (the Skeptic's words to start from); the reason goes into `GOAL.md`'s decisions and the goal is archived. |

## 3. Done looks like

From the agreed plan, heed drafts what done looks like: a statement and the criteria, each with how it is checked:
a **test**, a **CI step**, a **command**, or nothing yet. The meter on each row says how surely an agent can tell it
is met: a real check fills it, a proposed one (a test that does not exist yet) half, and a line nothing checks is
empty, or nearly, when its words cannot be checked ("fast", "nice", "robust" without a number).

![Done looks like: the criteria, how each is checked, and replacements for the vague one](../images/shots/goals/wizard-done.png)

A criterion nothing checks gets measurable replacements on the right: `1` `2` `3` highlight one, `↩` uses it ("drop
it" drops the criterion). `d` defines it with an agent: the same read-only agent as in Plan reads the repos and
proposes checks it could run, which join the list. **Looks right** (`⌘↩`) writes the criteria into `GOAL.md`'s
**Done when**, each with its check after it, as `(check: test RedirectTargetsTests)`.

## 4–6. Split, How careful, Go

These three steps have no screen in the wizard yet. Each says what it will do, and `↩` opens the goal's page that
does it today: the [swarm's plan](swarms/plan.md) for Split, the [reviewers and their bars](quality.md) for How
careful, and the goal's overview for Go. `⌘↩` counts the step as done; after Go the wizard is finished and the goal
opens on its page.

![A step without a screen yet](../images/shots/goals/wizard-later.png)

## TL;DR

Once there is something to summarise (the wizard's first plan, or a goal that says what it is), a **TL;DR** entry
sits under the rail's steps and a **TL;DR** chip beside each step's title and the goal's title on its page. When it
has news since you last opened it (a step finished, a new open point), the entry shows how many points are open, amber
when one of them needs you, or a dot when none is open. A click, or `T` on any step of the wizard and on a goal's
page, opens the goal's TL;DR: each
step with a summary, what is **settled**, and what is still **open**, numbered, each with what to do about it. `d`
does the first open point (define a vague criterion, back to the panel), `y` copies the whole TL;DR as markdown, and
`T` or `⎋` closes it. A cheap model writes it from heed's facts; it is written again only when something it was
written from changed, and until it is, heed's own words show.

![The TL;DR over the wizard](../images/shots/goals/wizard-tldr.png)

## What it costs

Plan's questions run on your strongest model, one headless run per question, and say what each cost. Everything
else is heed's [model calls](../configuration/inference.md) on the cheap model: the meters after each answer, the
panel's read (one call per round), the fixes, the criteria, the replacements and the TL;DR. In the tutor and the
docs' pictures nothing is called: the answers are scripted.
