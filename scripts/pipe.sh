#!/usr/bin/env bash
# Bitbucket pipe entry point: the ENTRYPOINT of ghcr.io/rfabric/cli (pipe.yml).
#
# Runs the suite (sim-run.sh) with the JUnit report under test-results/rfabric/ of the clone
# directory (Bitbucket's test reporting picks it up), writes the outputs to
# rfabric-result.json in the clone directory, posts a Code Insights report (and an annotation
# per failed case, up to Bitbucket's 1000 per report) on BITBUCKET_COMMIT, with
# RFABRIC_BITBUCKET_TOKEN on a pull request pipeline posts one new pull request comment per run,
# and exits with the CLI's code. `source pipe.sh` defines the functions only
# (tests/unit.sh).
#
# Signals: this script is the container's first process; a SIGTERM or SIGINT it receives
# reaches the CLI, which cancels the job. Bitbucket documents no signal or grace period for a
# stopped step and runs no after-script then: the wall deadline bounds the job.
#
# Reads the pipe variables (RFABRIC_* as in sim-run.sh; RFABRIC_WALL_DEADLINE defaults to
# 7200 there), Bitbucket's BITBUCKET_* variables (secretless: BITBUCKET_STEP_OIDC_TOKEN, read
# by the CLI), and RFABRIC_BITBUCKET_TOKEN. RFABRIC_BITBUCKET_PROXY (the Pipelines API proxy,
# default http://host.docker.internal:29418) and RFABRIC_BITBUCKET_API_URL (default
# https://api.bitbucket.org/2.0) exist for tests.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sim-run.sh
source "$here/sim-run.sh"

clone=${BITBUCKET_CLONE_DIR:-$PWD}
dir="$clone/test-results/rfabric"
proxy=${RFABRIC_BITBUCKET_PROXY:-http://host.docker.internal:29418}
api_url=${RFABRIC_BITBUCKET_API_URL:-https://api.bitbucket.org/2.0}
# Bitbucket's limit of annotations per report.
annotation_limit=1000

# insights_api <method> <path> <body>: a Code Insights call through the Pipelines proxy, which
# authenticates it (plain http to the API host, as Bitbucket documents for the proxy).
insights_api() {
  api_call "$1" "http://api.bitbucket.org/2.0/repositories/$BITBUCKET_REPO_FULL_NAME/commit/$BITBUCKET_COMMIT$2" "$3" \
    --proxy "$proxy"
}

# insights <exit-code>: the Code Insights report of the suite on BITBUCKET_COMMIT, then an
# annotation per case in the CLI's failedCases, at most 100 per request and annotation_limit in
# all; past the limit the report details say how many cases are annotated.
insights() {
  # report: the report file, else /dev/null (an empty report); a file, never an argument: a
  # report with many failed cases passes the size limit of one argument.
  local code=$1 path result job_id job_url classification report=/dev/null details body batch
  path="/reports/rfabric-sim-run-$(slug "$RFABRIC_SUITE")"
  job_id=$(output_value "$dir" job-id)
  job_url=$(output_value "$dir" job-url)
  classification=$(output_value "$dir" operational-classification)
  case $classification in
    complete_pass) result=PASSED ;;
    "") if [[ $code -eq 40 ]]; then result=PENDING; else result=FAILED; fi ;;
    *) result=FAILED ;;
  esac
  if has_report "$dir"; then
    report="$dir/report.json"
    details=$(jq -r --argjson limit "$annotation_limit" '"Conclusion: \(.conclusionStatus) (\(.operationalClassification // "unclassified")).",
      (.failedCases // [] | length | if . > $limit then "\(.) failed cases, the first \($limit) annotated; the scorecard lists them all." else empty end),
      (.gateChain // [] | if length > 0 then "Gate chain: " + (map(.key + " " + .status
        + (if (.reasonCodes // []) | length > 0 then " (" + (.reasonCodes | join(", ")) + ")" else "" end)) | join("; ")) + "." else empty end)' "$report")
  elif preflight_blocked "$dir"; then
    details=$(jq -r '"The launch preflight blocked the run: " + (.blockers | map(.code + ": " + .message) | join("; "))' "$dir/preflight.json")
  elif [[ -n $job_id ]]; then
    details="Evaluation job $job_id ended without a report (rfabric exit code $code)."
  else
    details="The run ended before a launch (rfabric exit code $code); the pipeline log says why."
  fi
  body=$(jq -n --arg suite "$RFABRIC_SUITE" --arg details "${details:0:2000}" --arg result "$result" \
    --arg job "$job_id" --arg url "$job_url" --slurpfile reports "$report" '($reports[0] // {}) as $report | {
      title: "rFabric sim run \($suite)",
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

  has_report "$dir" || return 0
  while IFS= read -r batch; do
    if ! insights_api POST "$path/annotations" "$batch" > /dev/null; then
      echo "rfabric: could not write the Code Insights annotations (Bitbucket answered $api_status)" >&2
      return 0
    fi
  done < <(jq -c --arg url "$job_url" --argjson limit "$annotation_limit" '.failedCases // [] | .[:$limit]
    | map({
        external_id: .runId,
        annotation_type: "BUG",
        result: "FAILED",
        severity: "HIGH",
        summary: "\(.caseKey) [\(.side)]: \(.reason)"[:450],
        details: "Run \(.runId), cell \(.cellId // "none"), scenario \(.scenarioId), seed \(.seed): \(.outcome)."
      } + (if $url != "" then {link: $url} else {} end))
    | range(0; length; 100) as $start | .[$start:$start + 100]' "$dir/report.json")
  return 0
}

# bitbucket_api <method> <url> [body]: api_call with RFABRIC_BITBUCKET_TOKEN.
bitbucket_api() {
  api_call "$1" "$2" "${3:-}" -H "Authorization: Bearer $RFABRIC_BITBUCKET_TOKEN"
}

# comment: posts one new pull request comment per run, the suite's marker first. The pipe never
# lists or edits comments: Bitbucket's documented token types give no check that a comment is
# the pipe's own, and anyone can copy a marker.
comment() {
  local body
  body=$(comment_body "$dir" "$(comment_marker "$RFABRIC_SUITE")" | jq -Rs '{content: {raw: .}}')
  bitbucket_api POST "$api_url/repositories/$BITBUCKET_REPO_FULL_NAME/pullrequests/$BITBUCKET_PR_ID/comments" "$body" > /dev/null \
    || echo "rfabric: could not post the pull request comment (Bitbucket answered $api_status)" >&2
}

[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

cd "$clone" || exit 1
sim_run "$dir"
code=$?
cp "$dir/outputs.json" "$clone/rfabric-result.json"
# Without a suite (a usage error) there is nothing to report on.
if [[ -n ${RFABRIC_SUITE:-} && -n ${BITBUCKET_COMMIT:-} && -n ${BITBUCKET_REPO_FULL_NAME:-} ]]; then
  insights "$code"
  if [[ -n ${RFABRIC_BITBUCKET_TOKEN:-} && -n ${BITBUCKET_PR_ID:-} ]]; then
    comment
  fi
fi
exit "$code"
