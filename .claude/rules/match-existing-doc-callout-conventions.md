---
title: Match Existing In-Document Callout Conventions
paths:
  - "**/*.md"
---

# Match Existing In-Document Callout Conventions

When adding a new note, warning, or trade-off callout to an existing document, reuse the document's own established callout format instead of introducing a different generic Markdown pattern (e.g., blockquotes). Mixing conventions within one file signals unaudited editing and degrades scanability for readers who learned the document's visual language.

## Incorrect

The document consistently marks callouts as plain bold-lead paragraphs (`**Trade-off.** ...`, `**Prerequisite for X.** ...`), but a new section introduces a blockquote for its warning — a different convention never used elsewhere in the file.

```markdown
**Trade-off.** Mounting `~/.claude*` binds the container to your host machine's profile...

...

> **Warning.** This configuration only works when the workspace folder is a git repository...
```

## Correct

Survey existing callouts in the file first (`grep -n '^\*\*' file.md` or similar), then match their exact format for the new content.

```markdown
**Trade-off.** Mounting `~/.claude*` binds the container to your host machine's profile...

...

**Warning.** This configuration only works when the workspace folder is a git repository...
```

## Reference

- Observed in README.md: every existing callout ("**MCP registration.**", "**Prerequisite for `~/.claude.json`.**", "**Trade-off.**") uses a plain bold-lead paragraph with no blockquote; a newly added "**Warning.**" callout was wrapped in `>` blockquote syntax, breaking the pattern.
