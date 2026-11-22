---
name: default
description: Use this skill for the agent-fx check. It defines the JSON verdict contract.
---

# Default structured-output skill

Read the commit message file and the change file that the prompt names.
Compare the message with the change.
End your answer with exactly one JSON object.

The object has exactly two fields: `verdict` and `reason`.
`verdict` is the exact string `PASS` or `FAIL`.
`reason` is a string. The string may be empty. Write the reason in strict STE wording.
Write no text before or after the object.
Use no markdown fence.

Use only the read tools.
Do not run shell commands.
Do not use web tools.

Other skills extend this contract.
They must not change the field names, the field count, or the allowed verdict values.
