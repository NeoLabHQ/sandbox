---
title: Setup Docker image
---

## Initial User Prompt

setup docker image

### Context

This is a new project, that based on devcontainer image that we use internally. Need setup proper docker images and workflows to build and push them to our public registry.

### Requirements

Create images that fulfill the following requirements:

[] Research and find hardened version of base image of microsoft devcontainer and use it as base
[] Create new Dockerfile.base in root that make base sandbox image based on the base image from previus requirement plus common tools and utils from .devcontainer/Dockerfile first stage apt-get installs + base package managers, like homebrew
[] Research how to possible install following languages in docker image using some version managers, like nvm. Languages:
    - Node.js
    - Python
    - Go
    - Java
[] Add this tools installation with enabled by default latest version of languages to Dockerfile
[] Create Dockerfile.agents that should build from base image and install common agents like claude code, opencode, gemini cli, etc.
[] Add Dockerfile that should build from Dockerfile.agents and add codemap, context7, common languages mcp servers, etc. Include there configure-claude.sh, statusline.sh, install-mcps.sh from devcontainer directory (move them to root)
[] create github workflow that will publish all images to our public registry NeoLabHQ/sandbox:base, NeoLabHQ/sandbox:agents, NeoLabHQ/sandbox:latest
[] Add proper usage description to README.md, that should explain how to use image to setup sandbox using only docker, add examples with devcontainer. Include how to map volumes for project properly. Also include example how to map ~/.claude/ and ~.claude.json so it will work properly with claude code. Also include how to pass CLAUDE_CODE_OAUTH_TOKEN enviroment variable, so it will login out of the box.


## Plan

// Fill in the details of the task here
