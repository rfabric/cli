#!/usr/bin/env bash
# The plumbing every rFabric CI wrapper shares (GitHub Action, GitLab template, Bitbucket pipe):
# map the wrapper inputs to `rfabric` flags, run the CLI, read its result into the outputs.
# Every behavior (auth, CI provenance, idempotency, registration, preflight, launch, wait,
# cancel on interrupt, JUnit, markdown scorecard, exit codes) is the CLI's.
#
#   sim-run.sh <result-dir>   register (with RFABRIC_IMAGE), preflight, launch and wait;
#                             exits with the exit code of the CLI call that ended the run
#   source sim-run.sh         defines the functions below (the provider scripts)
#
# Inputs: the wrapper inputs as RFABRIC_ + the input name in upper snake case (suite ->
# RFABRIC_SUITE, model-name -> RFABRIC_MODEL_NAME). The CLI itself reads RFABRIC_CLIENT_ID,
# RFABRIC_CLIENT_SECRET, RFABRIC_WORKSPACE, RFABRIC_PROFILE, RFABRIC_API_URL,
# RFABRIC_AUTH_URL and the CI provider's identity token.
#
# sim_run writes into <result-dir>:
#   artifact.json   the artifact registered from RFABRIC_IMAGE
#   preflight.json  the launch preflight
#   job-id          the evaluation job id, written as soon as the launch answers
#   report.json     the wait's JSON output: the report and its failedCases
#   junit.xml       the report's JUnit XML
#   scorecard.md    the report's markdown scorecard
#   job.json        the evaluation job, read after the run
#   summary.md      scorecard.md, else what ended the run before a report
#   outputs.json    the outputs: job-id, report-id, conclusion, operational-classification,
#                   job-url, artifact-id
#   exit-code       the exit code

set -uo pipefail

# The profile input defaults to production (the CLI resolves its built-in profiles itself).
export RFABRIC_PROFILE="${RFABRIC_PROFILE:-production}"

# The wall deadline when the wall-deadline input is empty, and how much longer than the
# deadline the CLI waits, so the job reaches its deadline and reports before the wait expires.
default_wall_deadline=7200
wait_margin=300

# rfabric_child is the process `forwarding` waits for; the traps send it the SIGINT or SIGTERM
# this shell receives, so an interrupted wait reaches the CLI, which cancels the job.
rfabric_child=""
forward_signal() {
  if [[ -n $rfabric_child ]]; then kill -s "$1" "$rfabric_child" 2> /dev/null; fi
  return 0
}
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM

# forwarding <command...>: runs the command in the background and waits for it, so the traps
# above can signal it; returns its exit code. Redirections of the call apply to the command.
# Bash starts background commands with SIGINT ignored; the CLI installs its own handler.
forwarding() {
  local code
  "$@" &
  rfabric_child=$!
  while :; do
    wait "$rfabric_child"
    code=$?
    kill -0 "$rfabric_child" 2> /dev/null || break
  done
  rfabric_child=""
  return "$code"
}

# usage_error <message>: prints the message; returns the CLI's usage exit code.
usage_error() {
  printf 'rfabric sim run: %s\n' "$1" >&2
  return 2
}

# record_job_id <file>: copies stderr through and writes the first evaluation job id it shows
# (the launch line) to <file>. It ignores SIGINT and SIGTERM: it must outlive the CLI's
# cancellation, whose output it carries.
record_job_id() {
  local line
  trap '' INT TERM
  while IFS= read -r line || [[ -n $line ]]; do
    printf '%s\n' "$line" >&2
    if [[ ! -s $1 && $line =~ (evj_[0-9A-Za-z]{26}) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}" > "$1"
    fi
  done
}

# sim_run_steps <result-dir>: register, preflight, launch and wait; returns the exit code of
# the CLI call that ended the run.
sim_run_steps() {
  local dir=$1 candidate=${RFABRIC_CANDIDATE:-} image=${RFABRIC_IMAGE:-}
  local wall_deadline=${RFABRIC_WALL_DEADLINE:-$default_wall_deadline}
  local cells=${RFABRIC_CELLS:-} args=() cell

  [[ -n ${RFABRIC_SUITE:-} ]] || { usage_error "the suite input is required"; return; }
  [[ -n ${RFABRIC_CLIENT_ID:-} ]] || { usage_error "the client-id input is required"; return; }
  if [[ -n $image && -n $candidate ]] || [[ -z $image && -z $candidate ]]; then
    usage_error "set exactly one of the image and candidate inputs"
    return
  fi
  [[ $wall_deadline =~ ^[0-9]+$ ]] || { usage_error "wall-deadline must be a number of seconds, got '$wall_deadline'"; return; }

  if [[ -n $image ]]; then
    args=(artifact-build register "$image" --output json)
    [[ -n ${RFABRIC_WEIGHTS:-} ]] && args+=(--weights "$RFABRIC_WEIGHTS")
    [[ -n ${RFABRIC_MODEL:-} ]] && args+=(--model "$RFABRIC_MODEL")
    [[ -n ${RFABRIC_MODEL_NAME:-} ]] && args+=(--model-name "$RFABRIC_MODEL_NAME")
    forwarding rfabric "${args[@]}" > "$dir/artifact.json" || return
    candidate=$(jq -r '.id // empty' "$dir/artifact.json")
    [[ -n $candidate ]] || { printf 'rfabric artifact-build register printed no artifact id\n' >&2; return 1; }
  fi

  args=(sim run "$RFABRIC_SUITE" --candidate "$candidate" --wall-deadline "$wall_deadline")
  [[ -n ${RFABRIC_BASELINE:-} ]] && args+=(--baseline "$RFABRIC_BASELINE")
  # Cells are comma or newline separated.
  while IFS= read -r cell; do
    cell=${cell//[[:space:]]/}
    [[ -n $cell ]] && args+=(--cell "$cell")
  done <<< "${cells//,/$'\n'}"
  [[ -n ${RFABRIC_POOL:-} ]] && args+=(--pool "$RFABRIC_POOL")
  [[ -n ${RFABRIC_MAX_WORKER_HOURS:-} ]] && args+=(--max-worker-hours "$RFABRIC_MAX_WORKER_HOURS")
  [[ -n ${RFABRIC_MAX_PARALLEL_GPU:-} ]] && args+=(--max-parallel-gpu "$RFABRIC_MAX_PARALLEL_GPU")
  [[ -n ${RFABRIC_MAX_PARALLEL_CPU:-} ]] && args+=(--max-parallel-cpu "$RFABRIC_MAX_PARALLEL_CPU")

  forwarding rfabric "${args[@]}" --preflight --output json > "$dir/preflight.json" || return

  forwarding rfabric "${args[@]}" --wait --wait-timeout "$((wall_deadline + wait_margin))s" \
    --junit "$dir/junit.xml" --markdown "$dir/scorecard.md" --output json \
    > "$dir/report.json" 2> >(record_job_id "$dir/job-id")
}

# has_report <result-dir> / preflight_blocked <result-dir>: what ended the run. The file test
# comes first: jq 1.6 (the image's) exits 0 for -e on empty input.
has_report() {
  [[ -s $1/report.json ]] && jq -e 'type == "object" and has("jobId")' "$1/report.json" > /dev/null 2>&1
}
preflight_blocked() {
  [[ -s $1/preflight.json ]] && jq -e '.ok == false' "$1/preflight.json" > /dev/null 2>&1
}

# sim_run_finish <result-dir> <exit-code>: reads the job, writes outputs.json, summary.md and
# exit-code. jq reads the report from its file, never from an argument: a report with many
# failed cases passes the size limit of one argument.
sim_run_finish() {
  local dir=$1 code=$2 job_id="" job_url="" report=/dev/null artifact_id=""
  [[ -s $dir/job-id ]] && job_id=$(head -n 1 "$dir/job-id")
  if has_report "$dir"; then
    report="$dir/report.json"
    [[ -n $job_id ]] || job_id=$(jq -r '.jobId' "$report")
  fi
  if [[ -s $dir/artifact.json ]]; then
    artifact_id=$(jq -r '.id // empty' "$dir/artifact.json" 2> /dev/null)
  fi
  if [[ -n $job_id ]] && forwarding rfabric evaluation-job get "$job_id" --output json > "$dir/job.json"; then
    job_url=$(jq -r '.appUrl // empty' "$dir/job.json" 2> /dev/null)
  fi
  jq -n --slurpfile reports "$report" --arg job "$job_id" --arg url "$job_url" --arg artifact "$artifact_id" \
    '($reports[0] // {}) as $report | {
    "job-id": $job,
    "report-id": ($report.id // ""),
    "conclusion": ($report.conclusionStatus // ""),
    "operational-classification": ($report.operationalClassification // ""),
    "job-url": $url,
    "artifact-id": $artifact
  }' > "$dir/outputs.json"

  if [[ -s $dir/scorecard.md ]]; then
    cp "$dir/scorecard.md" "$dir/summary.md"
  else
    {
      printf '### rFabric sim run %s\n\n' "${RFABRIC_SUITE:-}"
      if preflight_blocked "$dir"; then
        printf 'The launch preflight blocked the run:\n\n'
        jq -r '.blockers[] | "- `\(.code)`: \(.message)"' "$dir/preflight.json"
      elif [[ -n $job_id ]]; then
        printf 'Evaluation job [%s](%s) ended without a report (rfabric exit code %s).\n' "$job_id" "$job_url" "$code"
      else
        printf 'The run ended before a launch (rfabric exit code %s); the job log says why.\n' "$code"
      fi
    } > "$dir/summary.md"
  fi
  printf '%s\n' "$code" > "$dir/exit-code"
}

# sim_run <result-dir>: the whole run; returns the exit code.
sim_run() {
  local dir=$1 code
  mkdir -p "$dir" || return 1
  rm -f "$dir"/{artifact.json,preflight.json,job-id,report.json,junit.xml,scorecard.md,job.json,summary.md,outputs.json,exit-code}
  sim_run_steps "$dir"
  code=$?
  sim_run_finish "$dir" "$code"
  return "$code"
}

# output_value <result-dir> <output name>: one output, empty when unset.
output_value() {
  jq -r --arg name "$2" '.[$name] // ""' "$1/outputs.json" 2> /dev/null
}

# comment_marker <suite>: the hidden first line of the suite's pull request comment, by which
# the wrappers find it again (github.sh, gitlab.sh) and readers find the pipe's comments.
comment_marker() {
  printf '<!-- rfabric-sim-run:%s -->' "$1"
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

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# -eq 1 ]] || { echo "usage: sim-run.sh <result-dir>" >&2; exit 2; }
  sim_run "$1"
  exit $?
fi
