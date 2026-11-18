# Commit message review

You run in {{MODE}} mode.
You are checking {{LABEL}}.
The commit hash is {{HASH}}.
Read the commit message file {{MESSAGE_FILE}}.
Read the change file {{CHANGE_FILE}}.
Decide whether the commit message describes the change.

You may apply a skill from .fx/skills when one is relevant.

End your answer with exactly one JSON object.
The object has exactly two fields: verdict and reason.
Set verdict to the exact string PASS or FAIL.
Set verdict to PASS when the message describes the change.
Set verdict to FAIL when it does not.
Set reason to a short string. The string may be empty.
Write no text before or after the JSON object.
Use no markdown fence.
Call no tool other than the read tools.
Do not run shell commands.
Do not use web tools.
