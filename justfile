
[doc("Show all available commands with their descriptions")]
help:
    @just --list

[doc("Get the running devcontainer ID (empty if not running)")]
_sandbox-id:
    @docker ps --filter "label=devcontainer.local_folder={{justfile_directory()}}" --format "{{{{.ID}}" | head -n1

[doc("""
  Start devcontainer and open an interactive shell.

  Description:
    Starts the development container using devcontainer CLI and attaches to an
    interactive zsh shell. First run may take time to build the image.

  Steps:
    1. Runs `devcontainer up` to start the container
    2. Extracts container ID, workspace folder, and user from output
    3. Attaches to the container with docker exec

  Usage:
    just sandbox
""")]
sandbox:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Starting devcontainer... First run can take long time to build the image"
    tmpfile=$(mktemp)
    devcontainer up --workspace-folder . 2>&1 | tee "$tmpfile"
    output=$(cat "$tmpfile")
    rm "$tmpfile"
    container_id=$(echo "$output" | grep -oP '"containerId"\s*:\s*"\K[^"]+')
    workspace=$(echo "$output" | grep -oP '"remoteWorkspaceFolder"\s*:\s*"\K[^"]+')
    user=$(echo "$output" | grep -oP '"remoteUser"\s*:\s*"\K[^"]+')
    if [ -z "$container_id" ]; then
        echo "Error: could not find devcontainer"
        exit 1
    fi
    echo "Attaching to container $container_id as ${user:-root} at $workspace..."
    docker exec -it -u "${user:-root}" -w "${workspace:-/}" "$container_id" zsh

[doc("""
  Attach to a running devcontainer.

  Description:
    Connects to an already running devcontainer shell. Requires that
    the devcontainer was started with `just sandbox` first.

  Steps:
    1. Gets the container ID using _sandbox-id
    2. Inspects container to find workspace and user
    3. Attaches with docker exec

  Usage:
    just attach-sandbox
""")]
attach-sandbox:
    #!/usr/bin/env bash
    set -euo pipefail
    container_id=$(just _sandbox-id)
    if [ -z "$container_id" ]; then
        echo "Error: no running devcontainer found. Run 'just sandbox' first."
        exit 1
    fi
    eval "$(docker inspect "$container_id" | python3 -c "
    import json,sys
    c = json.load(sys.stdin)[0]
    folder = c['Config']['Labels'].get('devcontainer.local_folder','')
    ws = next((m['Destination'] for m in c.get('Mounts',[]) if m['Source'] == folder), '/')
    meta = json.loads(c['Config']['Labels'].get('devcontainer.metadata','[]'))
    user = next((i['remoteUser'] for i in meta if 'remoteUser' in i), 'root')
    print(f'workspace={ws}')
    print(f'user={user}')
    ")"
    echo "Attaching to container $container_id as $user at $workspace..."
    docker exec -it -u "$user" -w "$workspace" "$container_id" zsh

[doc("""
  Stop and remove the devcontainer.

  Description:
    Gracefully stops and removes the running development container.
    Safe to run even if no container is running.

  Steps:
    1. Gets container ID (if any)
    2. Stops the container with docker stop
    3. Removes the container with docker rm

  Usage:
    just stop-sandbox
""")]
stop-sandbox:
    #!/usr/bin/env bash
    set -euo pipefail
    container_id=$(just _sandbox-id)
    if [ -z "$container_id" ]; then
        echo "No running devcontainer found."
        exit 0
    fi
    echo "Stopping container $container_id..."
    docker stop "$container_id" && docker rm "$container_id"
    echo "Done."

[doc("""
  Tear down the devcontainer docker-compose resources.

  Description:
    Runs docker compose down for the devcontainer configuration.
    Use this to completely clean up devcontainer networking and volumes.

  Usage:
    just down-devcontainer
""")]
down-devcontainer:
    docker compose --project-name decision-engine_devcontainer -f .devcontainer/docker-compose.yaml down
