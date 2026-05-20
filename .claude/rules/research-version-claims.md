---
title: Anchor or Hedge Forward-Looking Version Claims
impact: HIGH
---

# Anchor or Hedge Forward-Looking Version Claims

When citing specific software versions in research, planning, or comparison tables, either anchor the claim to a verifiable source (manifest commit hash, release-notes URL, build SHA) OR use relative descriptors. Confident-specific version numbers presented as ground truth without anchoring are a confident-error pattern that corrupts downstream implementation.

## Incorrect

A table presents specific version numbers as verified facts, including versions that are forward-looking or not externally verifiable from the cited source. Looks authoritative but is unverifiable.

```markdown
Researched preinstalled versions in image X (verified against manifest.json):

| Language | Preinstalled version |
|----------|---------------------|
| Python   | 3.14 (default) + 3.13 |
| Java     | 25 (default) + 21 |
| Node.js  | 24 (default) + 22 |
```

## Correct

Specific versions are either anchored to a verifiable snapshot or replaced with relative descriptors. The reader knows whether to trust the exact number or look it up at build time.

```markdown
Researched preinstalled versions in image X (verify at build time via `docker run --rm X bash -c 'python3 --version && java --version && node --version'`):

| Language | Preinstalled version (as of manifest @ commit abc1234) |
|----------|--------------------------------------------------------|
| Python   | current stable (≥3.12) + previous stable |
| Java     | current LTS + previous LTS |
| Node.js  | current LTS + previous LTS |
```

## Reference

- Hedge forward-looking specifics: replace concrete numbers with descriptors when a verifiable source cannot be cited.
- Always provide a runtime-verifiable command when readers need exact numbers.
