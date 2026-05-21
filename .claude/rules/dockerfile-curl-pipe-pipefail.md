---
title: Use bash+pipefail for curl|bash installers in Dockerfiles
impact: HIGH
paths:
  - "**/Dockerfile*"
  - "**/*.dockerfile"
---

# Use bash+pipefail for curl|bash installers in Dockerfiles

Docker's default `RUN` shell is `/bin/sh` (dash on Debian/Ubuntu), which does NOT support `set -o pipefail`. A `RUN curl ... | bash` line under dash will succeed even when curl fails or returns a partial body — `bash` reads empty/truncated input, exits 0, and the layer is silently broken. Always switch to bash+pipefail before running pipe-fed installers, or wrap each `RUN` with explicit `bash -o pipefail -c`.

## Incorrect

The `curl | bash` line runs under dash with no pipefail; a network blip or 404 redirect silently produces a successful layer that contains no installed binary.

```dockerfile
FROM ubuntu:24.04

RUN curl -fsSL https://example.com/install.sh | bash
```

## Correct

Declare a bash+pipefail SHELL once, so every subsequent `RUN`'s pipeline aborts on the first failing stage. Alternatively, scope `set -euo pipefail` per RUN.

```dockerfile
FROM ubuntu:24.04

# Make every RUN abort if any pipeline stage fails.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN curl -fsSL https://example.com/install.sh | bash
```

## Reference

- Docker docs, `RUN` instruction: https://docs.docker.com/reference/dockerfile/#run
- Hadolint DL4006 (pipefail rule): https://github.com/hadolint/hadolint/wiki/DL4006
