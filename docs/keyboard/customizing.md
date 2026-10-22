---
description: Changing key bindings in config.toml, per mode and per view.
---

# Customizing keys

Key bindings live in `config.toml` (not in Settings). Each table maps keys, in vim notation, to a command name.

```toml
[keys]
insert_escape = "<C-\\>"           # leaves INSERT (⇧⎋ does too)
global_start_work = "<C-M-Space>"  # Start work from any app; "" turns it off
global_activate = "<C-M-h>"        # brings Heed forward from any app

[keys.normal]
"<C-j>" = "row.next"
"gC" = ""                          # "" unbinds a default

[keys.repos]
"x" = "select.remove"
```

- **Per mode**: `[keys.normal]`, `[keys.visual]`, `[keys.insert]`, `[keys.command]`, `[keys.hint]`.
- **Per view**: `[keys.sessions]`, `[keys.attention]`, `[keys.watch]`, `[keys.repos]`, `[keys.history]`,
  `[keys.timeline]`, `[keys.ledger]`, `[keys.dashboard]`, `[keys.log]`, `[keys.inbox]`, `[keys.issues]`, `[keys.prs]`,
  `[keys.diff]`, `[keys.pr]`, `[keys.issue]`. View keys apply in NORMAL in that view, before NORMAL's own.
- **Notation**: `gg`, `<C-w>v` (⌃w then v), `<D-/>` (⌘/), `<M-x>` (⌥x), `<S-Tab>`, `<CR>`, `<Esc>`, `<Space>`.

The [key reference](reference.md) lists every command name; `:` completes them.

## Clashes are refused

A binding that would hide another is refused, with a message in the status bar naming the clash:

- Within one table, `gg` and `g` cannot both be bound: one could never fire.
- A view binding cannot start with a key that is a NORMAL command (`iw` would make `i` wait), nor be the start of a
  NORMAL binding (a view `g` would hide `gg`). Replacing a NORMAL key outright in one view is fine.

Mistakes never take the rest down: the binding is skipped, the problem reported, and every other key keeps working.
