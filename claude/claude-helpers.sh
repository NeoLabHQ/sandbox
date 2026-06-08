#!/usr/bin/env bash
# Shared helper functions for claude justfile recipes.
# Source this file at the top of each recipe that needs these utilities:
#   source "$(dirname "${BASH_SOURCE[0]:-$0}")/../scripts/claude-helpers.sh"
# Or from justfile recipes:
#   source "scripts/claude-helpers.sh"

# ── Configuration defaults ──────────────────────────────────────────
MAX_SESSION_RETRIES="${MAX_SESSION_RETRIES:-12}"
SESSION_RETRY_WAIT="${SESSION_RETRY_WAIT:-3600}"    # 1 hour in seconds
COMMAND_TIMEOUT="${COMMAND_TIMEOUT:-21600}"          # 6 hours in seconds
PERMISSION_MODE="${PERMISSION_MODE:---permission-mode auto}"

DRAFT_DIR="${DRAFT_DIR:-.specs/tasks/draft}"
TODO_DIR="${TODO_DIR:-.specs/tasks/todo}"
DONE_DIR="${DONE_DIR:-.specs/tasks/done}"

# ── JSON schemas for structured output validation ───────────────────
COMPLETED_SCHEMA='{"type":"object","properties":{"completed":{"type":"boolean"},"message":{"type":"string"}},"required":["completed"]}'
NEXT_TASK_SCHEMA='{"type":"object","properties":{"allDone":{"type":"boolean"},"filenames":{"type":"object","properties":{"epic":{"type":"string"},"task":{"type":"string"}}}},"required":["allDone"]}'

# ── Classify error for diagnostic logging ─────────────────────────
# Outputs a human-readable error category string to stdout.
# Used solely for diagnostic log messages, not for retry decisions.
describe_error_type() {
  local stderr_text="$1"
  local lower
  lower=$(echo "$stderr_text" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *"session limit"*|*"rate limit"*|*"too many requests"*|*"rate_limit"*|*"overloaded"*|*"429"*|*"503"*)
      echo "session/rate limit" ;;
    *)
      echo "unknown error" ;;
  esac
}

# ── Wait for a PID with a timeout ─────────────────────────────────
# Returns 0 if the process exits before timeout, 1 if it times out.
# Uses a polling loop with 1-second granularity so we can detect
# process exit without relying on non-portable `timeout` flags.
#
# Args: pid, timeout_seconds
wait_with_timeout() {
  local pid="$1"
  local timeout_secs="$2"
  local elapsed=0

  while [ "$elapsed" -lt "$timeout_secs" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      # Process has exited
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  # Still running after timeout
  return 1
}

# ── Generic retry loop ────────────────────────────────────────────
# Retries a caller-provided command callback on ANY non-zero exit,
# waiting SESSION_RETRY_WAIT between attempts. The Claude CLI does not
# reliably report session/rate limit details in stderr, so we retry on
# all failures.
#
# WAIT BEHAVIOR: After each failed attempt (and before the next retry),
# this function sleeps for SESSION_RETRY_WAIT seconds (default: 3600 =
# 1 hour). This long pause is intentional -- it allows session/rate
# limits to expire before the next attempt. The flow on failure is:
#
#   command fails → capture stderr → check max retries → log warning
#     → sleep SESSION_RETRY_WAIT (default 1 hour) → retry
#
# The callback function is invoked as:
#   <callback> <attempt_number> <stderr_file>
# It MUST redirect its command's stderr through the stderr_file, e.g.:
#   my_command 2> >(tee "$stderr_file" >&2)
#
# TIMEOUT & CHILD CLEANUP: The callback is run in the background. On
# timeout, `pkill -P` kills all child processes (e.g. `claude`, `jq` in
# a pipe) of the background subshell, then the subshell itself is killed.
#
# Args: label, callback_fn_name
_retry_loop() {
  local label="$1"
  local callback="$2"
  local attempt=0
  local stderr_file
  stderr_file=$(mktemp)

  while true; do
    attempt=$((attempt + 1))
    echo "==> [$label] Attempt $attempt/$((MAX_SESSION_RETRIES + 1))" >&2

    # ── Run callback with COMMAND_TIMEOUT (default 6 hours) ──
    # The callback runs in the background. On timeout we use pkill -P
    # to terminate all child processes (e.g. claude, jq in a pipe),
    # then kill the background subshell itself.
    local cmd_exit=0
    "$callback" "$attempt" "$stderr_file" &
    local cmd_pid=$!

    if wait_with_timeout "$cmd_pid" "$COMMAND_TIMEOUT"; then
      # Command completed within timeout -- capture its exit code
      cmd_exit=0
      wait "$cmd_pid" 2>/dev/null || cmd_exit=$?
    else
      # Timed out -- kill children first (piped commands like claude | jq),
      # then the background subshell itself.
      echo "WARN: [$label] Command timed out after ${COMMAND_TIMEOUT}s (attempt $attempt/$((MAX_SESSION_RETRIES + 1))). Killing pid $cmd_pid and children." >&2
      pkill -TERM -P "$cmd_pid" 2>/dev/null || true
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 2
      pkill -KILL -P "$cmd_pid" 2>/dev/null || true
      kill -KILL "$cmd_pid" 2>/dev/null || true
      wait "$cmd_pid" 2>/dev/null || true
      cmd_exit=1
      echo "command timed out after ${COMMAND_TIMEOUT}s (attempt $attempt/$((MAX_SESSION_RETRIES + 1)))" > "$stderr_file"
    fi

    if [ "$cmd_exit" -eq 0 ]; then
      rm -f "$stderr_file"
      return 0
    fi

    local captured_stderr
    captured_stderr=$(cat "$stderr_file" 2>/dev/null || echo "")

    if [ "$attempt" -gt "$MAX_SESSION_RETRIES" ]; then
      echo "ERROR: [$label] Failed after $((MAX_SESSION_RETRIES + 1)) attempts. Stopping." >&2
      echo "  stderr: $captured_stderr" >&2
      rm -f "$stderr_file"
      return 1
    fi

    local error_type
    error_type=$(describe_error_type "$captured_stderr")

    if [ "$error_type" = "session/rate limit" ]; then
      echo "WARN: [$label] Session/rate limit hit. Waiting ${SESSION_RETRY_WAIT}s before retry ($attempt/$((MAX_SESSION_RETRIES + 1)))..." >&2
    else
      echo "WARN: [$label] Command failed (non-zero exit). Waiting ${SESSION_RETRY_WAIT}s before retry ($attempt/$((MAX_SESSION_RETRIES + 1)))..." >&2
      echo "  stderr: $captured_stderr" >&2
    fi

    # ── RETRY WAIT: sleep SESSION_RETRY_WAIT seconds (default 1 hour) ──
    # This is the sole retry-delay point. Every failed attempt passes
    # through here before looping back to the next attempt.
    local sleep_start sleep_end
    sleep_start=$(date '+%Y-%m-%d %H:%M:%S')
    sleep_end=$(date -d "+${SESSION_RETRY_WAIT} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
      || date -v "+${SESSION_RETRY_WAIT}S" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
      || echo "unknown")
    echo "INFO: [$label] Sleeping at $sleep_start, expected resume at $sleep_end" >&2
    sleep "$SESSION_RETRY_WAIT"
  done
}

# ── Shared retry wrapper for any CLI error ────────────────────────
# Retries a shell function on ANY non-zero exit, waiting SESSION_RETRY_WAIT
# between attempts.
#
# Args: label, fn_name, [fn_args...]
run_with_session_retry() {
  local label="$1"; shift
  local _rsr_args=("$@")

  # Callback invoked by _retry_loop on each attempt.
  # Captures _rsr_args from the enclosing scope.
  # NOTE: Bash has no block scoping -- _rsr_attempt leaks to the global
  # namespace. This is acceptable because justfile recipes run in separate
  # shell processes, so no cross-recipe collisions occur.
  _rsr_attempt() {
    local _attempt="$1"
    local _stderr_file="$2"
    "${_rsr_args[@]}" 2> >(tee "$_stderr_file" >&2)
  }

  _retry_loop "$label" _rsr_attempt
}

# ── Raw claude streaming call (no retry) ────────────────────────────
# Internal helper for run_plan_or_implement_retry. Not intended for
# direct use -- prefer `just claude` which wraps this with retry logic.
_raw_claude_stream() {
  local prompt="$1"
  # shellcheck disable=SC2086
  claude -p "$prompt" \
    --output-format stream-json --verbose --include-partial-messages \
    $PERMISSION_MODE | \
    jq -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text'
}

# ── Plan/implement with retry and prompt switching ──────────────────
# First attempt uses initial_prompt; retries use continue_prompt.
#
# Args: label, initial_prompt, continue_prompt
run_plan_or_implement_retry() {
  local label="$1"
  local _rpir_initial="$2"
  local _rpir_continue="$3"

  # Callback invoked by _retry_loop on each attempt.
  # Captures _rpir_initial and _rpir_continue from the enclosing scope.
  # NOTE: Bash has no block scoping -- _rpir_attempt leaks to the global
  # namespace. This is acceptable because justfile recipes run in separate
  # shell processes, so no cross-recipe collisions occur.
  _rpir_attempt() {
    local _attempt="$1"
    local _stderr_file="$2"
    if [ "$_attempt" -eq 1 ]; then
      _raw_claude_stream "$_rpir_initial" 2> >(tee "$_stderr_file" >&2)
    else
      _raw_claude_stream "$_rpir_continue" 2> >(tee "$_stderr_file" >&2)
    fi
  }

  _retry_loop "$label" _rpir_attempt
}

# ── Extract structured_output field from claude JSON response ───────
# Handles both array format (claude --verbose JSON output, where the
# result element has type=="result") and plain object format.
# Falls back to parsing .result as JSON if structured_output is absent.
extract_structured_field() {
  local json="$1"
  local field="$2"
  local fallback="${3:-}"

  # Normalize: if input is an array, extract the result element
  local result_obj
  result_obj=$(echo "$json" | jq -r '
    if type == "array" then
      (.[] | select(.type == "result"))
    else
      .
    end
  ' 2>/dev/null || echo "")

  if [ -z "$result_obj" ]; then
    echo "$fallback"
    return
  fi

  local value
  value=$(echo "$result_obj" | jq -r ".structured_output.$field // empty" 2>/dev/null || echo "")
  if [ -n "$value" ] && [ "$value" != "null" ]; then
    echo "$value"
    return
  fi

  # Fallback: try parsing .result as JSON
  local result_text
  result_text=$(echo "$result_obj" | jq -r '.result // empty' 2>/dev/null || echo "")
  if [ -n "$result_text" ]; then
    value=$(echo "$result_text" | jq -r ".$field // empty" 2>/dev/null || echo "")
    if [ -n "$value" ] && [ "$value" != "null" ]; then
      echo "$value"
      return
    fi
  fi

  echo "$fallback"
}
