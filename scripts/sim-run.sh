#!/usr/bin/env bash
# The plumbing every rFabric CI wrapper shares (GitHub Action, GitLab template, Bitbucket pipe):
# choose the `rfabric` commands for the run, map the wrapper inputs to their flags, run them, and
# read their results into the outputs. Every behavior (auth, CI provenance, idempotency,
# registration, apply preview, apply, preflight, launch, wait, test run, cancel on interrupt,
# JUnit, markdown, exit codes) is the CLI's. `source sim-run.sh` defines the functions below
# (the provider scripts).
#
# Inputs: the wrapper inputs as RFABRIC_ + the input name in upper snake case (suite ->
# RFABRIC_SUITE, base-branch -> RFABRIC_BASE_BRANCH). The CLI itself reads RFABRIC_CLIENT_ID,
# RFABRIC_CLIENT_SECRET, RFABRIC_WORKSPACE, RFABRIC_PROFILE, RFABRIC_API_URL, RFABRIC_AUTH_URL
# and the CI provider's identity token. On a pull request, a non-empty
# RFABRIC_PULL_REQUEST_CLIENT_ID replaces RFABRIC_CLIENT_ID (use_pull_request_client_id).
#
# The provider script sets before sim_run: run_event (pull_request; base_branch: any other run
# on the base branch; other), base_branch (the base-branch input, else the provider's default
# branch), identity_token (true when the job holds an identity token the CLI can exchange) and
# fork_run (true when the provider says the job runs in a fork of the repository).
#
# One suite (suite input): register (with image), preflight, `sim run <suite> --wait`.
# Definition directory (dir input), by run_event:
#   pull_request  `eval apply --preview` (problems end the run), then `sim run --dir` (blocking)
#                 and, at the same time when the preview changes a definition and test-run is
#                 auto, `eval test-run --changed` (non-blocking: never the step's exit code)
#   base_branch   `eval apply`, then `sim run --dir`
#   other         `sim run --dir`
# A pull request without an identity token and without client-secret (a fork), or a fork run,
# ends before any CLI call with the notice that a trusted run on the same commit is needed.
#
# sim_run writes into <result-dir>:
#   notice.md            why the run cannot reach rFabric (a fork pull request)
#   artifact.json        the artifact registered from image
#   preflight.json       one suite: the launch preflight
#   definitions.json     dir: the apply preview (pull request) or apply (base branch) result
#   definitions.md       its markdown; definitions-exit-code: its exit code
#   job-id               the evaluation job ids of the blocking run, one per line, each written
#                        as its launch answers
#   report.json          the wait's JSON output: one suite: the report and its failedCases;
#                        dir: one record per suite (suite, version, jobId, exitCode, error, report)
#   junit.xml            one suite: the report's JUnit XML
#   <suite slug>.xml     dir: each suite's JUnit XML
#   scorecard.md         the markdown scorecard (dir: every suite's)
#   test-run.json        dir, pull request: the test run's JSON output (its directory result
#                        when the directory has problems); test-run.md: its markdown;
#                        test-run-exit-code: its exit code
#   summary.md           the notice, else the scorecard (or what ended the run before a
#                        report), the definitions' changes and the test run
#   outputs.json         the outputs: job-id, report-id, conclusion, operational-classification,
#                        job-url (one suite), artifact-id, suites (each suite's result)
#   exit-code            the exit code

set -uo pipefail

# The profile input defaults to production (the CLI resolves its built-in profiles itself).
export RFABRIC_PROFILE="${RFABRIC_PROFILE:-production}"

# The wall deadline when the wall-deadline input is empty, and how much longer than the
# deadline the CLI waits, so the job reaches its deadline and reports before the wait expires.
default_wall_deadline=7200
wait_margin=300

# Set by the provider script (see above).
run_event=other
base_branch=""
identity_token=false
fork_run=false

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

# usage_error <message>: prints the message; returns the CLI's usage exit code.
usage_error() {
  printf 'rfabric sim run: %s\n' "$1" >&2
  return 2
}

# record_job_id <file>: copies stderr through and appends the evaluation job id of each launch
# line (`Simulation job evj_...`) to <file>. It ignores SIGINT and SIGTERM: it must outlive the
# CLI's cancellation, whose output it carries.
record_job_id() {
  local line
  trap '' INT TERM
  while IFS= read -r line || [[ -n $line ]]; do
    printf '%s\n' "$line" >&2
    if [[ $line =~ Simulation\ job\ (evj_[0-9A-Za-z]{26}) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}" >> "$1"
    fi
  done
}

# label_test_run: copies its input to stderr, each line prefixed `test run: `, so the test run's
# output stays apart from the blocking run's in the job log. Ignores SIGINT and SIGTERM, as
# record_job_id does.
label_test_run() {
  local line
  trap '' INT TERM
  while IFS= read -r line || [[ -n $line ]]; do printf 'test run: %s\n' "$line" >&2; done
}

# list_flags <flag> <list>: the flag once per item of a comma or newline separated list.
list_flags() {
  local item
  while IFS= read -r item; do
    item=${item//[[:space:]]/}
    [[ -n $item ]] && printf '%s\0%s\0' "$1" "$item"
  done <<< "${2//,/$'\n'}"
}

# run_key: what the run checks, for comment markers, artifact and report names: the suite, or
# dir:<definition directory>.
run_key() {
  if [[ -n ${RFABRIC_DIR:-} ]]; then printf 'dir:%s' "$RFABRIC_DIR"; else printf '%s' "${RFABRIC_SUITE:-}"; fi
}

# run_title: the run's title in summaries and reports.
run_title() {
  if [[ -n ${RFABRIC_DIR:-} ]]; then
    printf 'rFabric sim run, definition directory %s' "$RFABRIC_DIR"
  else
    printf 'rFabric sim run %s' "${RFABRIC_SUITE:-}"
  fi
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

# fork_notice <result-dir>: writes notice.md and prints it: the pull request cannot reach rFabric.
fork_notice() {
  {
    printf '### %s\n\n' "$(run_title)"
    printf 'Not run: this pull request job cannot reach rFabric. It holds no identity token and no client-secret, '
    printf 'as a pull request from a fork never does (or the job runs in the fork). '
    printf 'A trusted run on the same commit is needed: a maintainer pushes the commit to a branch of this repository '
    printf 'and opens the pull request from it, so its pipeline runs with the credential.\n'
  } > "$1/notice.md"
  printf 'rfabric: %s\n' "$(sed -n 3p "$1/notice.md")" >&2
}

# sim_run_steps <result-dir>: the whole run; returns the step's exit code.
sim_run_steps() {
  local dir=$1 candidate=${RFABRIC_CANDIDATE:-} image=${RFABRIC_IMAGE:-}
  local wall_deadline=${RFABRIC_WALL_DEADLINE:-$default_wall_deadline}
  local args=() launch=() flag

  if [[ -n ${RFABRIC_SUITE:-} && -n ${RFABRIC_DIR:-} ]] || [[ -z ${RFABRIC_SUITE:-} && -z ${RFABRIC_DIR:-} ]]; then
    usage_error "set exactly one of the suite and dir inputs"
    return
  fi
  [[ -n ${RFABRIC_CLIENT_ID:-} ]] || { usage_error "the client-id input is required"; return; }
  use_pull_request_client_id
  if [[ -n $image && -n $candidate ]] || [[ -z $image && -z $candidate ]]; then
    usage_error "set exactly one of the image and candidate inputs"
    return
  fi
  [[ $wall_deadline =~ ^[0-9]+$ ]] || { usage_error "wall-deadline must be a number of seconds, got '$wall_deadline'"; return; }
  if [[ -n ${RFABRIC_DIR:-} ]]; then
    [[ -z ${RFABRIC_CELLS:-} ]] || { usage_error "the cells input goes with suite; dir runs each suite's matrix"; return; }
    case ${RFABRIC_TEST_RUN:-auto} in
      auto | false) ;;
      *) usage_error "test-run must be auto or false, got '$RFABRIC_TEST_RUN'"; return ;;
    esac
  elif [[ -n ${RFABRIC_SUITES:-}${RFABRIC_TAGS:-} ]]; then
    usage_error "the suites and tags inputs go with dir"
    return
  fi
  if [[ ${RFABRIC_BASELINE:-} == auto && -z $base_branch ]]; then
    usage_error "baseline auto reads the base branch: set the base-branch input"
    return
  fi

  if [[ $run_event == pull_request ]] && { [[ $fork_run == true ]] || [[ $identity_token != true && -z ${RFABRIC_CLIENT_SECRET:-} ]]; }; then
    fork_notice "$dir"
    return 1
  fi

  if [[ -n $image ]]; then
    args=(artifact-build register "$image" --output json)
    [[ -n ${RFABRIC_WEIGHTS:-} ]] && args+=(--weights "$RFABRIC_WEIGHTS")
    [[ -n ${RFABRIC_MODEL:-} ]] && args+=(--model "$RFABRIC_MODEL")
    [[ -n ${RFABRIC_MODEL_NAME:-} ]] && args+=(--model-name "$RFABRIC_MODEL_NAME")
    forwarding rfabric "${args[@]}" > "$dir/artifact.json" || return
    candidate=$(jq -r '.id // empty' "$dir/artifact.json")
    [[ -n $candidate ]] || { printf 'rfabric artifact-build register printed no artifact id\n' >&2; return 1; }
  fi

  # The launch flags both modes share.
  launch=(--candidate "$candidate" --wall-deadline "$wall_deadline")
  if [[ ${RFABRIC_BASELINE:-} == auto ]]; then
    launch+=(--baseline auto --base-branch "$base_branch")
  elif [[ -n ${RFABRIC_BASELINE:-} ]]; then
    launch+=(--baseline "$RFABRIC_BASELINE")
  fi
  [[ -n ${RFABRIC_POOL:-} ]] && launch+=(--pool "$RFABRIC_POOL")
  [[ -n ${RFABRIC_MAX_WORKER_HOURS:-} ]] && launch+=(--max-worker-hours "$RFABRIC_MAX_WORKER_HOURS")
  [[ -n ${RFABRIC_MAX_PARALLEL_GPU:-} ]] && launch+=(--max-parallel-gpu "$RFABRIC_MAX_PARALLEL_GPU")
  [[ -n ${RFABRIC_MAX_PARALLEL_CPU:-} ]] && launch+=(--max-parallel-cpu "$RFABRIC_MAX_PARALLEL_CPU")

  if [[ -n ${RFABRIC_DIR:-} ]]; then
    directory_steps "$dir" "$candidate" "$wall_deadline" "${launch[@]}"
    return
  fi

  args=(sim run "$RFABRIC_SUITE" "${launch[@]}")
  while IFS= read -r -d '' flag; do args+=("$flag"); done < <(list_flags --cell "${RFABRIC_CELLS:-}")
  forwarding rfabric "${args[@]}" --preflight --output json > "$dir/preflight.json" || return
  forwarding rfabric "${args[@]}" --wait --wait-timeout "$((wall_deadline + wait_margin))s" \
    --junit "$dir/junit.xml" --markdown "$dir/scorecard.md" --output json \
    > "$dir/report.json" 2> >(record_job_id "$dir/job-id")
}

# directory_steps <result-dir> <candidate> <wall deadline> <launch flags...>: the definition
# directory's commands for run_event; returns the step's exit code: the definitions command's
# when it fails, else the blocking run's.
directory_steps() {
  local dir=$1 candidate=$2 wall_deadline=$3 code selection=() args=() flag test_run="" definitions=()
  shift 3
  while IFS= read -r -d '' flag; do selection+=("$flag"); done \
    < <(list_flags --suite "${RFABRIC_SUITES:-}"; list_flags --tag "${RFABRIC_TAGS:-}")

  case $run_event in
    pull_request) definitions=(eval apply --dir "$RFABRIC_DIR" --preview) ;;
    base_branch) definitions=(eval apply --dir "$RFABRIC_DIR") ;;
  esac
  if [[ ${#definitions[@]} -gt 0 ]]; then
    forwarding rfabric "${definitions[@]}" --markdown "$dir/definitions.md" --output json > "$dir/definitions.json"
    code=$?
    printf '%s\n' "$code" > "$dir/definitions-exit-code"
    [[ $code -eq 0 ]] || return "$code"
  fi

  if [[ $run_event == pull_request && ${RFABRIC_TEST_RUN:-auto} == auto ]] && definitions_changed "$dir" entries; then
    args=(eval test-run --dir "$RFABRIC_DIR" --candidate "$candidate" --changed "${selection[@]}"
      --wall-deadline "$wall_deadline" --wait-timeout "$((wall_deadline + wait_margin))s" --markdown "$dir/test-run.md")
    # --baseline auto never picks a test run's baseline: the test run takes an explicit one only.
    [[ -n ${RFABRIC_BASELINE:-} && $RFABRIC_BASELINE != auto ]] && args+=(--baseline "$RFABRIC_BASELINE")
    [[ -n ${RFABRIC_POOL:-} ]] && args+=(--pool "$RFABRIC_POOL")
    start rfabric "${args[@]}" --output json > "$dir/test-run.json" 2> >(label_test_run)
    test_run=$started
  fi

  forwarding rfabric sim run --dir "$RFABRIC_DIR" "$@" "${selection[@]}" \
    --wait-timeout "$((wall_deadline + wait_margin))s" --junit-dir "$dir" --markdown "$dir/scorecard.md" --output json \
    > "$dir/report.json" 2> >(record_job_id "$dir/job-id")
  code=$?

  if [[ -n $test_run ]]; then
    finish "$test_run"
    printf '%s\n' "$?" > "$dir/test-run-exit-code"
  fi
  return "$code"
}

# definitions_changed <result-dir> <entries|any>: the definitions result changes a definition
# (entries: an entry not unchanged; any: that, or a definition no longer in the directory).
definitions_changed() {
  [[ -s $1/definitions.json ]] && jq -e --arg what "$2" \
    'any(.entries[]?; .action != "unchanged") or ($what == "any" and ((.removed // []) | length) > 0)' \
    "$1/definitions.json" > /dev/null 2>&1
}

# has_report <result-dir> / preflight_blocked <result-dir>: what ended a one-suite run. The file
# test comes first: jq 1.6 (the image's) exits 0 for -e on empty input.
has_report() {
  [[ -s $1/report.json ]] && jq -e 'type == "object" and has("jobId")' "$1/report.json" > /dev/null 2>&1
}
preflight_blocked() {
  [[ -s $1/preflight.json ]] && jq -e '.ok == false' "$1/preflight.json" > /dev/null 2>&1
}
# has_suite_records <result-dir>: a definition directory run's report.json holds suite records.
has_suite_records() {
  [[ -s $1/report.json ]] && jq -e 'type == "array"' "$1/report.json" > /dev/null 2>&1
}

# job_urls <result-dir>: writes job-urls.json, each blocking job's page as {job id: url}. Runs
# in this shell, never in $(...): an interrupt must reach the CLI it runs.
job_urls() {
  local id url
  printf '{}' > "$1/job-urls.json"
  [[ -s $1/job-id ]] || return 0
  while IFS= read -r id; do
    url=""
    if forwarding rfabric evaluation-job get "$id" --output json > "$1/job.json"; then
      url=$(jq -r '.appUrl // empty' "$1/job.json" 2> /dev/null)
    fi
    jq -c --arg id "$id" --arg url "$url" '. + {($id): $url}' "$1/job-urls.json" > "$1/job-urls.next" \
      && mv "$1/job-urls.next" "$1/job-urls.json"
  done < <(sort -u "$1/job-id")
}

# sim_run_finish <result-dir> <exit-code>: writes outputs.json, summary.md and exit-code. jq
# reads the report from its file, never from an argument: a report with many failed cases
# passes the size limit of one argument.
sim_run_finish() {
  local dir=$1 code=$2 job_id="" report=/dev/null artifact_id=""
  [[ -s $dir/job-id ]] && job_id=$(head -n 1 "$dir/job-id")
  if has_report "$dir" || has_suite_records "$dir"; then
    report="$dir/report.json"
  fi
  if has_report "$dir"; then
    [[ -n $job_id ]] || { job_id=$(jq -r '.jobId' "$report") && printf '%s\n' "$job_id" > "$dir/job-id"; }
  fi
  if [[ -s $dir/artifact.json ]]; then
    artifact_id=$(jq -r '.id // empty' "$dir/artifact.json" 2> /dev/null)
  fi
  job_urls "$dir"
  jq -n --slurpfile reports "$report" --slurpfile urls "$dir/job-urls.json" --arg artifact "$artifact_id" \
    --arg suite "${RFABRIC_SUITE:-}" --arg job "$job_id" --argjson code "$code" \
    '($reports[0] // null) as $report | $urls[0] as $urls
    | def result($report): {reportId: ($report.id // ""), conclusion: ($report.conclusionStatus // ""),
        operationalClassification: ($report.operationalClassification // "")};
    (if $suite == "" then
       [($report // [])[] | {suite, version, jobId: (.jobId // ""), exitCode} + result(.report)
         + {jobUrl: ($urls[.jobId // ""] // "")}]
     elif $job != "" or $report != null then
       [{suite: $suite, version: null, jobId: $job, exitCode: $code} + result($report) + {jobUrl: ($urls[$job] // "")}]
     else [] end) as $suites
    | (if $suite == "" then {} else ($suites[0] // {}) end) as $one
    | {
        "job-id": ($one.jobId // ""),
        "report-id": ($one.reportId // ""),
        "conclusion": ($one.conclusion // ""),
        "operational-classification": ($one.operationalClassification // ""),
        "job-url": ($one.jobUrl // ""),
        "artifact-id": $artifact,
        "suites": $suites
      }' > "$dir/outputs.json"

  if [[ -s $dir/notice.md ]]; then
    cp "$dir/notice.md" "$dir/summary.md"
  elif [[ -n ${RFABRIC_DIR:-} ]]; then
    directory_summary "$dir" "$code" > "$dir/summary.md"
  elif [[ -s $dir/scorecard.md ]]; then
    cp "$dir/scorecard.md" "$dir/summary.md"
  else
    {
      printf '### %s\n\n' "$(run_title)"
      if preflight_blocked "$dir"; then
        printf 'The launch preflight blocked the run:\n\n'
        jq -r '.blockers[] | "- `\(.code)`: \(.message)"' "$dir/preflight.json"
      elif [[ -n $job_id ]]; then
        printf 'Evaluation job [%s](%s) ended without a report (rfabric exit code %s).\n' "$job_id" "$(output_value "$dir" job-url)" "$code"
      else
        printf 'The run ended before a launch (rfabric exit code %s); the job log says why.\n' "$code"
      fi
    } > "$dir/summary.md"
  fi
  printf '%s\n' "$code" > "$dir/exit-code"
}

# directory_summary <result-dir> <exit-code>: a definition directory run's summary: the blocking
# run's scorecard (or what ended the run before it), the definitions' changes (when the
# definitions command failed or changed something), then the test run.
directory_summary() {
  local dir=$1 code=$2 definitions_code=0 test_run_code
  [[ -s $dir/definitions-exit-code ]] && definitions_code=$(< "$dir/definitions-exit-code")
  if [[ -s $dir/scorecard.md ]]; then
    cat "$dir/scorecard.md"
  elif [[ $definitions_code -eq 0 ]]; then
    printf '### %s\n\nThe run ended before a launch (rfabric exit code %s); the job log says why.\n' "$(run_title)" "$code"
  fi
  if [[ -s $dir/definitions.md ]] && { [[ $definitions_code -ne 0 ]] || definitions_changed "$dir" any; }; then
    printf '\n'
    cat "$dir/definitions.md"
  elif [[ $definitions_code -ne 0 ]]; then
    printf '### %s\n\nThe definitions could not be read (rfabric exit code %s); the job log says why.\n' "$(run_title)" "$definitions_code"
  fi
  if [[ -s $dir/test-run-exit-code ]]; then
    test_run_code=$(< "$dir/test-run-exit-code")
    printf '\n'
    if [[ -s $dir/test-run.md ]]; then
      cat "$dir/test-run.md"
    else
      printf '# Test run - not yet approved\n\nThe test run ended before a report (rfabric exit code %s); it never fails this check.\n\n' "$test_run_code"
      jq -r '.problems[]? | "- `\(.path)`: \(.message)"' "$dir/test-run.json" 2> /dev/null
    fi
  fi
}

# sim_run <result-dir>: the whole run; returns the exit code.
sim_run() {
  local dir=$1 code
  mkdir -p "$dir" || return 1
  rm -f "$dir"/*.xml "$dir"/*.md "$dir"/*.json "$dir"/{job-id,exit-code,definitions-exit-code,test-run-exit-code}
  sim_run_steps "$dir"
  code=$?
  sim_run_finish "$dir" "$code"
  return "$code"
}

# output_value <result-dir> <output name>: one output, empty when unset; a JSON value compact.
output_value() {
  jq -r --arg name "$2" '.[$name] // "" | if type == "string" then . else tojson end' "$1/outputs.json" 2> /dev/null
}

# comment_marker: the hidden first line of the run's pull request comment, by which the
# wrappers find it again (github.sh, gitlab.sh) and readers find the pipe's comments.
comment_marker() {
  printf '<!-- rfabric-sim-run:%s -->' "$(run_key)"
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
