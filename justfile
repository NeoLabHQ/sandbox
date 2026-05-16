# ── Configuration defaults ──────────────────────────────────────────
# All configurable environment variables for claude recipes:
#
#   PERMISSION_MODE       Claude CLI permission flag.
#                         Default: "--permission-mode auto"
#                         Alternative: "--dangerously-skip-permissions"
#
#   MAX_SESSION_RETRIES   Max retry attempts on CLI failure (in claude-helpers.sh).
#                         Default: 12
#
#   SESSION_RETRY_WAIT    Seconds to wait between retries (in claude-helpers.sh).
#                         Default: 3600 (1 hour)
#
#   COMMAND_TIMEOUT       Max seconds a single `claude -p` command may run
#                         before being killed and retried (in claude-helpers.sh).
#                         Default: 21600 (6 hours)
#
#   DRAFT_DIR / TODO_DIR / DONE_DIR
#                         Task file directories (in claude-helpers.sh).
#                         Defaults: .specs/tasks/{draft,todo,done}
# ────────────────────────────────────────────────────────────────────

# `export` is required so the variable is visible inside recipe shell
# environments (each recipe runs in a separate bash process).
export PERMISSION_MODE := env("PERMISSION_MODE", "--permission-mode auto")

[doc("Show all available commands with their descriptions")]
help:
    @echo "PERMISSION_MODE: $PERMISSION_MODE"
    @just --list

[doc("Get the running devcontainer ID (empty if not running)")]
_sandbox-id:
    @docker ps --filter "label=devcontainer.local_folder={{justfile_directory()}}" --format "{{{{.ID}}" | head -n1

[doc("""
  Generate fly.toml for a target environment.

  Description:
    Merge .flyenv/<env>.toml and fly.template.toml into fly.toml.

    The generated fly.toml is gitignored — only the template and overrides
    are tracked in version control.

    if tomlq not avaiable, install it using `pip install yq`

  Parameters:
    env - Target environment name. Must match a file in .flyenv/ (e.g. dev, prod).

  Usage:
    just fly-config dev
    just fly-config prod
""")]
fly-config env:
    #!/usr/bin/env bash
    set -euo pipefail
    tomlq -t -s '.[0] * .[1]' fly.template.toml .flyenv/{{env}}.toml > fly.toml

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

[doc("""
  Run claude with a prompt and stream plain text output.

  Description:
    Executes Claude CLI with a prompt and streams the response as plain text.
    Automatically retries on session-limit errors.

  Parameters:
    prompt - The prompt to send to Claude
    label  - Optional label for tracking/logging (default: "claude")

  Usage:
    just claude "Explain this codebase"
    just claude "Summarize the README" "my-label"
""")]
[no-exit-message]
claude prompt label="claude":
    #!/usr/bin/env bash
    set -euo pipefail
    source claude-helpers.sh
    run_with_session_retry "{{ label }}" _raw_claude_stream "{{ prompt }}"

[doc("""
  Create a new draft task from a prompt.

  Description:
    Creates a new draft task file using the SDD add-task skill.
    The task will be created in the draft directory.

  Parameters:
    prompt - Description of the task to create

  Usage:
    just claude-add-task "Add validation to the /decide endpoint"
""")]
[no-exit-message]
claude-add-task prompt:
    #!/usr/bin/env bash
    set -euo pipefail
    just claude "/add-task {{ prompt }}"

[doc("""
  Run claude in JSON output mode with optional schema validation.

  Description:
    Executes Claude CLI and returns parseable JSON output.
    Supports optional JSON schema for structured responses.
    Automatically retries on session-limit errors.

  Parameters:
    prompt      - The prompt to send to Claude
    json_schema - Optional JSON schema for structured output (default: "")
    label       - Optional label for tracking/logging (default: "claude-json")

  Usage:
    just claude-json "your prompt"
    just claude-json "your prompt" '{"type":"object",...}'
    just claude-json "your prompt" '{"type":"object",...}' "my-label"
    just claude-json "your prompt" "" "my-label"
""")]
[no-exit-message]
claude-json prompt json_schema="" label="claude-json":
    #!/usr/bin/env bash
    set -euo pipefail
    source claude-helpers.sh
    _raw_claude_json() {
      local prompt="$1"
      local schema="${2:-}"
      # shellcheck disable=SC2086
      if [ -n "$schema" ]; then
        claude -p "$prompt" \
          --output-format json \
          --verbose \
          --json-schema "$schema" \
          $PERMISSION_MODE
      else
        claude -p "$prompt" \
          --output-format json \
          --verbose \
          $PERMISSION_MODE
      fi
    }
    run_with_session_retry "{{ label }}" _raw_claude_json "{{ prompt }}" '{{ json_schema }}'

[doc("""
  Plan, implement, and verify a task with automatic retries.

  Description:
    Executes the full task implementation pipeline (Steps 1-4):
    plans the task, implements it, verifies completion, and retries if needed.

  Steps:
    1. Plan - Creates implementation plan from draft task
    2. Implement - Executes the implementation
    3. Verify - Checks that all task items are completed
    4. Retry - Re-implements if verification fails

  Parameters:
    task-filename - The task filename (e.g., "add-feature-x.feature.md")
    mode          - Optional mode: "", "continue-plan", or "continue-implement"

  Usage:
    just claude-plan-and-implement "my-task.feature.md"
    just claude-plan-and-implement "my-task.feature.md" "continue-plan"
    just claude-plan-and-implement "my-task.feature.md" "continue-implement"
""")]
[no-exit-message]
claude-plan-and-implement task-filename mode="":
    #!/usr/bin/env bash
    set -euo pipefail
    source claude-helpers.sh

    TASK_FILENAME="{{ task-filename }}"
    MODE="{{ mode }}"

    # ── STEP 1: Plan ────────────────────────────────────────────────
    draft_path="$DRAFT_DIR/$TASK_FILENAME"
    todo_path="$TODO_DIR/$TASK_FILENAME"
    done_path="$DONE_DIR/$TASK_FILENAME"

    if [ "$MODE" = "continue-implement" ]; then
      echo "==> Step 1: Skipped (mode=continue-implement)"
    elif [ "$MODE" = "continue-plan" ]; then
      echo "==> Step 1: Continuing planning with --continue"
      run_plan_or_implement_retry "plan" \
        "/plan-task --continue $TASK_FILENAME start from judge review of last completed stage" \
        "/plan-task --continue $TASK_FILENAME start from judge review of last completed stage"
      echo ""

      if [ ! -f "$todo_path" ]; then
        echo "ERROR: Planning did not produce: $todo_path"
        exit 1
      fi
      echo "==> Plan complete. Task moved to: $todo_path"
    elif [ -f "$done_path" ]; then
      echo "==> Step 1: Task already done, skipping to verification"
    elif [ -f "$draft_path" ]; then
      echo "==> Step 1: Planning task from draft"
      run_plan_or_implement_retry "plan" \
        "/plan-task @$draft_path" \
        "/plan-task --continue $TASK_FILENAME start from judge review of last completed stage"
      echo ""

      if [ ! -f "$todo_path" ]; then
        echo "ERROR: Planning did not produce: $todo_path"
        exit 1
      fi
      echo "==> Plan complete. Task moved to: $todo_path"
    elif [ -f "$todo_path" ]; then
      echo "==> Step 1: Task already planned, skipping to implement"
    else
      echo "ERROR: Task file not found in draft/ or todo/: $TASK_FILENAME"
      exit 1
    fi

    # ── STEP 2: Implement (with retry loop) ───────────────────────────
    MAX_IMPLEMENT_RETRIES=3

    if [ -f "$done_path" ]; then
      echo ""
      echo "==> Step 2: Task already implemented, skipping to verification"
    else
      # Determine initial prompt based on mode
      if [ "$MODE" = "continue-implement" ]; then
        initial_prompt="/implement-task --continue $TASK_FILENAME start from judge review of last completed stage"
        echo ""
        echo "==> Step 2: Continuing implementation with --continue"
      else
        initial_prompt="/implement-task @$todo_path"
        echo ""
        echo "==> Step 2: Implementing task"
      fi
      continue_prompt="/implement-task --continue $TASK_FILENAME start from judge review of last completed stage"

      # Retry loop: attempt implementation until done_path exists or max retries
      implement_attempt=0
      while [ ! -f "$done_path" ]; do
        implement_attempt=$((implement_attempt + 1))

        if [ "$implement_attempt" -gt "$MAX_IMPLEMENT_RETRIES" ]; then
          echo "ERROR: Implementation did not move task to done/ after $MAX_IMPLEMENT_RETRIES attempts. Stopping."
          exit 1
        fi

        if [ "$implement_attempt" -gt 1 ]; then
          echo "==> Step 2: Retrying implementation (attempt $implement_attempt/$MAX_IMPLEMENT_RETRIES) with --continue"
          run_plan_or_implement_retry "implement-retry-$implement_attempt" \
            "$continue_prompt" \
            "$continue_prompt"
        else
          run_plan_or_implement_retry "implement" \
            "$initial_prompt" \
            "$continue_prompt"
        fi
        echo ""
      done

      echo "==> Implementation complete. Task moved to: $done_path"
    fi

    # ── STEP 3: Verify completion ──────────────────────────────────
    echo ""
    echo "==> Step 3: Verifying task completion"

    # Implementation MUST move the task file to done/
    if [ ! -f "$done_path" ]; then
      echo "ERROR: Implementation did not move task to done/: $done_path"
      exit 1
    fi
    verify_path="$done_path"

    verify_prompt="Read the task file at $verify_path. Check that all checkmarks/subtasks are marked as done (ignore items like 'human review' and 'create PR' which are expected to be unchecked). For any unchecked item, verify if it was actually completed in the codebase. If yes, mark it done. If all relevant items are done, output {completed: true}. If something is genuinely not done, output {completed: false, message: '<what is not done>'}."

    verify_output=$(just claude-json "$verify_prompt" "$COMPLETED_SCHEMA" "verify")
    completed=$(extract_structured_field "$verify_output" "completed" "false")

    # ── STEP 4: Retry implementation if not completed ──────────────
    if [ "$completed" != "true" ]; then
      not_done_msg=$(extract_structured_field "$verify_output" "message" "Unknown incomplete items")
      echo "WARN: Task not fully completed: $not_done_msg"
      echo "==> Step 4: Retrying implementation with --continue"

      run_plan_or_implement_retry "implement-retry" \
        "/implement-task --continue $TASK_FILENAME start from judge review of last completed stage" \
        "/implement-task --continue $TASK_FILENAME start from judge review of last completed stage"
      echo ""

      # Re-verify after retry
      echo "==> Re-verifying task completion after retry..."
      verify_output=$(just claude-json "$verify_prompt" "$COMPLETED_SCHEMA" "verify-retry")
      completed=$(extract_structured_field "$verify_output" "completed" "false")

      if [ "$completed" != "true" ]; then
        echo "ERROR: Task still not completed after retry. Stopping loop."
        exit 1
      fi
    fi

    echo "==> Task verification passed."

[doc("""
  Run lint and tests, auto-fix with claude if they fail.

  Description:
    Executes Step 5 of the task pipeline. Runs linting and tests,
    and if they fail, automatically invokes Claude to fix the issues.
    Limited to one automatic fix attempt.

  Steps:
    1. Run `bun run lint` and `bun run test`
    2. If failed, launch Claude to fix issues
    3. Retry lint/test once after fix attempt

  Usage:
    just claude-fix-lint-and-test
""")]
[no-exit-message]
claude-fix-lint-and-test:
    #!/usr/bin/env bash
    set -euo pipefail

    echo ""
    echo "==> Step 5: Running lint and tests"

    lint_test_pass=false
    for lt_attempt in 1 2 3; do
      lint_exit=0
      test_exit=0
      npm run lint > /tmp/lint.log 2>&1 || lint_exit=$?
      npm run test > /tmp/test.log 2>&1 || test_exit=$?
      if [ "$lint_exit" -eq 0 ] && [ "$test_exit" -eq 0 ]; then
        lint_test_pass=true
        break
      fi

      # Attempt 1: initial run failed, fix and retry once more
      # Attempt 2: fix attempt already made, retry once more
      # Attempt 3: fix attempt already made, no more retries
      if [ "$lt_attempt" -ge 3 ]; then
        echo "ERROR: Lint/test still failing after 2 fix attempt. Stopping loop."
        exit 1
      fi

      echo "WARN: Lint or test failed. Launching claude to fix (fix attempt $lt_attempt/3)..."
      fix_prompt="/do-and-judge This codebase was recently integrated with new functionality. But bun run lint or bun run test fails. Fix the codebase, iterate till bun run lint and bun run test pass. Do not break old and newly added functionality! Do not remove or change it, unless it is obviously a bug!"
      just claude "$fix_prompt" "lint-test-fix-$lt_attempt"
      echo ""
    done

    if [ "$lint_test_pass" != "true" ]; then
      echo "ERROR: Lint/test did not pass. Stopping loop."
      exit 1
    fi
    echo "==> Lint and tests passed."

[doc("""
  Run code review and auto-fix critical/high issues.

  Description:
    Executes Step 6 of the task pipeline. Runs automated code review
    on local changes and uses Claude to fix any critical or high severity
    issues found. Limited to two fix attempts.

  Steps:
    1. Run code review using /code-review:review-local-changes
    2. Extract critical and high issue counts
    3. If issues found, launch Claude to fix them
    4. Re-review after fix (up to 2 fix attempts)

  Usage:
    just claude-review-and-fix
""")]
[no-exit-message]
claude-review-and-fix:
    #!/usr/bin/env bash
    set -euo pipefail
    source claude-helpers.sh

    echo ""
    echo "==> Step 6: Running code review"

    review_pass=false
    for review_attempt in 1 2 3; do
      review_output=$(just claude-json "/review-local-changes --json" "" "code-review-$review_attempt")

      # Extract critical and high issue counts
      critical_count=$(extract_structured_field "$review_output" "summary.critical" "0")
      high_count=$(extract_structured_field "$review_output" "summary.high" "0")

      echo "  Review result: critical=$critical_count high=$high_count"

      if [ "${critical_count:-0}" -eq 0 ] 2>/dev/null && [ "${high_count:-0}" -eq 0 ] 2>/dev/null; then
        review_pass=true
        break
      fi

      # Attempt 1: initial review found issues, fix and review once more
      # Attempt 2: fix attempt already made, retry once more
      # Attempt 3: fix attempt already made, no more retries
      if [ "$review_attempt" -ge 3 ]; then
        echo "ERROR: Critical/high issues remain after 2 fix attempts. Stopping loop."
        exit 1
      fi

      echo "WARN: Found critical=$critical_count high=$high_count issues. Launching claude to fix (fix attempt $review_attempt/3)..."
      fix_review_prompt="/do-and-judge The code review found critical or high severity issues in the local changes. Fix all critical and high issues. Do not break existing functionality!"
      just claude "$fix_review_prompt" "review-fix-$review_attempt"
      echo ""
    done

    if [ "$review_pass" != "true" ]; then
      echo "ERROR: Code review did not pass. Stopping loop."
      exit 1
    fi
    echo "==> Code review passed."

[doc("""
  Run lint+test and code review loop, retrying up to 3 times.

  Description:
    Executes the verify-and-fix loop: runs lint+test followed by code review,
    retrying up to 3 times until both pass.

  Steps:
    1. Run claude-fix-lint-and-test
    2. Run claude-review-and-fix
    3. If either fails, retry from step 1 (up to 3 attempts)

  Parameters:
    skip-lint-on-first - If "true", skip lint+test on the first loop attempt (default: "")

  Usage:
    just claude-verify-and-fix
    just claude-verify-and-fix "true"
""")]
[no-exit-message]
claude-verify-and-fix skip-lint-on-first="":
    #!/usr/bin/env bash
    set -euo pipefail

    MAX_LOOP=3
    loop_passed=false
    SKIP_LINT_ON_FIRST="{{ skip-lint-on-first }}"

    for loop_attempt in $(seq 1 $MAX_LOOP); do
      echo ""
      echo "==> Verify-and-fix loop: attempt $loop_attempt/$MAX_LOOP"

      skip_lint=false
      if [ "$loop_attempt" -eq 1 ] && [ "$SKIP_LINT_ON_FIRST" = "true" ]; then
        skip_lint=true
        echo "==> Skipping lint+test on first pass"
      fi

      if [ "$skip_lint" = "false" ]; then
        if ! just claude-fix-lint-and-test; then
          echo "WARN: Lint+test failed on attempt $loop_attempt"
          if [ "$loop_attempt" -ge "$MAX_LOOP" ]; then
            echo "ERROR: Lint+test failed on final attempt. Stopping."
            exit 1
          fi
          continue
        fi
      fi

      if ! just claude-review-and-fix; then
        echo "WARN: Review failed on attempt $loop_attempt"
        if [ "$loop_attempt" -ge "$MAX_LOOP" ]; then
          echo "ERROR: Review failed on final attempt. Stopping."
          exit 1
        fi
        continue
      fi

      echo "==> Lint+test and review both passed on attempt $loop_attempt"
      loop_passed=true
      break
    done

    if [ "$loop_passed" != "true" ]; then
      echo "ERROR: Lint+test and review did not pass after $MAX_LOOP attempts."
      exit 1
    fi

[doc("""
  Create a git commit for recently completed work.

  Description:
    Uses Claude to generate a proper commit message and commit
    all staged and unstaged changes.

  Usage:
    just claude-commit
""")]
[no-exit-message]
claude-commit:
    #!/usr/bin/env bash
    set -euo pipefail

    echo ""
    echo "==> Committing changes"
    commit_prompt="/git:commit Please create proper commit message and commit changes."
    just claude "$commit_prompt" "git-commit"
    echo ""
    echo "==> Changes committed."

[doc("""
  Full pipeline: plan, implement, verify, lint, test, review, update roadmap, and commit.

  Description:
    Executes the complete task pipeline for a single task.
    This is the main entry point for processing a task from start to finish.

  Steps:
    1-4. Plan, implement, verify, retry (via claude-plan-and-implement)
    5-6. Lint+test and code review loop (via claude-verify-and-fix)
    7. Update roadmap tracking (marks task as done in roadmap.md)
    8. Git commit the changes (via claude-commit)

  Modes:
    ""                    - Full pipeline from scratch
    "continue-plan"       - Continue planning, then verify-and-fix, roadmap, commit
    "continue-implement"  - Continue implementation, then verify-and-fix, roadmap, commit
    "continue-lint-and-test" - Skip plan-and-implement, go straight to verify-and-fix
    "continue-review"     - Skip plan-and-implement and lint-and-test on first pass, start at review

  Parameters:
    task-filename - The task filename (e.g., "add-feature-x.feature.md")
    mode          - Optional mode (see Modes above)

  Usage:
    just claude-vibe "my-task.feature.md"
    just claude-vibe "my-task.feature.md" "continue-plan"
    just claude-vibe "my-task.feature.md" "continue-implement"
    just claude-vibe "my-task.feature.md" "continue-lint-and-test"
    just claude-vibe "my-task.feature.md" "continue-review"
""")]
[no-exit-message]
claude-vibe task-filename mode="":
    #!/usr/bin/env bash
    set -euo pipefail
    source claude-helpers.sh

    TASK_FILENAME="{{ task-filename }}"
    MODE="{{ mode }}"

    echo ""
    echo "================================================================"
    echo "  Processing task: $TASK_FILENAME"
    echo "================================================================"
    echo ""

    # ── Validate mode parameter ───────────────────────────────────────
    case "$MODE" in
      ""|"continue-plan"|"continue-implement"|"continue-lint-and-test"|"continue-review") ;;
      *)
        echo "ERROR: Unknown mode '$MODE'."
        echo "Valid modes: '', 'continue-plan', 'continue-implement', 'continue-lint-and-test', 'continue-review'"
        exit 1
        ;;
    esac

    # ── Steps 1-4: Plan and implement (skipped for continue-lint-and-test and continue-review) ──
    if [ "$MODE" != "continue-lint-and-test" ] && [ "$MODE" != "continue-review" ]; then
      just claude-plan-and-implement "$TASK_FILENAME" "$MODE"
    fi

    # ── Steps 5-6: Verify and fix ─────────────────────────────────────
    if [ "$MODE" = "continue-review" ]; then
      just claude-verify-and-fix "true"
    else
      just claude-verify-and-fix
    fi

    # ── STEP 7: Update roadmap tracking ───────────────────────────────
    echo ""
    echo "==> Step 7: Updating roadmap tracking"
    if [ -f ".specs/roadmap.md" ]; then
      roadmap_prompt="Find the task $TASK_FILENAME in .specs/roadmap.md. Mark this task as done in the roadmap file."
      just claude-json "$roadmap_prompt" "" "roadmap-update"
      echo "==> Roadmap tracking updated."
    else
      echo "==> Roadmap file not found (.specs/roadmap.md), skipping this stage."
    fi

    # ── STEP 8: Git commit ─────────────────────────────────────────
    just claude-commit

[doc("""
  Load open PR comments, fix them, verify, and commit.

  Description:
    Automates the process of addressing PR review comments:
    loads open comments, converts them to tasks, fixes them in parallel,
    verifies the fixes, cleans up, and commits.

  Steps:
    1. Load open PR comments and save as task files
    2. Combine related comments into focused task files
    3. Launch parallel agents to fix all comments
    4. Run verify-and-fix loop (lint+test + review)
    5. Clean up comment task files
    6. Commit the changes

  Modes:
    ""              - Run all steps 1-6
    "continue-fix"  - Skip steps 1-2, start from step 3 (assumes .specs/comments/ already populated)

  Parameters:
    mode - Optional mode (see Modes above)

  Usage:
    just claude-fix-pr-comments
    just claude-fix-pr-comments continue-fix
""")]
[no-exit-message]
claude-fix-pr-comments mode="":
    #!/usr/bin/env bash
    set -euo pipefail

    MODE="{{ mode }}"

    # ── Validate mode parameter ──────────────────────────────────────
    case "$MODE" in
      ""|"continue-fix") ;;
      *)
        echo "ERROR: Unknown mode '$MODE'."
        echo "Valid modes: '', 'continue-fix'"
        exit 1
        ;;
    esac

    # ── Pre-check: GitHub CLI authentication ─────────────────────────
    if ! gh auth status &>/dev/null; then
        echo ""
        echo "GitHub CLI is not authenticated — there's no GH_TOKEN or GITHUB_TOKEN set in the environment, and gh auth login hasn't been run."
        echo ""
        echo "To fix this, you can either:"
        echo ""
        echo "1. Run interactive login — type this in the prompt:"
        echo "   ! gh auth login"
        echo "2. Set a token — export a GitHub personal access token:"
        echo "   ! export GH_TOKEN=ghp_your_token_here"
        exit 1
    fi

    echo ""
    echo "================================================================"
    echo "  Fixing PR comments"
    echo "================================================================"
    echo ""

    # ── Step 1: Load PR comments ────────────────────────────────────
    if [ "$MODE" = "continue-fix" ]; then
      echo "==> Step 1: Skipped (mode=continue-fix)"
    else
      echo "==> Step 1: Loading PR comments"
      mkdir -p .specs/comments
      load_prompt="/pr-comments load ONLY open PR comments for current git branch from github and save it as separate md files to @.specs/comments/. Rewrite them as tasks, avoid summarising: write human feedback as requirements, if it not exists then claude fix suggestion as requirements, add claude issue description and link to the file and line as task context. (if they available). Do not duplicate issues!"
      just claude "$load_prompt" "load-pr-comments"
      echo ""
    fi

    # ── Step 2: Combine comments ────────────────────────────────────
    if [ "$MODE" = "continue-fix" ]; then
      echo "==> Step 2: Skipped (mode=continue-fix)"
    else
      echo "==> Step 2: Combining PR comments"
      combine_prompt="/do-and-judge Analyze and combine related comments or comments that impossible to do in parallel in @.specs/comments/ into a multiple md files. Avoid rewriting them, just combine text, avoid summarising. If there any nitpicks or one line changes, combine them in one aggregation also. Try to keep amount of files no more than 5, but do not combine too much unrelated changes! Each of them will be done by separate, parllel agents. As a result they should have own focused task to produce good result. After combining, delete old files that no longer relevant. CRITICAL: do not left comments folder in intermidiate state, when there are both combined files and their original copies!"
      just claude "$combine_prompt" "combine-pr-comments"
      echo ""
    fi

    # ── Step 3: Fix comments ────────────────────────────────────────
    echo "==> Step 3: Fixing PR comments"
    fix_prompt="/do-in-parallel launch agents to fix all comments in @.specs/comments/ in parallel"
    just claude "$fix_prompt" "fix-pr-comments"
    echo ""

    # ── Step 4: Verify and fix ──────────────────────────────────────
    echo "==> Step 4: Verifying fixes"
    just claude-verify-and-fix

    # ── Step 5: Clean up ────────────────────────────────────────────
    echo "==> Step 5: Cleaning up comment files"
    rm -f .specs/comments/*.md
    echo "==> Comment files cleaned up."

    # ── Step 6: Commit ──────────────────────────────────────────────
    echo "==> Step 6: Committing changes"
    just claude-commit

[doc("""
  Run the full loop: process all tasks from roadmap until complete.

  Description:
    Continuously processes tasks from the roadmap file until all tasks
    are marked as done. For each task, runs the full claude-vibe pipeline.
    Requires a .specs/roadmap.md file to exist.

  Steps:
    1. Extract next incomplete task from roadmap
    2. Run full claude-vibe pipeline for that task
    3. Repeat until all tasks are done

  Usage:
    just claude-loop
""")]
[no-exit-message]
claude-loop:
    #!/usr/bin/env bash
    set -euo pipefail
    source claude-helpers.sh

    # Check if roadmap file exists
    if [ ! -f ".specs/roadmap.md" ]; then
      echo "ERROR: Roadmap file not found (.specs/roadmap.md). Cannot run claude-loop without a roadmap."
      exit 1
    fi

    # ══════════════════════════════════════════════════════════════════
    # MAIN LOOP
    # ══════════════════════════════════════════════════════════════════
    while true; do

      # ── Extract next task from roadmap ──────────────────────────────
      echo ""
      echo "==> Extracting next task from roadmap"
      next_task_prompt="Read @.specs/roadmap.md. Find the next task that is not marked as done. Return in format {allDone: false, filenames: {task: '<task-filename>'}}. Where task filename is not include directory path, only filename, example 'add-agent-trigger-matcher.feature.md'. If all tasks are done, return {allDone: true}."

      next_output=$(just claude-json "$next_task_prompt" "$NEXT_TASK_SCHEMA" "next-task")
      all_done=$(extract_structured_field "$next_output" "allDone" "false")

      if [ "$all_done" = "true" ]; then
        echo ""
        echo "================================================================"
        echo "  All tasks complete! Roadmap fully implemented."
        echo "================================================================"
        exit 0
      fi

      # Parse next task filename
      TASK_FILENAME=$(extract_structured_field "$next_output" "filenames.task" "")
      next_epic=$(extract_structured_field "$next_output" "filenames.epic" "")

      if [ -z "$TASK_FILENAME" ]; then
        echo "ERROR: Could not extract next task filename from response."
        echo "Response: $next_output"
        exit 1
      fi

      echo "==> Next task: $TASK_FILENAME (epic: $next_epic)"

      # Steps 1-8: Full pipeline for the current task
      just claude-vibe "$TASK_FILENAME"

    done  # end main loop


# JSON claude execution examples:

# Without schema:
# just claude-json "What is 2+2?"
# ==> [claude-json] Attempt 1/6
# [{"type":"system","subtype":"init","cwd":"/workspaces/agent-hooks","session_id":"b15a7626-bb05-44d5-9fae-2ee84ff9972f","tools":["Task","TaskOutput","Bash","Glob","Grep","ExitPlanMode","Read","Edit","Write","NotebookEdit","WebFetch","TodoWrite","WebSearch","TaskStop","AskUserQuestion","Skill","EnterPlanMode","EnterWorktree","ExitWorktree","CronCreate","CronDelete","CronList","ToolSearch","mcp__context7__resolve-library-id","mcp__context7__query-docs","LSP"],"mcp_servers":[{"name":"context7","status":"connected"},{"name":"claude.ai Google Calendar","status":"needs-auth"},{"name":"claude.ai Gmail","status":"needs-auth"},{"name":"claude.ai Slack","status":"needs-auth"},{"name":"claude.ai Canva","status":"needs-auth"},{"name":"claude.ai Hugging Face","status":"needs-auth"},{"name":"claude.ai Atlassian","status":"needs-auth"},{"name":"claude.ai Microsoft 365","status":"needs-auth"},{"name":"claude.ai Notion","status":"needs-auth"},{"name":"claude.ai Figma","status":"failed"}],"model":"claude-opus-4-6","permissionMode":"bypassPermissions","slash_commands":["debug","simplify","batch","loop","claude-api","hook-setup-command","claude-code-hooks","class-validator-and-transformer","commander-js","hook-configuration-patterns","claude-code-cli","nest-commander","yaml-schema","sdd:add-task","sdd:brainstorm","sdd:plan","sdd:create-ideas","sdd:implement","sadd:multi-agent-patterns","sadd:judge","sadd:do-in-steps","sadd:do-in-parallel","sadd:launch-sub-agent","sadd:do-and-judge","sadd:do-competitively","sadd:judge-with-debate","sadd:tree-of-thoughts","sadd:subagent-driven-development","git:create-pr","git:load-issues","git:commit","git:compare-worktrees","git:merge-worktree","git:attach-review-to-pr","git:create-worktree","git:notes","git:worktrees","git:analyze-issue","ddd:setup-code-formating","code-review:review-local-changes","code-review:review-pr","compact","context","cost","heapdump","init","pr-comments","release-notes","review","security-review","extra-usage","insights"],"apiKeySource":"none","claude_code_version":"2.1.74","output_style":"default","agents":["general-purpose","statusline-setup","Explore","Plan","sdd:software-architect","sdd:researcher","sdd:tech-lead","sdd:developer","sdd:qa-engineer","sdd:team-lead","sdd:business-analyst","sdd:code-explorer","sdd:tech-writer","sadd:meta-judge","sadd:judge","code-review:code-reviewer","code-review:bug-hunter","code-review:test-coverage-reviewer","code-review:contracts-reviewer","code-review:historical-context-reviewer","code-review:security-auditor"],"skills":["debug","simplify","batch","loop","claude-api","hook-setup-command","claude-code-hooks","class-validator-and-transformer","commander-js","hook-configuration-patterns","claude-code-cli","nest-commander","yaml-schema","sdd:add-task","sdd:brainstorm","sdd:plan","sdd:create-ideas","sdd:implement","sadd:multi-agent-patterns","sadd:judge","sadd:do-in-steps","sadd:do-in-parallel","sadd:launch-sub-agent","sadd:do-and-judge","sadd:do-competitively","sadd:judge-with-debate","sadd:tree-of-thoughts","sadd:subagent-driven-development","git:create-pr","git:load-issues","git:commit","git:compare-worktrees","git:merge-worktree","git:attach-review-to-pr","git:create-worktree","git:notes","git:worktrees","git:analyze-issue","ddd:setup-code-formating","code-review:review-local-changes","code-review:review-pr"],"plugins":[{"name":"typescript-lsp","path":"/home/node/.claude/plugins/cache/claude-plugins-official/typescript-lsp/1.0.0"},{"name":"sdd","path":"/home/node/.claude/plugins/cache/context-engineering-kit/sdd/2.1.1"},{"name":"sadd","path":"/home/node/.claude/plugins/cache/context-engineering-kit/sadd/1.3.0"},{"name":"git","path":"/home/node/.claude/plugins/cache/context-engineering-kit/git/1.2.0"},{"name":"ddd","path":"/home/node/.claude/plugins/cache/context-engineering-kit/ddd/2.0.0"},{"name":"code-review","path":"/home/node/.claude/plugins/cache/context-engineering-kit/code-review/1.1.0"}],"uuid":"98ad5e92-272c-4047-ade2-f29808786c34","fast_mode_state":"off"},{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_01LpnfTf6R7uqC7SrPdHPMM2","type":"message","role":"assistant","content":[{"type":"text","text":"\n\n4"}],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":35339,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":35339},"output_tokens":2,"service_tier":"standard","inference_geo":"not_available"},"context_management":null},"parent_tool_use_id":null,"session_id":"b15a7626-bb05-44d5-9fae-2ee84ff9972f","uuid":"5c08417d-2b68-46b0-a439-c77987bba742"},{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1774382400,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false},"uuid":"3873d31b-6fca-4b2d-863e-e3bf5e7c0bc5","session_id":"b15a7626-bb05-44d5-9fae-2ee84ff9972f"},{"type":"result","subtype":"success","is_error":false,"duration_ms":3214,"duration_api_ms":3092,"num_turns":1,"result":"\n\n4","stop_reason":"end_turn","session_id":"b15a7626-bb05-44d5-9fae-2ee84ff9972f","total_cost_usd":0.22100875,"usage":{"input_tokens":3,"cache_creation_input_tokens":35339,"cache_read_input_tokens":0,"output_tokens":5,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":35339,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard"},"modelUsage":{"claude-opus-4-6":{"inputTokens":3,"outputTokens":5,"cacheReadInputTokens":0,"cacheCreationInputTokens":35339,"webSearchRequests":0,"costUSD":0.22100875,"contextWindow":200000,"maxOutputTokens":32000}},"permission_denials":[],"fast_mode_state":"off","uuid":"a9c6659c-ae8b-4aec-95dc-7e770b1a1454"}]

# With schema:
# claude -p "What is 2+2?" --output-format json --verbose --json-schema '{"type":"object","properties":{"answer":{"type":"number"}},"required":["answer"]}'
# [{"type":"system","subtype":"init","cwd":"/workspaces/agent-hooks","session_id":"d0e8f92a-b33a-477d-9d8f-e239d3ffe9c1","tools":["Task","TaskOutput","Bash","Glob","Grep","ExitPlanMode","Read","Edit","Write","NotebookEdit","WebFetch","TodoWrite","WebSearch","TaskStop","AskUserQuestion","Skill","EnterPlanMode","EnterWorktree","ExitWorktree","CronCreate","CronDelete","CronList","RemoteTrigger","ToolSearch","StructuredOutput","mcp__context7__resolve-library-id","mcp__context7__query-docs","LSP"],"mcp_servers":[{"name":"context7","status":"connected"},{"name":"claude.ai Google Calendar","status":"needs-auth"},{"name":"claude.ai Gmail","status":"needs-auth"},{"name":"claude.ai Slack","status":"needs-auth"},{"name":"claude.ai Canva","status":"needs-auth"},{"name":"claude.ai Hugging Face","status":"needs-auth"},{"name":"claude.ai Figma","status":"pending"},{"name":"claude.ai Atlassian","status":"needs-auth"},{"name":"claude.ai Microsoft 365","status":"needs-auth"},{"name":"claude.ai Notion","status":"needs-auth"}],"model":"claude-opus-4-6[1m]","permissionMode":"bypassPermissions","slash_commands":["update-config","debug","simplify","batch","loop","schedule","claude-api","hook-setup-command","claude-code-hooks","class-validator-and-transformer","commander-js","hook-configuration-patterns","claude-code-cli","nest-commander","yaml-schema","sdd:add-task","sdd:brainstorm","sdd:plan","sdd:create-ideas","sdd:implement","sadd:judge","sadd:do-in-steps","sadd:do-in-parallel","sadd:judge-with-debate","sadd:subagent-driven-development","sadd:do-competitively","sadd:launch-sub-agent","sadd:do-and-judge","sadd:tree-of-thoughts","sadd:multi-agent-patterns","git:load-issues","git:commit","git:compare-worktrees","git:create-pr","git:analyze-issue","git:worktrees","git:merge-worktree","git:attach-review-to-pr","git:create-worktree","git:notes","ddd:setup-code-formating","code-review:review-local-changes","code-review:review-pr","compact","context","cost","heapdump","init","pr-comments","release-notes","review","security-review","extra-usage","insights"],"apiKeySource":"none","claude_code_version":"2.1.81","output_style":"default","agents":["general-purpose","statusline-setup","Explore","Plan","sdd:researcher","sdd:tech-lead","sdd:developer","sdd:qa-engineer","sdd:team-lead","sdd:business-analyst","sdd:code-explorer","sdd:tech-writer","sdd:software-architect","sadd:meta-judge","sadd:judge","code-review:code-reviewer","code-review:bug-hunter","code-review:test-coverage-reviewer","code-review:contracts-reviewer","code-review:historical-context-reviewer","code-review:security-auditor"],"skills":["update-config","debug","simplify","batch","loop","schedule","claude-api","hook-setup-command","claude-code-hooks","class-validator-and-transformer","commander-js","hook-configuration-patterns","claude-code-cli","nest-commander","yaml-schema","sdd:add-task","sdd:brainstorm","sdd:plan","sdd:create-ideas","sdd:implement","sadd:judge","sadd:do-in-steps","sadd:do-in-parallel","sadd:judge-with-debate","sadd:subagent-driven-development","sadd:do-competitively","sadd:launch-sub-agent","sadd:do-and-judge","sadd:tree-of-thoughts","sadd:multi-agent-patterns","git:load-issues","git:commit","git:compare-worktrees","git:create-pr","git:analyze-issue","git:worktrees","git:merge-worktree","git:attach-review-to-pr","git:create-worktree","git:notes","ddd:setup-code-formating","code-review:review-local-changes","code-review:review-pr"],"plugins":[{"name":"typescript-lsp","path":"/home/node/.claude/plugins/cache/claude-plugins-official/typescript-lsp/1.0.0"},{"name":"sdd","path":"/home/node/.claude/plugins/cache/context-engineering-kit/sdd/2.1.1"},{"name":"sadd","path":"/home/node/.claude/plugins/cache/context-engineering-kit/sadd/1.3.0"},{"name":"git","path":"/home/node/.claude/plugins/cache/context-engineering-kit/git/1.2.0"},{"name":"ddd","path":"/home/node/.claude/plugins/cache/context-engineering-kit/ddd/2.0.0"},{"name":"code-review","path":"/home/node/.claude/plugins/cache/context-engineering-kit/code-review/1.1.0"}],"uuid":"c4a8e996-76c1-4f78-92fa-5f3581756ab5","fast_mode_state":"off"},{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_01T7Yfq3LC7pAJuPBomvPV5M","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"The user is asking a simple math question.","signature":"EtIBCkYIDBgCKkBN5NJqJIeLCiAqkfpaWfsOkN1BR8OlbxUPrnJrvLg2wpB10LFEOdpBuDkqar3RoqRqnYDw3tWf0d8v3vqOZ741Egz61JohS03vXIZb2roaDLrE/IEndkBSLmYbYyIwg+Z8H4oVR/Ehh5Jq0qnIeDG+2m34Ij+Fze89xX0xQPfm4Pz3YRCYbj3l8UL2rdxMKjpbpWKIedjDm7p1e/qEvmGZrWRVYvvFrOSwhmlTw+7VAN7TLarXP4UHjjlsTcYuzBEEWABl1Cdu368dGAE="}],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":36041,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":36041},"output_tokens":45,"service_tier":"standard","inference_geo":"not_available"},"context_management":null},"parent_tool_use_id":null,"session_id":"d0e8f92a-b33a-477d-9d8f-e239d3ffe9c1","uuid":"c6441f72-7cc7-41ef-a363-283c1101aee6"},{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_01T7Yfq3LC7pAJuPBomvPV5M","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_018J4oFeohmtqwPgX1d5eptw","name":"StructuredOutput","input":{"answer":4},"caller":{"type":"direct"}}],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":36041,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":36041},"output_tokens":45,"service_tier":"standard","inference_geo":"not_available"},"context_management":null},"parent_tool_use_id":null,"session_id":"d0e8f92a-b33a-477d-9d8f-e239d3ffe9c1","uuid":"f8e2c765-b0fb-4809-adb6-eaebdb251553"},{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_018J4oFeohmtqwPgX1d5eptw","type":"tool_result","content":"Structured output provided successfully"}]},"parent_tool_use_id":null,"session_id":"d0e8f92a-b33a-477d-9d8f-e239d3ffe9c1","uuid":"a06fc570-637c-482e-bb27-d6ae990c9fe4","timestamp":"2026-03-24T15:45:30.695Z","tool_use_result":"Structured output provided successfully"},{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1774382400,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false},"uuid":"3f285401-f025-4aa0-acf7-f9e77a33bc1b","session_id":"d0e8f92a-b33a-477d-9d8f-e239d3ffe9c1"},{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_0145HbJwcFTRtb3qL2iL9gs3","type":"message","role":"assistant","content":[{"type":"text","text":"4."}],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"cache_creation_input_tokens":97,"cache_read_input_tokens":36041,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":97},"output_tokens":1,"service_tier":"standard","inference_geo":"not_available"},"context_management":null},"parent_tool_use_id":null,"session_id":"d0e8f92a-b33a-477d-9d8f-e239d3ffe9c1","uuid":"688222b1-7429-4200-8dd5-18c039c1927c"},{"type":"result","subtype":"success","is_error":false,"duration_ms":8869,"duration_api_ms":8342,"num_turns":2,"result":"4.","stop_reason":"end_turn","session_id":"d0e8f92a-b33a-477d-9d8f-e239d3ffe9c1","total_cost_usd":0.24600299999999997,"usage":{"input_tokens":4,"cache_creation_input_tokens":36138,"cache_read_input_tokens":36041,"output_tokens":84,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":36138,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard"},"modelUsage":{"claude-opus-4-6[1m]":{"inputTokens":4,"outputTokens":84,"cacheReadInputTokens":36041,"cacheCreationInputTokens":36138,"webSearchRequests":0,"costUSD":0.24600299999999997,"contextWindow":1000000,"maxOutputTokens":64000}},"permission_denials":[],"structured_output":{"answer":4},"fast_mode_state":"off","uuid":"f0c40030-8e71-4e34-9624-f5b4d9895585"}]