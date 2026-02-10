---
name: toggle
description: Toggle Codex plan review on or off
allowed-tools: [Read, Edit]
---

# Toggle Codex Plan Review

Enable or disable the Codex plan reviewer.

## Algorithm

1. Read `${CLAUDE_PLUGIN_ROOT}/settings.json`
2. Toggle the `enabled` field:
   - If currently `true` (or missing), set to `false`
   - If currently `false`, set to `true`
3. Write the updated value back to `settings.json` using the Edit tool
4. Report the new state to the user:
   - If now enabled: "Codex plan review is **enabled**. Plans will be sent to Codex for review."
   - If now disabled: "Codex plan review is **disabled**. Plans will pass through without review."
