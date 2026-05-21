# Development


## Building locally

The image chain is `Dockerfile.base` → `Dockerfile.agents` → `Dockerfile`. Each layer must be built before the next can reference it.

```bash
# 1. Build the base image
docker build -f Dockerfile.base -t neolabhq/sandbox:base .

# 2. Build the agents image (references :base by default via ARG)
docker build -f Dockerfile.agents -t neolabhq/sandbox:agents .

# 3. Build the final image (references :agents by default via ARG)
docker build -f Dockerfile -t neolabhq/sandbox:latest .
```

To pass a custom base image (e.g., a locally-built variant):

```bash
docker build -f Dockerfile.agents \
  --build-arg BASE_IMAGE=neolabhq/sandbox:base \
  -t neolabhq/sandbox:agents .

docker build -f Dockerfile \
  --build-arg AGENTS_IMAGE=neolabhq/sandbox:agents \
  -t neolabhq/sandbox:latest .
```

For multi-arch builds (requires `docker buildx`):

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -f Dockerfile.base \
  -t neolabhq/sandbox:base \
  --push .
```

The CI workflow (`.github/workflows/docker-publish.yml`) runs vulnerability scanning with Trivy before pushing any image. When building locally, you can run a quick scan with:

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image neolabhq/sandbox:latest
```
