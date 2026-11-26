#!/usr/bin/env bash
# The CI job side every rFabric CI wrapper entry point shares (GitHub Actions, GitLab templates,
# Bitbucket pipe), whatever `rfabric` command it runs: the run's event, the client id the CLI
# signs in with, the refusal of a pull request that cannot reach rFabric, signal forwarding to
# the CLI processes, the definition directory apply, the result directory, the outputs and
# summary it publishes, and provider REST calls. `source ci-job.sh` defines the variables and
# functions below. A run script sources it and maps the inputs to `rfabric` flags:
# sim-run.sh (simulation suites) or training-run.sh (a training run); a provider script
# (github.sh, gitlab.sh, pipe.sh) sources exactly one run script.
#
# The run script sets run_script to its name (sim-run, training-run: the result directory, comment
# marker and report names carry it) and defines:
#   run_key                      what the run checks, for comment markers and report names
#   run_title                    the run's title in summaries and reports
#   run_steps <dir>              the run's commands; returns the step's exit code
#   run_finish <dir> <code>      writes outputs.json and summary.md
#   run_outputs                  the output names, one per line, in publishing order
#   cancel_launched <dir>        cancels what the run launched (GitLab after_script)
#
# Inputs: the wrapper inputs as RFABRIC_ + the input name in upper snake case (base-branch ->
# RFABRIC_BASE_BRANCH). The CLI itself reads RFABRIC_CLIENT_ID, RFABRIC_CLIENT_SECRET,
# RFABRIC_WORKSPACE, RFABRIC_PROFILE, RFABRIC_API_URL, RFABRIC_AUTH_URL and the CI provider's
# identity token. On a pull request, a non-empty RFABRIC_PULL_REQUEST_CLIENT_ID replaces
# RFABRIC_CLIENT_ID (use_pull_request_client_id).
#
# The provider script's detect_run sets, before the run: run_event (pull_request; base_branch:
# any other run on the base branch; other), base_branch (the base-branch input, else the
# provider's default branch), identity_token (true when the job holds an identity token the CLI
# can exchange) and fork_run (true when the provider says the job runs in a fork of the
# repository).
#
# A run script writes into its result directory, read here and by the provider scripts:
#   notice.md                why the run cannot reach rFabric (fork_notice)
#   definitions.json         dir: the apply preview (pull request) or apply (base branch) result
#   definitions.md           its markdown; definitions-exit-code: its exit code
#   summary.md               what the job summary and the pull request comment show
#   outputs.json             the outputs, one key per output name
#   exit-code                the exit code

set -uo pipefail

# The profile input defaults to production (the CLI resolves its built-in profiles itself).
export RFABRIC_PROFILE="${RFABRIC_PROFILE:-production}"

# Set by the run script (see above).
run_script=""

# Set by the provider script (see above); base_branch is read by the run script.
run_event=other
# shellcheck disable=SC2034
base_branch=""
identity_token=false
fork_run=false
# Set by the provider script with fork_run when it could not read what proves a pull request
# comes from this repository (a missing jq, an unreadable event file); fork_notice names it.
fork_reason=""

# rfabric_children are the CLI processes `start` runs; the traps send them the SIGINT or SIGTERM
# this shell receives, so an interrupted wait reaches each CLI, which cancels its jobs.
rfabric_children=()
forward_signal() {
  local pid
  for pid in "${rfabric_children[@]}"; do kill -s "$1" "$pid" 2> /dev/null; done
  return 0
}
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM

# start <command...>: runs the command in the background as a child the traps signal; sets
# started to its pid. Redirections of the call apply to the command. Bash starts background
# commands with SIGINT ignored; the CLI installs its own handler.
started=""
start() {
  "$@" &
  started=$!
  rfabric_children+=("$started")
}

# finish <pid>: waits for a started command; returns its exit code.
finish() {
  local pid=$1 code child kept=()
  while :; do
    wait "$pid"
    code=$?
    kill -0 "$pid" 2> /dev/null || break
  done
  for child in "${rfabric_children[@]}"; do [[ $child == "$pid" ]] || kept+=("$child"); done
  rfabric_children=("${kept[@]}")
  return "$code"
}

# forwarding <command...>: start, then finish; returns the command's exit code.
forwarding() {
  start "$@"
  finish "$started"
}

# record_launch <pattern> <file>: copies stderr through and appends to <file> the id the
# pattern's group captures in each launch line. It ignores SIGINT and SIGTERM: it must outlive
# the CLI's cancellation, whose output it carries.
record_launch() {
  local line
  trap '' INT TERM
  while IFS= read -r line || [[ -n $line ]]; do
    printf '%s\n' "$line" >&2
    if [[ $line =~ $1 ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}" >> "$2"
    fi
  done
}

# usage_error <rfabric command> <message>: prints the message as the command's; returns the
# CLI's usage exit code.
usage_error() {
  printf 'rfabric %s: %s\n' "$1" "$2" >&2
  return 2
}

# list_flags <flag> <list>: the flag once per item of a comma or newline separated list.
list_flags() {
  local item
  while IFS= read -r item; do
    item=${item//[[:space:]]/}
    [[ -n $item ]] && printf '%s\0%s\0' "$1" "$item"
  done <<< "${2//,/$'\n'}"
}

# use_pull_request_client_id: on a pull request, the pull-request-client-id input, when set,
# becomes the client id the CLI signs in with; every other run keeps client-id. Call it after
# the provider's detect_run.
use_pull_request_client_id() {
  if [[ $run_event == pull_request && -n ${RFABRIC_PULL_REQUEST_CLIENT_ID:-} ]]; then
    export RFABRIC_CLIENT_ID=$RFABRIC_PULL_REQUEST_CLIENT_ID
  fi
  return 0
}

# fork_pull_request: the run is a pull request that must not reach rFabric: a fork run (the
# provider's detect_run saw a fork, whatever token or client-secret the job holds), or a job
# without an identity token and without client-secret (as a fork's job is). The run script ends
# it with fork_notice before any CLI call.
fork_pull_request() {
  [[ $run_event == pull_request ]] && { [[ $fork_run == true ]] || [[ $identity_token != true && -z ${RFABRIC_CLIENT_SECRET:-} ]]; }
}

# fork_notice <result-dir> <run title>: writes notice.md and prints it: the pull request cannot
# reach rFabric.
fork_notice() {
  {
    printf '### %s\n\n' "$2"
    printf 'Not run: this pull request job cannot reach rFabric. It comes from a fork, or holds neither an identity '
    printf 'token nor a client-secret. '
    [[ -n $fork_reason ]] && printf 'It is treated as a fork because %s. ' "$fork_reason"
    printf 'A trusted run on the same commit is needed: a maintainer pushes the commit to a branch of this repository '
    printf 'and opens the pull request from it, so its pipeline runs with the credential.\n'
  } > "$1/notice.md"
  printf 'rfabric: %s\n' "$(sed -n 3p "$1/notice.md")" >&2
}

# apply_definitions <result-dir> <rfabric command group> [apply flags...]: the definition
# directory (dir input) for run_event: a pull request runs `<group> apply --preview`, a
# base-branch run `<group> apply` with the flags, any other run nothing. Writes
# definitions.json, definitions.md and definitions-exit-code; returns the command's exit code.
apply_definitions() {
  local dir=$1 group=$2 code definitions=()
  shift 2
  case $run_event in
    pull_request) definitions=("$group" apply --dir "$RFABRIC_DIR" --preview) ;;
    base_branch) definitions=("$group" apply --dir "$RFABRIC_DIR" "$@") ;;
    *) return 0 ;;
  esac
  forwarding rfabric "${definitions[@]}" --markdown "$dir/definitions.md" --output json > "$dir/definitions.json"
  code=$?
  printf '%s\n' "$code" > "$dir/definitions-exit-code"
  return "$code"
}

# definitions_changed <result-dir> <entries|any>: the definitions result changes a definition
# (entries: an entry not unchanged; any: that, or a definition no longer in the directory).
definitions_changed() {
  [[ -s $1/definitions.json ]] && jq -e --arg what "$2" \
    'any(.entries[]?; .action != "unchanged") or ($what == "any" and ((.removed // []) | length) > 0)' \
    "$1/definitions.json" > /dev/null 2>&1
}

# definitions_summary <result-dir> <definitions exit code>: the definitions' part of the
# summary: their markdown when the command failed or changed something, else nothing.
definitions_summary() {
  if [[ -s $1/definitions.md ]] && { [[ $2 -ne 0 ]] || definitions_changed "$1" any; }; then
    printf '\n'
    cat "$1/definitions.md"
  elif [[ $2 -ne 0 ]]; then
    printf '### %s\n\nThe definitions could not be read (rfabric exit code %s); the job log says why.\n' "$(run_title)" "$2"
  fi
}

# ci_run <result-dir>: the whole run: empties the result directory of earlier results, runs
# run_steps, then run_finish, and writes exit-code; returns the exit code.
ci_run() {
  local dir=$1 code
  mkdir -p "$dir" || return 1
  rm -f "$dir"/*.xml "$dir"/*.md "$dir"/*.json "$dir"/*-id "$dir"/*exit-code
  run_steps "$dir"
  code=$?
  run_finish "$dir" "$code"
  printf '%s\n' "$code" > "$dir/exit-code"
  return "$code"
}

# output_value <result-dir> <output name>: one output, empty when unset; a JSON value compact.
output_value() {
  jq -r --arg name "$2" '.[$name] // "" | if type == "string" then . else tojson end' "$1/outputs.json" 2> /dev/null
}

# comment_marker: the hidden first line of the run's pull request comment, by which the
# wrappers find it again (github.sh, gitlab.sh) and readers find the pipe's comments.
comment_marker() {
  printf '<!-- rfabric-%s:%s -->' "$run_script" "$(run_key)"
}

# comment_body <result-dir> <marker>: the pull request comment, the marker then summary.md,
# cut below the smallest provider limit.
comment_body() {
  printf '%s\n' "$2"
  head -c 60000 "$1/summary.md"
}

# slug <text>: the text with every character outside [A-Za-z0-9._-] replaced by '-', for
# names a provider restricts (artifact names, report ids).
slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

# api_call <method> <url> <json body or empty> [curl options...]: one REST call of a provider
# script; prints the response body, sets api_status to the HTTP status (000 when unreachable)
# and returns 0 on a 2xx answer. Call it outside $(...) to read api_status. curl reads the body
# from stdin, never from an argument: a large body passes the size limit of one argument.
api_status=""
api_call() {
  local method=$1 url=$2 body=$3 response
  shift 3
  local options=("$@")
  [[ -n $body ]] && options+=(-H "Content-Type: application/json" --data-binary @-)
  response=$(printf '%s' "$body" | curl -sS -X "$method" "${options[@]}" -w '\n%{http_code}' "$url")
  api_status=${response##*$'\n'}
  printf '%s' "${response%$'\n'*}"
  [[ $api_status == 2?? ]]
}
