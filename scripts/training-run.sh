#!/usr/bin/env bash
# The training run script every rFabric CI wrapper shares (GitHub Action training-run/action.yml,
# GitLab template templates/training-run.yml, the Bitbucket pipe with RFABRIC_LAUNCH_TEMPLATE):
# map the wrapper inputs to `rfabric training apply` and `rfabric training run` flags, run them,
# and read the run into the outputs. Every behavior (auth, CI provenance, idempotency, the
# directory apply, launch, replacing earlier runs, wait, cancel on interrupt, markdown, exit
# codes) is the CLI's; this script passes the CLI's exit code through. `source training-run.sh`
# sources ci-job.sh (the run's event, client id, fork refusal, signal forwarding, result
# directory, outputs) and defines the run script functions ci-job.sh names (the provider scripts run
# it with ci_run).
#
# Inputs: the wrapper inputs as RFABRIC_ + the input name in upper snake case (launch-template
# -> RFABRIC_LAUNCH_TEMPLATE); ci-job.sh lists what the CLI reads itself:
#   launch-template     launch template id or slug (required); with dir, the slug its file holds
#   experiment          experiment id (required)
#   dataset-versions    dataset version ids, comma or newline separated
#   base-model, config-overrides, compute-overrides, run-tags (key=value, comma or newline
#   separated), image (<repository>@sha256:<digest>), code-version (the commit image was built
#   from; only with image, never defaulted), wait (true: block until the run ends),
#   wait-timeout (with wait), replace-previous (true: cancel the runs earlier launched from this
#   repository, ref and launch template), dir (definition directory of launch template files)
#
# By run_event:
#   pull_request  with dir: `training apply --preview` (problems end the run); then `training run`
#   base_branch   with dir: `training apply`, with `--image <launch-template>=<image>` and
#                 `--code-version` when the inputs are set; then `training run`
#   other         `training run`
# A pull request that cannot reach rFabric (ci-job.sh fork_pull_request) ends before any CLI
# call with the notice that a trusted run on the same commit is needed.
#
# The run writes into <result-dir>, beside ci-job.sh's files:
#   run-id        the training run id, written as the launch answers
#   run.json      `training run`'s JSON output: the run (waited: its terminal state)
#   run.md        its markdown summary
#   summary.md    the notice, else run.md (or what ended the run before it), then the
#                 definitions' changes
#   outputs.json  the outputs: run-id, status, run-url, best-checkpoint-id

set -uo pipefail

# shellcheck source=ci-job.sh
source "$(dirname "${BASH_SOURCE[0]}")/ci-job.sh"
run_script=training-run

# launch_line: the CLI's line for the training run it launches; its group is the run id.
launch_line='Training run (run_[0-9A-Za-z]{26})'

# run_result: the outputs from `training run`'s JSON output ($run, {} without one) and the
# recorded run id ($launched). The one place that reads the CLI's run JSON.
# shellcheck disable=SC2016 # jq variables, expanded by jq
run_result='{
  "run-id": ($run.id // $launched),
  "status": ($run.status // ""),
  "run-url": ($run.appUrl // ""),
  "best-checkpoint-id": ($run.bestCheckpoint.id // "")
}'

# run_key: what the run launches, for comment markers: the launch template.
run_key() {
  printf '%s' "${RFABRIC_LAUNCH_TEMPLATE:-}"
}

# run_title: the run's title in summaries.
run_title() {
  printf 'rFabric training run %s' "${RFABRIC_LAUNCH_TEMPLATE:-}"
}

# run_outputs: the output names, in publishing order.
run_outputs() {
  printf '%s\n' run-id status run-url best-checkpoint-id
}

# boolean_input <input name> <value>: the value is true or false, else a usage error.
boolean_input() {
  case $2 in
    true | false) ;;
    *) usage_error "training run" "$1 must be true or false, got '$2'" ;;
  esac
}

# run_steps <result-dir>: the whole run; returns the step's exit code.
run_steps() {
  local dir=$1 image=${RFABRIC_IMAGE:-} code_version=${RFABRIC_CODE_VERSION:-}
  local wait=${RFABRIC_WAIT:-false} replace_previous=${RFABRIC_REPLACE_PREVIOUS:-false}
  local args=() apply=() flag

  [[ -n ${RFABRIC_LAUNCH_TEMPLATE:-} ]] || { usage_error "training run" "the launch-template input is required"; return; }
  [[ -n ${RFABRIC_EXPERIMENT:-} ]] || { usage_error "training run" "the experiment input is required"; return; }
  [[ -n ${RFABRIC_CLIENT_ID:-} ]] || { usage_error "training run" "the client-id input is required"; return; }
  use_pull_request_client_id
  [[ -z $code_version || -n $image ]] || { usage_error "training run" "code-version goes with image: the commit the image was built from"; return; }
  boolean_input wait "$wait" || return
  boolean_input replace-previous "$replace_previous" || return
  [[ -z ${RFABRIC_WAIT_TIMEOUT:-} || $wait == true ]] || { usage_error "training run" "wait-timeout goes with wait: true"; return; }

  if fork_pull_request; then
    fork_notice "$dir" "$(run_title)"
    return 1
  fi

  if [[ -n ${RFABRIC_DIR:-} ]]; then
    if [[ -n $image ]]; then
      apply=(--image "$RFABRIC_LAUNCH_TEMPLATE=$image")
      [[ -n $code_version ]] && apply+=(--code-version "$code_version")
    fi
    apply_definitions "$dir" training "${apply[@]}" || return
  fi

  args=(training run "$RFABRIC_LAUNCH_TEMPLATE" --experiment "$RFABRIC_EXPERIMENT")
  while IFS= read -r -d '' flag; do args+=("$flag"); done \
    < <(list_flags --dataset-version "${RFABRIC_DATASET_VERSIONS:-}"; list_flags --tag "${RFABRIC_RUN_TAGS:-}")
  [[ -n ${RFABRIC_BASE_MODEL:-} ]] && args+=(--base-model "$RFABRIC_BASE_MODEL")
  [[ -n ${RFABRIC_CONFIG_OVERRIDES:-} ]] && args+=(--config-overrides "$RFABRIC_CONFIG_OVERRIDES")
  [[ -n ${RFABRIC_COMPUTE_OVERRIDES:-} ]] && args+=(--compute-overrides "$RFABRIC_COMPUTE_OVERRIDES")
  [[ -n $image ]] && args+=(--image "$image")
  [[ -n $code_version ]] && args+=(--code-version "$code_version")
  [[ $wait == true ]] && args+=(--wait)
  [[ -n ${RFABRIC_WAIT_TIMEOUT:-} ]] && args+=(--wait-timeout "$RFABRIC_WAIT_TIMEOUT")
  [[ $replace_previous == true ]] && args+=(--replace-previous)
  forwarding rfabric "${args[@]}" --markdown "$dir/run.md" --output json \
    > "$dir/run.json" 2> >(record_launch "$launch_line" "$dir/run-id")
}

# run_finish <result-dir> <exit-code>: writes outputs.json and summary.md.
run_finish() {
  local dir=$1 code=$2 run=/dev/null launched="" definitions_code=0 run_id run_url
  [[ -s $dir/run-id ]] && launched=$(head -n 1 "$dir/run-id")
  # The file test comes first: jq 1.6 (the image's) exits 0 for -e on empty input.
  if [[ -s $dir/run.json ]] && jq -e 'type == "object" and has("id")' "$dir/run.json" > /dev/null 2>&1; then
    run="$dir/run.json"
  fi
  jq -n --slurpfile runs "$run" --arg launched "$launched" "(\$runs[0] // {}) as \$run | $run_result" > "$dir/outputs.json"

  if [[ -s $dir/notice.md ]]; then
    cp "$dir/notice.md" "$dir/summary.md"
    return
  fi
  [[ -s $dir/definitions-exit-code ]] && definitions_code=$(< "$dir/definitions-exit-code")
  run_id=$(output_value "$dir" run-id)
  run_url=$(output_value "$dir" run-url)
  {
    if [[ -s $dir/run.md ]]; then
      cat "$dir/run.md"
    elif [[ -n $run_id ]]; then
      printf '### %s\n\nTraining run [%s](%s) ended without a summary (rfabric exit code %s); the job log says why.\n' \
        "$(run_title)" "$run_id" "$run_url" "$code"
    elif [[ $definitions_code -eq 0 ]]; then
      printf '### %s\n\nThe run ended before a launch (rfabric exit code %s); the job log says why.\n' "$(run_title)" "$code"
    fi
    definitions_summary "$dir" "$definitions_code"
  } > "$dir/summary.md"
}

# cancel_launched <result-dir>: cancels the training run the wait was following.
cancel_launched() {
  local run_id
  [[ -s $1/run-id ]] || return 0
  while IFS= read -r run_id; do
    forwarding rfabric training-run cancel "$run_id" --output json > /dev/null
  done < <(sort -u "$1/run-id")
}
