#!/usr/bin/env bash
# The simulation run script every rFabric CI wrapper shares (GitHub Action, GitLab template,
# Bitbucket pipe): choose the `rfabric` commands for the run, map the wrapper inputs to their
# flags, run them, and read their results into the outputs. Every behavior (auth, CI provenance,
# idempotency, registration, apply preview, apply, preflight, launch, wait, test run, cancel on
# interrupt, JUnit, markdown, exit codes) is the CLI's. `source sim-run.sh` sources ci-job.sh
# (the run's event, client id, fork refusal, signal forwarding, result directory, outputs) and
# defines the run script functions ci-job.sh names (the provider scripts run it with ci_run).
#
# Inputs: the wrapper inputs as RFABRIC_ + the input name in upper snake case (suite ->
# RFABRIC_SUITE, base-branch -> RFABRIC_BASE_BRANCH); ci-job.sh lists what the CLI reads itself.
# The run's event is ci-job.sh's run_event, base_branch, identity_token and fork_run, which the
# provider script's detect_run sets before ci_run.
#
# One suite (suite input): register (with image), preflight, `sim run <suite> --wait`.
# Definition directory (dir input), by run_event:
#   pull_request  `eval apply --preview` (problems end the run), then `sim run --dir` (blocking)
#                 and, at the same time when the preview changes a definition and test-run is
#                 auto, `eval test-run --changed` (non-blocking: never the step's exit code)
#   base_branch   `eval apply`, then `sim run --dir`
#   other         `sim run --dir`
# A pull request that cannot reach rFabric (ci-job.sh fork_pull_request) ends before any CLI
# call with the notice that a trusted run on the same commit is needed.
#
# The run writes into <result-dir>, beside ci-job.sh's files:
#   artifact.json        the artifact registered from image
#   preflight.json       one suite: the launch preflight
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

set -uo pipefail

# shellcheck source=ci-job.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-job.sh"
run_script=sim-run

# The wall deadline when the wall-deadline input is empty, and how much longer than the
# deadline the CLI waits, so the job reaches its deadline and reports before the wait expires.
default_wall_deadline=7200
wait_margin=300

# launch_line: the CLI's line for each evaluation job it launches; its group is the job id.
launch_line='Simulation job (evj_[0-9A-Za-z]{26})'

# label_test_run: copies its input to stderr, each line prefixed `test run: `, so the test run's
# output stays apart from the blocking run's in the job log. Ignores SIGINT and SIGTERM, as
# record_launch does.
label_test_run() {
  local line
  trap '' INT TERM
  while IFS= read -r line || [[ -n $line ]]; do printf 'test run: %s\n' "$line" >&2; done
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

# run_outputs: the output names, in publishing order.
run_outputs() {
  printf '%s\n' job-id report-id conclusion operational-classification job-url artifact-id suites
}

# run_steps <result-dir>: the whole run; returns the step's exit code.
run_steps() {
  local dir=$1 candidate=${RFABRIC_CANDIDATE:-} image=${RFABRIC_IMAGE:-}
  local wall_deadline=${RFABRIC_WALL_DEADLINE:-$default_wall_deadline}
  local args=() launch=() flag

  if [[ -n ${RFABRIC_SUITE:-} && -n ${RFABRIC_DIR:-} ]] || [[ -z ${RFABRIC_SUITE:-} && -z ${RFABRIC_DIR:-} ]]; then
    usage_error "sim run" "set exactly one of the suite and dir inputs"
    return
  fi
  [[ -n ${RFABRIC_CLIENT_ID:-} ]] || { usage_error "sim run" "the client-id input is required"; return; }
  use_pull_request_client_id
  if [[ -n $image && -n $candidate ]] || [[ -z $image && -z $candidate ]]; then
    usage_error "sim run" "set exactly one of the image and candidate inputs"
    return
  fi
  [[ $wall_deadline =~ ^[0-9]+$ ]] || { usage_error "sim run" "wall-deadline must be a number of seconds, got '$wall_deadline'"; return; }
  if [[ -n ${RFABRIC_DIR:-} ]]; then
    [[ -z ${RFABRIC_CELLS:-} ]] || { usage_error "sim run" "the cells input goes with suite; dir runs each suite's matrix"; return; }
    case ${RFABRIC_TEST_RUN:-auto} in
      auto | false) ;;
      *) usage_error "sim run" "test-run must be auto or false, got '$RFABRIC_TEST_RUN'"; return ;;
    esac
  elif [[ -n ${RFABRIC_SUITES:-}${RFABRIC_TAGS:-} ]]; then
    usage_error "sim run" "the suites and tags inputs go with dir"
    return
  fi
  if [[ ${RFABRIC_BASELINE:-} == auto && -z $base_branch ]]; then
    usage_error "sim run" "baseline auto reads the base branch: set the base-branch input"
    return
  fi

  if fork_pull_request; then
    fork_notice "$dir" "$(run_title)"
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
    > "$dir/report.json" 2> >(record_launch "$launch_line" "$dir/job-id")
}

# directory_steps <result-dir> <candidate> <wall deadline> <launch flags...>: the definition
# directory's commands for run_event; returns the step's exit code: the definitions command's
# when it fails, else the blocking run's.
directory_steps() {
  local dir=$1 candidate=$2 wall_deadline=$3 code selection=() args=() flag test_run=""
  shift 3
  while IFS= read -r -d '' flag; do selection+=("$flag"); done \
    < <(list_flags --suite "${RFABRIC_SUITES:-}"; list_flags --tag "${RFABRIC_TAGS:-}")

  apply_definitions "$dir" eval || return

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
    > "$dir/report.json" 2> >(record_launch "$launch_line" "$dir/job-id")
  code=$?

  if [[ -n $test_run ]]; then
    finish "$test_run"
    printf '%s\n' "$?" > "$dir/test-run-exit-code"
  fi
  return "$code"
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

# run_finish <result-dir> <exit-code>: writes outputs.json and summary.md. jq reads the report
# from its file, never from an argument: a report with many failed cases passes the size limit
# of one argument.
run_finish() {
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
  definitions_summary "$dir" "$definitions_code"
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

# cancel_launched <result-dir>: cancels the blocking run's evaluation jobs.
cancel_launched() {
  local job_id
  [[ -s $1/job-id ]] || return 0
  while IFS= read -r job_id; do
    forwarding rfabric evaluation-job cancel "$job_id" --output json > /dev/null
  done < <(sort -u "$1/job-id")
}
