#!/usr/bin/env bash
# GitHub Action plumbing (action.yml: sim runs; training-run/action.yml: training runs).
# Subcommands, one per step; the second argument is the run script (ci-job.sh): sim-run (the
# default) or training-run:
#
#   github.sh install                 install the pinned CLI into $RUNNER_TEMP and add it to
#                                     GITHUB_PATH
#   github.sh run [run script]        run the run script (sim-run.sh: the suite or the
#                                     definition directory; training-run.sh: the training run)
#                                     as this step's process, so the runner's SIGINT/SIGTERM on
#                                     cancel reaches the CLI; exits with the step's code
#   github.sh publish [run script]    always, after run: step outputs, preflight blocker and
#                                     notice annotations, the job summary, the pull request
#                                     comment; never fails the job itself
#
# Reads the inputs as RFABRIC_* variables (the run script), RFABRIC_CLI_VERSION (default:
# VERSION in this repository), RFABRIC_COMMENT, RFABRIC_RESULT_DIR (publish: the run step's
# result directory), GITHUB_TOKEN (comments) and the runner's GITHUB_* and
# ACTIONS_ID_TOKEN_REQUEST_URL variables.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case ${2:-sim-run} in
  sim-run)
    # shellcheck source=sim-run.sh
    source "$here/sim-run.sh"
    ;;
  training-run)
    # shellcheck source=training-run.sh
    source "$here/training-run.sh"
    ;;
  *)
    echo "usage: github.sh install|run|publish [sim-run|training-run]" >&2
    exit 2
    ;;
esac

install() {
  local version=${RFABRIC_CLI_VERSION:-}
  local dir="$RUNNER_TEMP/rfabric/bin"
  [[ -n $version ]] || version=$(< "$here/../VERSION")
  # An existing directory: the installer writes into it as the runner user, without sudo.
  mkdir -p "$dir" || exit 1
  curl -fsSL https://get.rfabric.io/cli.sh | RFABRIC_VERSION="v${version#v}" RFABRIC_INSTALL_DIR="$dir" sh || exit
  printf '%s\n' "$dir" >> "$GITHUB_PATH"
}

# detect_run: the run's event (ci-job.sh). The base branch defaults to the repository's
# default branch, which the event payload carries (unreadable payload: no base branch, so the
# run is "other" and applies nothing); a pull request event (pull_request, pull_request_target)
# is a pull request; any other event on the base branch is a base-branch run. A pull request is
# a fork run unless the event payload proves its head repository is this repository, whatever
# credential the job holds: a pull_request_target job of a fork holds the identity token and the
# repository's secrets. A missing, empty or unreadable payload, or no jq, counts as a fork.
detect_run() {
  base_branch=${RFABRIC_BASE_BRANCH:-}
  if [[ -z $base_branch && -s ${GITHUB_EVENT_PATH:-} ]]; then
    base_branch=$(jq -r '.repository.default_branch // empty' "$GITHUB_EVENT_PATH" 2> /dev/null)
  fi
  case ${GITHUB_EVENT_NAME:-} in
    pull_request | pull_request_target) run_event=pull_request ;;
    *) [[ -n $base_branch && ${GITHUB_REF:-} == "refs/heads/$base_branch" ]] && run_event=base_branch ;;
  esac
  if [[ $run_event == pull_request ]] && ! same_repository_pull_request; then
    fork_run=true
  fi
  [[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} ]] && identity_token=true
  return 0
}

# same_repository_pull_request: the event payload names this repository as the pull request's
# head repository. When the payload cannot be read, sets fork_reason (ci-job.sh) to say why.
# The file test comes first: jq 1.6 (the image's) exits 0 for -e on empty input.
same_repository_pull_request() {
  if ! jq --version > /dev/null 2>&1; then
    fork_reason='jq is not available on the runner, so the event payload was not read'
    return 1
  fi
  if [[ ! -s ${GITHUB_EVENT_PATH:-} ]]; then
    fork_reason='the event file (GITHUB_EVENT_PATH) is missing or empty'
    return 1
  fi
  if ! jq -e '.repository.full_name | type == "string"' "$GITHUB_EVENT_PATH" > /dev/null 2>&1; then
    fork_reason='the event file is not a readable pull request payload'
    return 1
  fi
  jq -e '.pull_request.head.repo.full_name == .repository.full_name' "$GITHUB_EVENT_PATH" > /dev/null 2>&1
}

run() {
  local dir
  dir=$(mktemp -d "$RUNNER_TEMP/rfabric-$run_script.XXXXXX") || exit 1
  printf 'dir=%s\n' "$dir" >> "$GITHUB_OUTPUT"
  detect_run
  ci_run "$dir"
  exit $?
}

# escape_data / escape_property <text>: workflow command escaping.
escape_data() {
  local text=${1//'%'/'%25'}
  text=${text//$'\r'/'%0D'}
  printf '%s' "${text//$'\n'/'%0A'}"
}
escape_property() {
  local text
  text=$(escape_data "$1")
  text=${text//:/'%3A'}
  printf '%s' "${text//,/'%2C'}"
}

# github_api <method> <path> [body]: api_call with the job token.
github_api() {
  api_call "$1" "${GITHUB_API_URL:-https://api.github.com}$2" "${3:-}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28"
}

# comment_author: the author of the job token's (github.token) comments; only its comment with
# the run's marker is updated.
comment_author='github-actions[bot]'

# comment <result-dir>: creates or updates the run's pull request comment.
comment() {
  local dir=$1 number marker body page=1 comments id=""
  number=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH" 2> /dev/null)
  [[ -n $number ]] || return 0
  marker=$(comment_marker)
  while [[ -z $id ]]; do
    comments=$(github_api GET "/repos/$GITHUB_REPOSITORY/issues/$number/comments?per_page=100&page=$page") || break
    id=$(jq -r --arg marker "$marker" --arg author "$comment_author" \
      'map(select(.user.login == $author and (.body | contains($marker)))) | first | .id // empty' <<< "$comments")
    [[ $(jq length <<< "$comments") -eq 100 ]] || break
    page=$((page + 1))
  done
  body=$(comment_body "$dir" "$marker" | jq -Rs '{body: .}')
  if [[ -n $id ]]; then
    github_api PATCH "/repos/$GITHUB_REPOSITORY/issues/comments/$id" "$body" > /dev/null
  else
    github_api POST "/repos/$GITHUB_REPOSITORY/issues/$number/comments" "$body" > /dev/null
  fi
  case $api_status in
    2??) ;;
    403) echo "::notice title=rFabric::No pull request comment: the job token is read-only here (a pull request from a fork). The scorecard is in the job summary." ;;
    *) echo "::warning title=rFabric::Could not write the pull request comment (GitHub answered $api_status)." ;;
  esac
}

publish() {
  local dir=${RFABRIC_RESULT_DIR:-} name first_job
  [[ -n $dir && -f $dir/outputs.json ]] || exit 0
  while IFS= read -r name; do
    printf '%s=%s\n' "$name" "$(output_value "$dir" "$name")" >> "$GITHUB_OUTPUT"
  done < <(run_outputs)
  # The artifact name holds the first job id: a retried step reuses its jobs and overwrites it.
  if compgen -G "$dir/*.xml" > /dev/null; then
    first_job=$(sort "$dir/job-id" 2> /dev/null | head -n 1)
    printf 'artifact-name=rfabric-%s-%s-%s\n' "$run_script" "$(slug "$(run_key)")" "$first_job" >> "$GITHUB_OUTPUT"
  fi
  if [[ -s $dir/notice.md ]]; then
    printf '::error title=rFabric::%s\n' "$(escape_data "$(sed -n 3p "$dir/notice.md")")"
  fi
  if [[ $run_script == sim-run ]] && preflight_blocked "$dir"; then
    while IFS=$'\t' read -r code message; do
      printf '::error title=%s::%s\n' "$(escape_property "$code")" "$(escape_data "$message")"
    done < <(jq -r '.blockers[] | [.code, .message] | @tsv' "$dir/preflight.json")
  fi
  cat "$dir/summary.md" >> "$GITHUB_STEP_SUMMARY"
  printf '\n' >> "$GITHUB_STEP_SUMMARY"
  case ${GITHUB_EVENT_NAME:-} in
    pull_request | pull_request_target) [[ ${RFABRIC_COMMENT:-true} == true ]] && comment "$dir" ;;
  esac
  exit 0
}

case ${1:-} in
  install | run | publish) "$1" ;;
  *)
    echo "usage: github.sh install|run|publish [sim-run|training-run]" >&2
    exit 2
    ;;
esac
