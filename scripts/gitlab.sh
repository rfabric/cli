#!/usr/bin/env bash
# GitLab template plumbing (templates/sim-run.yml). Subcommands:
#
#   gitlab.sh run     script: run the suite or the definition directory (sim-run.sh) into
#                     rfabric-sim-run/; exits with the step's code
#   gitlab.sh after   after_script, also after a cancel: GitLab does not always signal the
#                     job's process, so a canceled job (CI_JOB_STATUS=canceled) cancels the
#                     blocking evaluation jobs here; then the dotenv outputs and, with
#                     RFABRIC_GITLAB_TOKEN on a merge request pipeline, the merge request note
#
# Reads the inputs as RFABRIC_* variables (sim-run.sh) and GitLab's predefined CI_* variables.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sim-run.sh
source "$here/sim-run.sh"

dir="${CI_PROJECT_DIR:-.}/rfabric-sim-run"

# detect_run: the run's event for sim-run.sh. The base branch defaults to the project's default
# branch (CI_DEFAULT_BRANCH); a merge request pipeline is a pull request, any other pipeline on
# the base branch a base-branch run. A merge request pipeline in the fork (the source project,
# not the merge request's project) is a fork run; RFABRIC_ID_TOKEN is the identity token.
detect_run() {
  base_branch=${RFABRIC_BASE_BRANCH:-${CI_DEFAULT_BRANCH:-}}
  if [[ -n ${CI_MERGE_REQUEST_IID:-} ]]; then
    run_event=pull_request
  elif [[ -n $base_branch && ${CI_COMMIT_BRANCH:-} == "$base_branch" ]]; then
    run_event=base_branch
  fi
  if [[ -n ${CI_MERGE_REQUEST_PROJECT_ID:-} && ${CI_PROJECT_ID:-} != "$CI_MERGE_REQUEST_PROJECT_ID" ]]; then
    fork_run=true
  fi
  [[ -n ${RFABRIC_ID_TOKEN:-} ]] && identity_token=true
  return 0
}

run() {
  detect_run
  sim_run "$dir"
  exit $?
}

# gitlab_api <method> <path> [body]: api_call with RFABRIC_GITLAB_TOKEN.
gitlab_api() {
  api_call "$1" "$CI_API_V4_URL$2" "${3:-}" -H "PRIVATE-TOKEN: $RFABRIC_GITLAB_TOKEN"
}

# note: creates or updates the run's merge request note: the note of the token's user that
# carries the run's marker.
note() {
  local path="/projects/$CI_PROJECT_ID/merge_requests/$CI_MERGE_REQUEST_IID/notes"
  local author marker body page=1 notes id=""
  if ! author=$(gitlab_api GET /user | jq -er .id); then
    echo "rfabric: could not read the user of RFABRIC_GITLAB_TOKEN; no merge request note" >&2
    return 0
  fi
  marker=$(comment_marker)
  while [[ -z $id ]]; do
    notes=$(gitlab_api GET "$path?per_page=100&page=$page") || break
    id=$(jq -r --arg marker "$marker" --argjson author "$author" \
      'map(select(.author.id == $author and (.body | contains($marker)))) | first | .id // empty' <<< "$notes")
    [[ $(jq length <<< "$notes") -eq 100 ]] || break
    page=$((page + 1))
  done
  body=$(comment_body "$dir" "$marker" | jq -Rs '{body: .}')
  if [[ -n $id ]]; then
    gitlab_api PUT "$path/$id" "$body" > /dev/null
  else
    gitlab_api POST "$path" "$body" > /dev/null
  fi
  [[ $api_status == 2?? ]] || echo "rfabric: could not write the merge request note (GitLab answered $api_status)" >&2
}

after() {
  local job_id name variable
  # No exit-code file: the job was canceled before the CLI ended the wait.
  if [[ ${CI_JOB_STATUS:-} == canceled && -s $dir/job-id && ! -f $dir/exit-code ]]; then
    # after_script is a new shell: the cancel signs in with the client id the run used.
    detect_run
    use_pull_request_client_id
    while IFS= read -r job_id; do
      forwarding rfabric evaluation-job cancel "$job_id" --output json > /dev/null
    done < <(sort -u "$dir/job-id")
  fi
  [[ -f $dir/outputs.json ]] || return 0
  # dotenv takes no JSON value: the suites output stays in outputs.json.
  for name in job-id report-id conclusion operational-classification job-url artifact-id; do
    variable="RFABRIC_$(tr 'a-z-' 'A-Z_' <<< "$name")"
    printf '%s=%s\n' "$variable" "$(output_value "$dir" "$name")"
  done > "$dir/outputs.env"
  if [[ -n ${RFABRIC_GITLAB_TOKEN:-} && -n ${CI_MERGE_REQUEST_IID:-} ]]; then
    note
  fi
  return 0
}

case ${1:-} in
  run | after) "$1" ;;
  *)
    echo "usage: gitlab.sh run|after" >&2
    exit 2
    ;;
esac
