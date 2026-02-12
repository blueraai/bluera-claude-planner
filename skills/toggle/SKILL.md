---
name: toggle
description: Toggle Codex plan review on or off for the current project
allowed-tools: [Read, Edit, Write, Bash]
---

# Toggle Codex Plan Review

Enable or disable the Codex plan reviewer for the **current project**.

Enablement is per-project via `.claude/bluera-claude-planner.json` in the project root. This prevents the reviewer from running in unrelated projects.

## Algorithm

1. Determine the project root (current working directory)
2. Read `<project-root>/.claude/bluera-claude-planner.json` if it exists
3. Toggle the `enabled` field:
   - If file doesn't exist or `enabled` is `false`: create/update with `{"enabled": true}`
   - If `enabled` is `true`: set to `false`
4. Ensure `.claude/` directory exists before writing
5. Report the new state to the user:
   - If now enabled: "Codex plan review is **enabled** for this project. Plans will be sent to Codex for review."
   - If now disabled: "Codex plan review is **disabled** for this project. Plans will pass through without review."
