@CLAUDE.md

Read `CLAUDE.md` for the shared infrastructure instructions.

For app/project onboarding, use `.agents/skills/add-app/SKILL.md` (`$add-app` in
Codex). This directory links to the canonical `.claude/skills/add-app` skill so
Claude and Codex use the same workflow and references; edit the canonical files.

Every new app needs a backup decision: add it to both the backup template and the
active VPS configuration, or ask the user and document an explicit exclusion.
`phnx-solution` is intentionally excluded from backups. Follow the onboarding
skill for configuration and verification; a Git pull does not update the active
backup configuration under `/etc`.
