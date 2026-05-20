---
title: Add slim image variants based on devcontainers/base
depends_on:
  - setup-docker-image.chore.md
---

## Initial User Prompt

- extend repo to publish -slim version of all images, including base and agents. 
- For this version use mcr.microsoft.com/devcontainers/base as basis, 
- then use mise to install version manageres like nvm, 
- then then pass it to Dockerfile.base -> Dockerfile.agents -> Dockerfile, same way as with universal. Design it in a way to avoid code dublication. 
- Then extend github workflow to publish it, and update Readme

## Description

// Will be filled in future stages by business analyst
