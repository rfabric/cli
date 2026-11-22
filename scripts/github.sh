#!/usr/bin/env bash
# GitHub Action plumbing (action.yml). Subcommands, one per step:
#
#   github.sh install   install the pinned CLI into $RUNNER_TEMP and add it to GITHUB_PATH
#   github.sh run       run the suite (sim-run.sh) as this step's process, so the runner's
#                       SIGINT/SIGTERM on cancel reaches the CLI; exits with the CLI's code
#   github.sh publish   always, after run: step outputs, preflight blocker annotations, the
#                       job summary, the pull request comment; never fails the job itself
#
# Reads the inputs as RFABRIC_* variables (sim-run.sh), RFABRIC_CLI_VERSION (default: VERSION
# beside this repository's action.yml), RFABRIC_COMMENT, RFABRIC_RESULT_DIR (publish: the
# run step's result directory), GITHUB_TOKEN (comments) and the runner's GITHUB_* variables.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sim-run.sh
source "$here/sim-run.sh"

install() {
  local version=${RFABRIC_CLI_VERSION:-}
  local dir="$RUNNER_TEMP/rfabric/bin"
  [[ -n $version ]] || version=$(< "$here/../VERSION")
  # An existing directory: the installer writes into it as the runner user, without sudo.
  mkdir -p "$dir" || exit 1
  curl -fsSL https://get.rfabric.io/cli.sh | RFABRIC_VERSION="v${version#v}" RFABRIC_INSTALL_DIR="$dir" sh || exit
  printf '%s\n' "$dir" >> "$GITHUB_PATH"
}

run() {
  local dir
  dir=$(mktemp -d "$RUNNER_TEMP/rfabric-sim-run.XXXXXX") || exit 1
  printf 'dir=%s\n' "$dir" >> "$GITHUB_OUTPUT"
  sim_run "$dir"
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
# the suite's marker is updated.
comment_author='github-actions[bot]'

# comment <result-dir>: creates or updates the suite's pull request comment.
comment() {
  local dir=$1 number marker body page=1 comments id=""
  number=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH" 2> /dev/null)
  [[ -n $number ]] || return 0
  marker=$(comment_marker "$RFABRIC_SUITE")
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
  local dir=${RFABRIC_RESULT_DIR:-} name
  [[ -n $dir && -f $dir/outputs.json ]] || exit 0
  for name in job-id report-id conclusion operational-classification job-url artifact-id; do
    printf '%s=%s\n' "$name" "$(output_value "$dir" "$name")" >> "$GITHUB_OUTPUT"
  done
  if [[ -s $dir/junit.xml ]]; then
    printf 'artifact-name=rfabric-sim-run-%s-%s\n' "$(slug "$RFABRIC_SUITE")" "$(output_value "$dir" job-id)" >> "$GITHUB_OUTPUT"
  fi
  if preflight_blocked "$dir"; then
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
    echo "usage: github.sh install|run|publish" >&2
    exit 2
    ;;
esac
