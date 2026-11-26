#!/usr/bin/env bash
# Bitbucket pipe entry point: the ENTRYPOINT of ghcr.io/rfabric/cli (pipe.yml).
#
# The run script (ci-job.sh): training-run.sh when RFABRIC_LAUNCH_TEMPLATE is set, else
# sim-run.sh. Runs it with its result directory test-results/rfabric/ of the clone directory
# (Bitbucket's test reporting picks up a sim run's JUnit reports there), writes the outputs to
# rfabric-result.json in the clone directory, for a sim run posts a Code Insights report (and
# an annotation per failed case, up to Bitbucket's 1000 per report) on BITBUCKET_COMMIT, with
# RFABRIC_BITBUCKET_TOKEN on a pull request pipeline posts one new pull request comment per
# run, and exits with the step's code. `source pipe.sh` defines the functions only
# (tests/unit.sh).
#
# Signals: this script is the container's first process; a SIGTERM or SIGINT it receives
# reaches the CLI, which cancels the job or the waited training run. Bitbucket documents no
# signal or grace period for a stopped step and runs no after-script then: the wall deadline
# (sim) bounds the job.
#
# Reads the pipe variables (RFABRIC_* as in the run script; RFABRIC_WALL_DEADLINE defaults
# to 7200 in sim-run.sh), Bitbucket's BITBUCKET_* variables (secretless:
# BITBUCKET_STEP_OIDC_TOKEN, read by the CLI), and RFABRIC_BITBUCKET_TOKEN.
# RFABRIC_BITBUCKET_PROXY (the Pipelines API proxy, default http://host.docker.internal:29418)
# and RFABRIC_BITBUCKET_API_URL (default https://api.bitbucket.org/2.0) exist for tests.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n ${RFABRIC_LAUNCH_TEMPLATE:-} ]]; then
  # shellcheck source=training-run.sh
  source "$here/training-run.sh"
else
  # shellcheck source=sim-run.sh
  source "$here/sim-run.sh"
fi

clone=${BITBUCKET_CLONE_DIR:-$PWD}
dir="$clone/test-results/rfabric"
proxy=${RFABRIC_BITBUCKET_PROXY:-http://host.docker.internal:29418}
api_url=${RFABRIC_BITBUCKET_API_URL:-https://api.bitbucket.org/2.0}
# Bitbucket's limit of annotations per report.
annotation_limit=1000

# detect_run: the run's event (ci-job.sh). Bitbucket gives a step no default branch: the
# base branch is RFABRIC_BASE_BRANCH, else main. A pull request pipeline is a pull request,
# any other pipeline on the base branch a base-branch run. A pull request pipeline without the
# identity token (as in a fork) and without RFABRIC_CLIENT_SECRET gets the fork notice. Bitbucket
# names no source repository of a pull request, so a fork is not detected from its variables: a
# fork's pipeline runs in the fork, without this repository's secured variables, and its identity
# token carries the fork's repositoryUuid, which no credential trust of this repository admits.
detect_run() {
  base_branch=${RFABRIC_BASE_BRANCH:-main}
  if [[ -n ${BITBUCKET_PR_ID:-} ]]; then
    run_event=pull_request
  elif [[ ${BITBUCKET_BRANCH:-} == "$base_branch" ]]; then
    run_event=base_branch
  fi
  [[ -n ${BITBUCKET_STEP_OIDC_TOKEN:-} ]] && identity_token=true
  return 0
}

# insights_api <method> <path> <body>: a Code Insights call through the Pipelines proxy, which
# authenticates it (plain http to the API host, as Bitbucket documents for the proxy).
insights_api() {
  api_call "$1" "http://api.bitbucket.org/2.0/repositories/$BITBUCKET_REPO_FULL_NAME/commit/$BITBUCKET_COMMIT$2" "$3" \
    --proxy "$proxy"
}

# insights <exit-code>: the run's Code Insights report on BITBUCKET_COMMIT, then an annotation
# per case in the CLI's failedCases (a definition directory run: every suite's, named by its
# suite), at most 100 per request and annotation_limit in all; past the limit the report
# details say how many cases are annotated.
insights() {
  # report: the report file, else /dev/null (an empty report); a file, never an argument: a
  # report with many failed cases passes the size limit of one argument.
  local code=$1 path result job_id job_url classification report=/dev/null details body batch
  local definitions_code=0
  path="/reports/rfabric-sim-run-$(slug "$(run_key)")"
  job_id=$(output_value "$dir" job-id)
  job_url=$(output_value "$dir" job-url)
  classification=$(output_value "$dir" operational-classification)
  [[ -s $dir/definitions-exit-code ]] && definitions_code=$(< "$dir/definitions-exit-code")
  case $classification:$code in
    complete_pass:* | :0) result=PASSED ;;
    :40) result=PENDING ;;
    *) result=FAILED ;;
  esac
  if [[ -s $dir/notice.md ]]; then
    details=$(sed -n 3p "$dir/notice.md")
  elif has_report "$dir"; then
    report="$dir/report.json"
    details=$(jq -r --argjson limit "$annotation_limit" '"Conclusion: \(.conclusionStatus) (\(.operationalClassification // "unclassified")).",
      (.failedCases // [] | length | if . > $limit then "\(.) failed cases, the first \($limit) annotated; the scorecard lists them all." else empty end),
      (.gateChain // [] | if length > 0 then "Gate chain: " + (map(.key + " " + .status
        + (if (.reasonCodes // []) | length > 0 then " (" + (.reasonCodes | join(", ")) + ")" else "" end)) | join("; ")) + "." else empty end)' "$report")
  elif has_suite_records "$dir"; then
    details=$(jq -r --argjson limit "$annotation_limit" '(.[] | "\(.suite)@\(.version): " + (if .report then
        "\(.report.conclusionStatus) (\(.report.operationalClassification // "unclassified"))." else "exit \(.exitCode): \(.error // "no report")." end)),
      ([.[].report.failedCases // [] | .[]] | length | if . > $limit then "\(.) failed cases, the first \($limit) annotated; the scorecard lists them all." else empty end)' "$dir/report.json")
  elif preflight_blocked "$dir"; then
    details=$(jq -r '"The launch preflight blocked the run: " + (.blockers | map(.code + ": " + .message) | join("; "))' "$dir/preflight.json")
  elif [[ $definitions_code -ne 0 ]]; then
    details="rfabric eval apply ended the run (exit code $definitions_code); the pipeline log lists why."
  elif [[ -n $job_id ]]; then
    details="Evaluation job $job_id ended without a report (rfabric exit code $code)."
  else
    details="The run ended before a launch (rfabric exit code $code); the pipeline log says why."
  fi
  body=$(jq -n --arg title "$(run_title)" --arg details "${details:0:2000}" --arg result "$result" \
    --arg job "$job_id" --arg url "$job_url" --slurpfile reports "$report" '($reports[0] // {}) as $report | {
      title: $title,
      details: $details,
      report_type: "TEST",
      reporter: "rFabric",
      result: $result,
      data: ([
        (if $report.conclusionStatus then {title: "Conclusion", type: "TEXT", value: $report.conclusionStatus} else empty end),
        (if $report.operationalClassification then {title: "Operational classification", type: "TEXT", value: $report.operationalClassification} else empty end),
        (if $job != "" and $url != "" then {title: "Evaluation job", type: "LINK", value: {text: $job, href: $url}} else empty end),
        (if $report.runCounts.total != null then {title: "Runs", type: "NUMBER", value: $report.runCounts.total} else empty end),
        (if $report.runCounts.successful != null then {title: "Successful runs", type: "NUMBER", value: $report.runCounts.successful} else empty end)
      ])
    } + (if $url != "" then {link: $url} else {} end)')
  if ! insights_api PUT "$path" "$body" > /dev/null; then
    echo "rfabric: could not write the Code Insights report (Bitbucket answered $api_status)" >&2
    return 0
  fi

  has_report "$dir" || has_suite_records "$dir" || return 0
  while IFS= read -r batch; do
    if ! insights_api POST "$path/annotations" "$batch" > /dev/null; then
      echo "rfabric: could not write the Code Insights annotations (Bitbucket answered $api_status)" >&2
      return 0
    fi
  done < <(jq -c --arg url "$job_url" --argjson limit "$annotation_limit" '(if type == "array"
      then [.[] | .suite as $suite | .report.failedCases // [] | .[] | . + {suite: $suite}]
      else .failedCases // [] end) | .[:$limit]
    | map({
        external_id: .runId,
        annotation_type: "BUG",
        result: "FAILED",
        severity: "HIGH",
        summary: ((if .suite then "\(.suite): " else "" end) + "\(.caseKey) [\(.side)]: \(.reason)")[:450],
        details: "Run \(.runId), cell \(.cellId // "none"), scenario \(.scenarioId), seed \(.seed): \(.outcome)."
      } + (if $url != "" then {link: $url} else {} end))
    | range(0; length; 100) as $start | .[$start:$start + 100]' "$dir/report.json")
  return 0
}

# bitbucket_api <method> <url> [body]: api_call with RFABRIC_BITBUCKET_TOKEN.
bitbucket_api() {
  api_call "$1" "$2" "${3:-}" -H "Authorization: Bearer $RFABRIC_BITBUCKET_TOKEN"
}

# comment: posts one new pull request comment per run, the run's marker first. The pipe never
# lists or edits comments: Bitbucket's documented token types give no check that a comment is
# the pipe's own, and anyone can copy a marker.
comment() {
  local body
  body=$(comment_body "$dir" "$(comment_marker)" | jq -Rs '{content: {raw: .}}')
  bitbucket_api POST "$api_url/repositories/$BITBUCKET_REPO_FULL_NAME/pullrequests/$BITBUCKET_PR_ID/comments" "$body" > /dev/null \
    || echo "rfabric: could not post the pull request comment (Bitbucket answered $api_status)" >&2
}

[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

cd "$clone" || exit 1
detect_run
ci_run "$dir"
code=$?
cp "$dir/outputs.json" "$clone/rfabric-result.json"
# Without what the run checks (a usage error) there is nothing to report on. Code Insights
# carries a sim run's verdict.
if [[ -n $(run_key) && -n ${BITBUCKET_COMMIT:-} && -n ${BITBUCKET_REPO_FULL_NAME:-} ]]; then
  [[ $run_script == sim-run ]] && insights "$code"
  if [[ -n ${RFABRIC_BITBUCKET_TOKEN:-} && -n ${BITBUCKET_PR_ID:-} ]]; then
    comment
  fi
fi
exit "$code"
