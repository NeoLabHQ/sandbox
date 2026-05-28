---
title: Switch base image to devcontainers/base
---

## Initial User Prompt

### Context

Current repo uses devctonainer/universal as base image, which is too big to properly work with our pipelines. 

### Requirements

- Switch this repo to  use mcr.microsoft.com/devcontainers/base as basis
- Together with mise, also install nix and https://github.com/jetify-com/devbox
- then use mise or nix to install version manageres like nvm (Need research which one is better as part of this plan generation)
- then pass it to Dockerfile.base -> Dockerfile.agents -> Dockerfile, same way as with universal. Add packages if there will be some need. 
- Update github workflow
- update Readme
- Use .devcontainer/Dockerfile as reference, we currently use this for our other projects. Install clis/packages that are mentioned there, but missing in devcontainer/base, for example gh cli.

## Plan

TODO: fill it