#!/usr/bin/env bash
# Runs every wrapper entry point against the local stack with a simulated runner environment
# (`mise run test`). Each scenario runs the provider script the way the provider does, in an
# environment holding only that provider's variables (exported RFABRIC_*, GITHUB_*, ACTIONS_*,
# RUNNER_*, GITLAB_*, CI_*, BITBUCKET_*), with `rfabric-dev` on PATH as `rfabric`, and the
# provider endpoints stubbed on localhost (tests/stub.mjs).
#
# Secretless throughout: the test creates a trust credential in its workspace whose trusts
# accept the stub issuer's GitHub, GitLab and Bitbucket tokens; it revokes it at the end.
#
# Fixtures: as the seeded owner seed@rfabric.io, the test creates its own workspace and, in it,
# three published sim suites on the local Docker pool that run the reference oracle of the
# seeded local-process platform profile, and an approved model as candidate (fixtures below);
# it deletes the workspace at the end:
#   pass             every run meets the criteria: complete_pass
#   wrong-placement  the oracle measures the payload 0.5 m off target: behavioral_failure
#   held             the oracle holds readiness, so a job is still running when cancelled
#
# Needs the stack's api and auth (with the sim.attempt handler image on the local Docker pool),
# `rfabric-dev` (`mise run cli:dev`), node, jq, git and docker. Optional: RFABRIC_API_URL
# (default http://localhost:10201), RFABRIC_AUTH_URL (default http://localhost:10301),
# RFABRIC_TEST_STUB_PORT (default 18091), RFABRIC_TEST_IMAGE_CLI (the CLI the pipe image gets: a
# Linux build for the Docker engine's platform; default rfabric-dev, which only a Linux host can
# put in the image).
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
api_url=${RFABRIC_API_URL:-http://localhost:10201}
auth_url=${RFABRIC_AUTH_URL:-http://localhost:10301}
port=${RFABRIC_TEST_STUB_PORT:-18091}
image_cli=${RFABRIC_TEST_IMAGE_CLI:-}
stub="http://127.0.0.1:$port"
provider_variables='^(RFABRIC|GITHUB|ACTIONS|RUNNER|GITLAB|CI|BITBUCKET)_'
suite=pass
failing_suite=wrong-placement
held_suite=held

# Nothing of the caller's environment reaches a provider.
for name in $(compgen -e); do [[ $name =~ $provider_variables ]] && unset "$name"; done

work=$(mktemp -d)
run_id="$(date +%s)$$"
image_tag="rfabric-cli-test:$run_id"
failures=0
workspace=""
candidate=""
client_id=""
stub_pid=""

say() { printf '\n== %s\n' "$*"; }
check() { # check <description> <command...>
  if "${@:2}"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
contains() { grep -qF -- "$2" "$1"; }
matches() { [[ $1 =~ $2 ]]; }
equal() { [[ $1 == "$2" ]]; }
# requests <jq condition>: the stub's logged requests matching it, one JSON line each.
requests() { jq -c "select($1)" "$work/requests.jsonl"; }
count() { requests "$1" | wc -l | tr -d ' '; }

# as_owner <rfabric args...>: the CLI as the seeded owner (a fresh 15-minute token per call).
as_owner() {
  local token
  token=$(curl -fsS "$auth_url/api/auth/token" -H "authorization: Bearer $session" | jq -er .token) || return 1
  env -i PATH="$PATH" HOME="$HOME" RFABRIC_ACCESS_TOKEN="$token" RFABRIC_API_URL="$api_url" \
    RFABRIC_AUTH_URL="$auth_url" RFABRIC_CONFIG_DIR="$work/owner-config" "$work/bin/rfabric" "$@"
}
job() { as_owner evaluation-job get "$1" --output json; }

# create <resource> <json body>: a new row of the resource; prints its id.
create() { as_owner "$1" create --data "$2" --output json | jq -er .id; }
# publish <resource> <json body>: a definition created and published; prints the published row.
publish() {
  local id
  id=$(create "$1" "$2") || return 1
  as_owner "$1" publish "$id" --output json
}

# fixtures: sets workspace (created for this run) and candidate, and publishes the suites pass,
# wrong-placement and held in that workspace: a task, its criteria, a five-seed protocol, a
# cell, and per suite one scenario on the local-process platform profile. The profile runs the
# worker's reference oracle, which reads two case parameters: demo_outcome wrong_placement
# measures the payload 0.5 m off target, demo_ready_delay_s holds readiness that many seconds
# (under the profile's 10 s readiness budget). The candidate is an approved model: the
# reference oracle runs no candidate image. The workspace packages candidate models before
# approval, as a customer's CI does when it registers each build (`image` input).
fixtures() {
  local organization profile pool metric task criteria protocol cell simulation slug variables scenario
  organization=$(as_owner organization ls --output json | jq -er 'first.id') || return 1
  workspace=$(create workspace "$(jq -nc --arg organization "$organization" --arg run "$run_id" \
    '{organizationId: $organization, name: "CI wrapper test \($run)", slug: "ci-wrapper-test-\($run)"}')") || return 1
  as_owner settings set artifact.preApprovalPackaging=true --rationale "CI builds are packaged for evaluation" \
    --scope-type workspace --scope-id "$workspace" > /dev/null || return 1
  profile=$(as_owner sim-adapter-profile ls -f "workspaceId=$workspace" -f slug=local-process --output json \
    | jq -er 'map(select(.status == "published")) | max_by(.version).id') \
    || { echo "no published local-process platform profile" >&2; return 1; }
  pool=$(as_owner compute-pool ls --output json \
    | jq -er 'first(.[] | select(.backend == "local_docker" and (.taskTypes | index("sim.attempt")))).id') \
    || { echo "no local Docker compute pool admits sim.attempt" >&2; return 1; }
  metric=$(as_owner evaluation-metric ls -f slug=task_success --output json \
    | jq -ec 'first(.[] | select(.workspaceId == null)) | {metricId: .id, metricVersion: .version}') || return 1

  task=$(create task "$(jq -nc --arg workspace "$workspace" '{workspaceId: $workspace, slug: "put-away",
    name: "Put-away", description: "Drive the carrier to the target and release the payload there."}')") || return 1
  criteria=$(publish evaluation-criteria "$(jq -nc --arg workspace "$workspace" --arg task "$task" '{
    workspaceId: $workspace, slug: "payload-on-target", targetType: "task", taskId: $task,
    name: "Payload placed on target", criteriaClass: "performance",
    description: "The reference oracle measures the payload within 0.10 m of the target.",
    goalPredicates: [{key: "payload_on_target", required: true, expression: "state.placement_error_m <= 0.10"}]}')") \
    || return 1
  # Five seeds: a pass with all five on target clears the gate's Wilson lower bound.
  protocol=$(publish evaluation-protocol "$(jq -nc --arg workspace "$workspace" --arg task "$task" \
    --argjson criteria "$criteria" --argjson metric "$metric" '{
    workspaceId: $workspace, slug: "put-away", targetType: "task", taskId: $task,
    name: "Put-away (reference oracle)", description: "Reference oracle grading against payload-on-target.",
    protocolType: "capability", criteriaId: $criteria.id, criteriaVersion: $criteria.version,
    executionMode: "simulation", gradingMode: "simulator_oracle", metricRefs: [$metric],
    primaryMetric: "task_success", secondaryMetrics: [], groupBy: [],
    rolloutPlan: {minRuns: 5, maxRuns: 5, seedPolicy: "fixed", stoppingRule: "fixed", seeds: [1, 2, 3, 4, 5], maxInfraRetries: 1},
    statistics: {paired: false, ciMethod: "wilson", confidenceLevel: 0.95},
    acceptanceGates: [{id: "task_success", name: "Every run meets the criteria", metric: "task_success",
      aggregate: "ci_lower", op: "gte", value: 0.5, blocking: true, severity: "fail"}]}')") || return 1
  cell=$(create evaluation-cell "$(jq -nc --arg workspace "$workspace" '{workspaceId: $workspace,
    siteProfileKey: "example-warehouse", operation: "put_away", robotProfileKey: "example-carrier",
    coverageStatus: "supported", notes: "CI wrapper tests"}')") || return 1
  simulation=$(jq -nc --arg profile "$profile" '{adapterProfileId: $profile,
    siteProfileKey: "example-warehouse", operation: "put_away", robotProfileKey: "example-carrier",
    assets: {world: null, robot: null, inputs: []}, initialState: {},
    mission: {kind: "put_away", target: {x_m: 4.0, y_m: 2.0}},
    readiness: {topics: [{name: "/odom", minHz: 5, expectedHz: 20}], transforms: ["map->odom"], warmupS: 0},
    faults: [], limits: {missionSimS: 600, wallS: 120}, requiredMetrics: ["placement_error_m"], allowedContacts: []}')

  for slug in "$suite" "$failing_suite" "$held_suite"; do
    case $slug in
      "$failing_suite") variables='[{"key": "demo_outcome", "type": "categorical", "sampling": "grid", "values": ["wrong_placement"], "required": true}]' ;;
      "$held_suite") variables='[{"key": "demo_ready_delay_s", "type": "discrete", "sampling": "grid", "values": [6], "required": true}]' ;;
      *) variables='[]' ;;
    esac
    scenario=$(publish evaluation-scenario "$(jq -nc --arg workspace "$workspace" --arg slug "$slug" \
      --argjson simulation "$simulation" --argjson variables "$variables" '{workspaceId: $workspace,
      slug: $slug, name: $slug, variables: $variables, constraints: [], simulation: $simulation}')") || return 1
    publish sim-suite "$(jq -nc --arg workspace "$workspace" --arg slug "$slug" --argjson protocol "$protocol" \
      --argjson scenario "$scenario" --arg cell "$cell" --arg pool "$pool" '{
      workspaceId: $workspace, slug: $slug, name: $slug, protocolId: $protocol.id,
      scenarioEntries: [{scenarioId: $scenario.id, version: $scenario.version, sha256: $scenario.digest, required: true}],
      expansion: "full", matrix: [$cell], minValidSamplesPerCell: 1, baselineOrder: "alternate", poolId: $pool}')" \
      > /dev/null || return 1
  done

  # Approval needs evaluation evidence.
  candidate=$(create model "$(jq -nc --arg workspace "$workspace" '{workspaceId: $workspace,
    name: "CI wrapper test candidate", version: "1", architecture: "reference-oracle"}')") || return 1
  as_owner model update "$candidate" \
    --data '{"evaluationResults": {"source": "the reference oracle of the local-process platform profile"}}' > /dev/null \
    && as_owner model approve "$candidate" --reason "Candidate of the CI wrapper tests" > /dev/null
}

cleanup() {
  if [[ -n $client_id ]]; then
    as_owner credential revoke "$client_id" --confirm > /dev/null 2>&1 \
      || echo "warning: could not revoke the test credential $client_id" >&2
  fi
  if [[ -n $workspace ]]; then
    as_owner workspace delete "$workspace" --confirm > /dev/null 2>&1 \
      || echo "warning: could not delete the test workspace $workspace" >&2
  fi
  [[ -n $stub_pid ]] && kill "$stub_pid" 2> /dev/null
  docker rm -f "rfabric-cli-test-$run_id" > /dev/null 2>&1
  docker image rm "$image_tag" "rfabric-cli-test-candidate:$run_id" > /dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

# The CLI under test, as `rfabric` (a copy: the image build context takes it too).
mkdir -p "$work/bin"
dev_cli=$(command -v rfabric-dev) || { echo "rfabric-dev is not on PATH: run mise run cli:dev" >&2; exit 1; }
cp "$dev_cli" "$work/bin/rfabric"
base_path="$work/bin:$PATH"

# repository <name>: a git work tree with one commit; prints its path.
repository() {
  local dir="$work/$1"
  git init -q "$dir"
  git -C "$dir" -c user.email=ci@example.com -c user.name=ci commit -q --allow-empty -m "$1"
  printf '%s' "$dir"
}

# provider <command...>: execs the command with PATH, HOME and the exported provider
# variables only; call it in a subshell, so the command keeps the subshell's pid.
provider() {
  local name assignments=()
  for name in $(compgen -e); do
    [[ $name =~ $provider_variables ]] && assignments+=("$name=${!name}")
  done
  exec env -i PATH="$base_path" HOME="$HOME" "${assignments[@]}" "$@"
}

# unexport <prefix...>: unsets the provider variables of a finished scenario.
unexport() {
  local name prefix
  for prefix in "$@"; do
    for name in $(compgen -e "$prefix"); do unset "$name"; done
  done
}

# mint <claims json>: an identity token of the stub issuer.
mint() { curl -fsS "$stub/mint?claims=$(jq -rn --arg claims "$1" '$claims | @uri')"; }

# await_file <file> <pid>: waits until the file has content; fails when the process ends first.
await_file() {
  for _ in $(seq 1200); do
    [[ -s $1 ]] && return 0
    kill -0 "$2" 2> /dev/null || return 1
    sleep 0.25
  done
  return 1
}

say "setup"
node "$root/tests/stub.mjs" "$port" "$work/requests.jsonl" "$auth_url" > "$work/stub.log" 2>&1 &
stub_pid=$!
for _ in $(seq 50); do curl -fs "$stub/.well-known/jwks" > /dev/null && break; sleep 0.1; done
: >> "$work/requests.jsonl"

session=$(curl -fsS -D - -o /dev/null -X POST "$auth_url/api/auth/sign-in/email" \
  -H 'content-type: application/json' -H "origin: $auth_url" \
  --data '{"email":"seed@rfabric.io","password":"pass"}' | tr -d '\r' | sed -n 's/^set-auth-token: //Ip')
[[ -n $session ]] || { echo "could not sign in as seed@rfabric.io at $auth_url" >&2; exit 1; }

fixtures || { echo "could not create the fixtures" >&2; exit 1; }
organization=$(as_owner workspace get "$workspace" --output json | jq -er .organizationId) || exit 1
github_repository_id=123456789
gitlab_project_id=4242
bitbucket_repository_uuid="{0e0c7c5e-1b1d-4b39-9f6e-9d2b0c2b7a11}"
client_id=$(as_owner credential create --name "cli-wrapper-test-$run_id" \
  --organization-id "$organization" --workspace-id "$workspace" \
  --permission simSuite:launch --permission evaluationJob:launch,cancel \
  --permission artifact:read,create,build --permission model:read,create \
  --trust-issuer "$stub" --trust-condition "repository_id=$github_repository_id" \
  --output json | jq -er .clientId) || { echo "could not create the test credential" >&2; exit 1; }
as_owner credential trust add "$client_id" --issuer "$stub" --condition "project_id=$gitlab_project_id" > /dev/null || exit 1
as_owner credential trust add "$client_id" --issuer "$stub" --condition "repositoryUuid=$bitbucket_repository_uuid" > /dev/null || exit 1
echo "suites $suite, $failing_suite, $held_suite; candidate $candidate; workspace $workspace; credential $client_id"

# inputs <suite>: the inputs every scenario shares. No workspace input: the credential's
# workspace is the default.
inputs() {
  export RFABRIC_SUITE=$1 RFABRIC_CANDIDATE=$candidate RFABRIC_CLIENT_ID=$client_id \
    RFABRIC_API_URL=$api_url RFABRIC_AUTH_URL=$auth_url RFABRIC_WALL_DEADLINE=900
}
marker() { printf '<!-- rfabric-sim-run:%s -->' "$1"; }
marker=$(marker "$suite")

# reviewer_comment <path> <json body>: a comment of another user (the stub's `other-token`)
# that quotes the suite's marker; the wrapper must create its own comment beside it and never
# change it. Prints its id.
reviewer_comment() {
  curl -fsS -X POST "$stub$1" -H 'Authorization: Bearer other-token' -H 'content-type: application/json' \
    --data "$2" | jq -er .id
}

# ------------------------------------------------------------------------------------------
say "GitHub Action: run and publish steps, the pull request comment created"
gh_repo=$(repository github)
gh_sha=$(git -C "$gh_repo" rev-parse HEAD)
printf '{"pull_request":{"number":42,"html_url":"https://github.com/acme/robot/pull/42","head":{"sha":"%s"}}}' \
  "$gh_sha" > "$work/event.json"
inputs "$suite"
export GITHUB_ACTIONS=true GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=acme/robot \
  GITHUB_RUN_ID="gh$run_id" GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=$gh_sha GITHUB_REF=refs/pull/42/merge \
  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$work/event.json" GITHUB_API_URL=$stub \
  GITHUB_TOKEN=job-token RUNNER_TEMP="$work/runner" RFABRIC_COMMENT=true \
  ACTIONS_ID_TOKEN_REQUEST_URL="$stub/github-id-token?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=github-request-token
mkdir -p "$RUNNER_TEMP"

# github_steps <name>: the action's run step, then its publish step, in $work/<name>; sets
# gh_code (run step), gh_publish_code and gh_dir (the run step's result directory).
github_steps() {
  mkdir -p "$work/$1"
  export GITHUB_OUTPUT="$work/$1/run-output" GITHUB_STEP_SUMMARY="$work/$1/summary"
  : > "$GITHUB_OUTPUT"
  (cd "$gh_repo" && provider "$root/scripts/github.sh" run) > "$work/$1/run.log" 2>&1
  gh_code=$?
  gh_dir=$(sed -n 's/^dir=//p' "$GITHUB_OUTPUT")
  export GITHUB_OUTPUT="$work/$1/publish-output" RFABRIC_RESULT_DIR=$gh_dir
  : > "$GITHUB_OUTPUT"
  (cd "$gh_repo" && provider "$root/scripts/github.sh" publish) > "$work/$1/publish.log" 2>&1
  gh_publish_code=$?
  unset RFABRIC_RESULT_DIR
}
output() { sed -n "s/^$2=//p" "$work/$1/publish-output"; }

gh_reviewer=$(reviewer_comment /repos/acme/robot/issues/42/comments \
  "$(jq -nc --arg marker "$marker" '{body: "\($marker)\nA reviewer quoting the scorecard."}')") || exit 1
github_steps gh1
cat "$work/gh1/run.log"
job1=$(output gh1 job-id)
gh1_code=$gh_code
check "a passing suite exits 0 (got $gh_code)" equal "$gh_code" 0
check "exit-code holds the run step's code" equal "$(cat "$gh_dir/exit-code")" "$gh_code"
check "publish step exits 0" equal "$gh_publish_code" 0
check "output job-id" matches "$job1" '^evj_[0-9A-Za-z]{26}$'
check "output report-id" matches "$(output gh1 report-id)" '^evrp_[0-9A-Za-z]{26}$'
check "output conclusion pass" equal "$(output gh1 conclusion)" pass
check "output operational-classification complete_pass" equal "$(output gh1 operational-classification)" complete_pass
check "output job-url is the job's page" equal "$(output gh1 job-url)" "$(job "$job1" | jq -r .appUrl)"
check "output artifact-id empty with candidate" equal "$(output gh1 artifact-id)" ""
check "JUnit written" test -s "$gh_dir/junit.xml"
check "artifact name: suite and job" equal "$(output gh1 artifact-name)" "rfabric-sim-run-$suite-$job1"
check "job summary holds the CLI's scorecard" contains "$work/gh1/summary" "$(head -n 1 "$gh_dir/scorecard.md")"
check "the job records the pull request provenance" equal \
  "$(job "$job1" | jq -c '.ci | {repository, commit, pullRequest, headCommit}')" \
  "{\"repository\":\"https://github.com/acme/robot\",\"commit\":\"$gh_sha\",\"pullRequest\":42,\"headCommit\":\"$gh_sha\"}"
check "secretless: the CLI requested the GitHub identity token" matches \
  "$(count '.method == "GET" and (.url | startswith("/github-id-token?"))')" '^[1-9]'
check "one pull request comment created by the job token, marker first" equal \
  "$(count ".method == \"POST\" and .token == \"job-token\" and .url == \"/repos/acme/robot/issues/42/comments\" and (.body.body | startswith(\"$marker\n\"))")" 1
check "the comment holds the scorecard" equal \
  "$(requests '.method == "POST" and .token == "job-token" and .url == "/repos/acme/robot/issues/42/comments"' | jq -r .body.body | sed 1d)" \
  "$(cat "$gh_dir/scorecard.md")"

say "GitHub Action: a retried step reuses the job and updates the comment in place"
github_steps gh2
check "same job" equal "$(output gh2 job-id)" "$job1"
check "same exit code" equal "$gh_code" "$gh1_code"
check "no second comment" equal \
  "$(count '.method == "POST" and .token == "job-token" and .url == "/repos/acme/robot/issues/42/comments"')" 1
check "the comment updated in place" equal \
  "$(count ".method == \"PATCH\" and .token == \"job-token\" and (.url | test(\"^/repos/acme/robot/issues/comments/[0-9]+$\")) and (.body.body | startswith(\"$marker\"))")" 1
check "a reviewer's comment quoting the marker is never written" equal \
  "$(count ".method == \"PATCH\" and .url == \"/repos/acme/robot/issues/comments/$gh_reviewer\"")" 0

say "GitHub Action: a fork pull request's read-only token"
export GITHUB_REPOSITORY=acme/fork GITHUB_OUTPUT="$work/fork-output" GITHUB_STEP_SUMMARY="$work/fork-summary" RFABRIC_RESULT_DIR=$gh_dir
: > "$GITHUB_OUTPUT"
(cd "$gh_repo" && provider "$root/scripts/github.sh" publish) > "$work/fork.log" 2>&1
check "publish exits 0" equal "$?" 0
check "a notice, no failure" contains "$work/fork.log" "::notice title=rFabric::No pull request comment"
check "the refused write was the only attempt" equal "$(count '(.url | startswith("/repos/acme/fork/")) and .method != "GET"')" 1
check "outputs still set" equal "$(sed -n 's/^job-id=//p' "$GITHUB_OUTPUT")" "$job1"
export GITHUB_REPOSITORY=acme/robot
unset RFABRIC_RESULT_DIR

say "GitHub Action: register an image, preflight blockers as error annotations"
printf 'FROM scratch\nCOPY Dockerfile /policy\n' > "$work/Dockerfile"
docker build -q -t "rfabric-cli-test-candidate:$run_id" -f "$work/Dockerfile" "$work" > /dev/null || exit 1
image="rfabric-cli-test-candidate@$(docker image inspect --format '{{.Id}}' "rfabric-cli-test-candidate:$run_id")"
export GITHUB_RUN_ID="gh-blocked-$run_id" RFABRIC_IMAGE=$image \
  RFABRIC_MAX_WORKER_HOURS=0.000001 RFABRIC_MAX_PARALLEL_GPU=1 RFABRIC_MAX_PARALLEL_CPU=1
unset RFABRIC_CANDIDATE
github_steps gh-blocked
cat "$work/gh-blocked/run.log"
check "run step exits 1" equal "$gh_code" 1
check "output artifact-id: the registered artifact" matches "$(output gh-blocked artifact-id)" '^art_[0-9A-Za-z]{26}$'
check "one error annotation per blocker, titled with its code" equal \
  "$(sed -n 's/^::error title=\([^:]*\)::.*/\1/p' "$work/gh-blocked/publish.log" | sort | tr '\n' ' ')" \
  "$(jq -r '.blockers[].code' "$gh_dir/preflight.json" | sort | tr '\n' ' ')"
check "at least one blocker" matches "$(jq '.blockers | length' "$gh_dir/preflight.json")" '^[1-9]'
check "no job launched" equal "$(output gh-blocked job-id)" ""
check "the summary lists the blockers" contains "$work/gh-blocked/summary" "The launch preflight blocked the run"
unset RFABRIC_IMAGE RFABRIC_MAX_WORKER_HOURS RFABRIC_MAX_PARALLEL_GPU RFABRIC_MAX_PARALLEL_CPU
export RFABRIC_CANDIDATE=$candidate

say "GitHub Action: cancelling the workflow (SIGINT to the step's process) cancels the job"
export GITHUB_RUN_ID="gh-cancel-$run_id" GITHUB_OUTPUT="$work/gh-cancel-output" RFABRIC_SUITE=$held_suite
: > "$GITHUB_OUTPUT"
# Job control: the runner starts the step with SIGINT not ignored; so does the test.
set -m
(cd "$gh_repo" && provider "$root/scripts/github.sh" run) > "$work/gh-cancel.log" 2>&1 &
step_pid=$!
set +m
for _ in $(seq 100); do gh_dir=$(sed -n 's/^dir=//p' "$GITHUB_OUTPUT"); [[ -n $gh_dir ]] && break; sleep 0.1; done
if await_file "$gh_dir/job-id" "$step_pid"; then
  sleep 2
  kill -INT "$step_pid"
  wait "$step_pid"
  code=$?
  cancelled=$(cat "$gh_dir/job-id")
  check "exit 40 (got $code)" equal "$code" 40
  check "the CLI cancelled the job" contains "$work/gh-cancel.log" "Cancelled evaluation job $cancelled"
  check "the job is cancelled" equal "$(job "$cancelled" | jq -r .status)" cancelled
  check "outputs written after the interrupt" equal "$(jq -r '."job-id"' "$gh_dir/outputs.json")" "$cancelled"
else
  fail "the launch never wrote job-id"
  cat "$work/gh-cancel.log"
fi
unexport GITHUB_ ACTIONS_ RUNNER_ RFABRIC_

# ------------------------------------------------------------------------------------------
say "GitLab template: script, after_script, dotenv, merge request note"
gl_repo=$(repository gitlab)
gl_sha=$(git -C "$gl_repo" rev-parse HEAD)
# The failing suite, with the workspace input set.
inputs "$failing_suite"
export RFABRIC_WORKSPACE=$workspace
gitlab_token=$(mint "{\"project_id\":\"$gitlab_project_id\",\"sub\":\"project_path:acme/robot:ref_type:branch:ref:main\"}")
export GITLAB_CI=true CI_PROJECT_URL=https://gitlab.com/acme/robot CI_PROJECT_ID=$gitlab_project_id \
  CI_PROJECT_DIR=$gl_repo CI_COMMIT_SHA=$gl_sha CI_PIPELINE_ID="1$run_id" \
  CI_PIPELINE_URL="https://gitlab.com/acme/robot/-/pipelines/1$run_id" \
  CI_MERGE_REQUEST_IID=7 CI_MERGE_REQUEST_PROJECT_URL=https://gitlab.com/acme/robot \
  CI_MERGE_REQUEST_REF_PATH=refs/merge-requests/7/head CI_MERGE_REQUEST_SOURCE_BRANCH_SHA=$gl_sha \
  CI_API_V4_URL="$stub/api/v4" RFABRIC_GITLAB_TOKEN=gitlab-token RFABRIC_ID_TOKEN=$gitlab_token
gl_notes="/api/v4/projects/$gitlab_project_id/merge_requests/7/notes"
gl_reviewer=$(reviewer_comment "$gl_notes" \
  "$(jq -nc --arg marker "$(marker "$failing_suite")" '{body: "\($marker)\nA reviewer quoting the scorecard."}')") || exit 1
(cd "$gl_repo" && provider "$root/scripts/gitlab.sh" run) > "$work/gitlab.log" 2>&1
gl_code=$?
cat "$work/gitlab.log"
(cd "$gl_repo" && CI_JOB_STATUS=success provider "$root/scripts/gitlab.sh" after) > "$work/gitlab-after.log" 2>&1
check "after_script exits 0" equal "$?" 0
gl_dir="$gl_repo/rfabric-sim-run"
dotenv() { sed -n "s/^$1=//p" "$gl_dir/outputs.env"; }
gl_job=$(dotenv RFABRIC_JOB_ID)
check "a failing suite exits 10 (got $gl_code)" equal "$gl_code" 10
check "dotenv RFABRIC_CONCLUSION fail" equal "$(dotenv RFABRIC_CONCLUSION)" fail
check "dotenv RFABRIC_OPERATIONAL_CLASSIFICATION behavioral_failure" equal "$(dotenv RFABRIC_OPERATIONAL_CLASSIFICATION)" behavioral_failure
check "the workspace input was used" equal "$(job "$(dotenv RFABRIC_JOB_ID)" | jq -r .workspaceId)" "$workspace"
check "dotenv: the six outputs, nothing else" equal "$(cut -d= -f1 "$gl_dir/outputs.env" | tr '\n' ' ')" \
  "RFABRIC_JOB_ID RFABRIC_REPORT_ID RFABRIC_CONCLUSION RFABRIC_OPERATIONAL_CLASSIFICATION RFABRIC_JOB_URL RFABRIC_ARTIFACT_ID "
check "dotenv RFABRIC_JOB_ID" matches "$gl_job" '^evj_[0-9A-Za-z]{26}$'
check "dotenv RFABRIC_REPORT_ID" matches "$(dotenv RFABRIC_REPORT_ID)" '^evrp_'
check "dotenv RFABRIC_JOB_URL" equal "$(dotenv RFABRIC_JOB_URL)" "$(job "$gl_job" | jq -r .appUrl)"
check "a new job for a new pipeline" test "$gl_job" != "$job1"
check "junit report path" test -s "$gl_dir/junit.xml"
check "the job records the merge request provenance" equal \
  "$(job "$gl_job" | jq -c '.ci | {repository, commit, pullRequest}')" \
  "{\"repository\":\"https://gitlab.com/acme/robot\",\"commit\":\"$gl_sha\",\"pullRequest\":7}"
check "one merge request note created by the token's user, marker first" equal \
  "$(count ".method == \"POST\" and .token == \"gitlab-token\" and .url == \"$gl_notes\" and (.body.body | startswith(\"$(marker "$failing_suite")\"))")" 1
check "a reviewer's note quoting the marker is never written" equal \
  "$(count ".method == \"PUT\" and .url == \"$gl_notes/$gl_reviewer\"")" 0

say "GitLab template: a canceled job's after_script cancels the evaluation job"
export CI_PIPELINE_ID="2$run_id" RFABRIC_SUITE=$held_suite
rm -rf "$gl_dir"
set -m
(cd "$gl_repo" && provider "$root/scripts/gitlab.sh" run) > "$work/gitlab-cancel.log" 2>&1 &
script_pid=$!
set +m
if await_file "$gl_dir/job-id" "$script_pid"; then
  # GitLab may stop the job without signalling the CLI: kill the whole job unannounced.
  kill -KILL -- "-$script_pid"
  wait "$script_pid" 2> /dev/null
  cancelled=$(cat "$gl_dir/job-id")
  (cd "$gl_repo" && CI_JOB_STATUS=canceled provider "$root/scripts/gitlab.sh" after) > "$work/gitlab-cancel-after.log" 2>&1
  check "after_script exits 0" equal "$?" 0
  check "after_script cancelled the job" contains "$work/gitlab-cancel-after.log" "Cancelled $cancelled"
  check "the job is cancelled" equal "$(job "$cancelled" | jq -r .status)" cancelled
else
  fail "the launch never wrote job-id"
  cat "$work/gitlab-cancel.log"
fi
unexport GITLAB_ CI_ RFABRIC_

# ------------------------------------------------------------------------------------------
say "Bitbucket pipe: entry point, Code Insights, JUnit location, rfabric-result.json"
bb_repo=$(repository bitbucket)
bb_sha=$(git -C "$bb_repo" rev-parse HEAD)
bb_dir="$bb_repo/test-results/rfabric"
inputs "$failing_suite"
bitbucket_token=$(mint "{\"repositoryUuid\":\"$bitbucket_repository_uuid\",\"sub\":\"{pipeline-step}\"}")
export BITBUCKET_BUILD_NUMBER=$((RANDOM + 1000)) BITBUCKET_COMMIT=$bb_sha \
  BITBUCKET_GIT_HTTP_ORIGIN=http://bitbucket.org/acme/robot BITBUCKET_REPO_FULL_NAME=acme/robot \
  BITBUCKET_BRANCH=main BITBUCKET_PIPELINE_UUID="{bb-$run_id}" BITBUCKET_CLONE_DIR=$bb_repo BITBUCKET_PR_ID=5 \
  BITBUCKET_STEP_OIDC_TOKEN=$bitbucket_token \
  RFABRIC_BITBUCKET_PROXY=$stub RFABRIC_BITBUCKET_API_URL="$stub/bitbucket/2.0" RFABRIC_BITBUCKET_TOKEN=bitbucket-token
bb_comments="/bitbucket/2.0/repositories/acme/robot/pullrequests/5/comments"
bb_marker=$(marker "$failing_suite")
# bb_posts: the pipe's new pull request comments, the suite's marker first.
bb_posts() {
  count ".method == \"POST\" and .token == \"bitbucket-token\" and .url == \"$bb_comments\" and (.body.content.raw | startswith(\"$bb_marker\n\"))"
}
# bb_reads_or_edits: the pipe's lists and updates of pull request comments.
bb_reads_or_edits() { count "(.method == \"GET\" or .method == \"PUT\") and (.url | startswith(\"$bb_comments\"))"; }
(cd "$bb_repo" && provider "$root/scripts/pipe.sh") > "$work/pipe.log" 2>&1
bb_code=$?
cat "$work/pipe.log"
bb_job=$(jq -r '."job-id"' "$bb_repo/rfabric-result.json")
bb_classification=$(jq -r '."operational-classification"' "$bb_repo/rfabric-result.json")
reports="http://api.bitbucket.org/2.0/repositories/acme/robot/commit/$bb_sha/reports"
report_url="$reports/rfabric-sim-run-$failing_suite"
check "a failing suite exits 10 (got $bb_code)" equal "$bb_code" 10
check "JUnit under test-results/rfabric/" test -s "$bb_dir/junit.xml"
check "rfabric-result.json: the seven outputs" equal "$(jq -c 'keys_unsorted' "$bb_repo/rfabric-result.json")" \
  '["job-id","report-id","conclusion","operational-classification","job-url","artifact-id","suites"]'
check "rfabric-result.json job-id" matches "$bb_job" '^evj_[0-9A-Za-z]{26}$'
check "rfabric-result.json suites: the suite's job" equal "$(jq -r '.suites | map(.jobId) | join(" ")' "$bb_repo/rfabric-result.json")" "$bb_job"
check "the job records the Bitbucket provenance" equal \
  "$(job "$bb_job" | jq -c '.ci | {repository, commit, pullRequest}')" \
  "{\"repository\":\"https://bitbucket.org/acme/robot\",\"commit\":\"$bb_sha\",\"pullRequest\":5}"
report=$(requests ".method == \"PUT\" and .url == \"$report_url\"" | tail -n 1)
check "Code Insights report through the proxy" test -n "$report"
check "report result FAILED" equal "$(jq -r .body.result <<< "$report")" FAILED
check "rfabric-result.json classification behavioral_failure" equal "$bb_classification" behavioral_failure
check "report links the job" equal "$(jq -r .body.link <<< "$report")" "$(jq -r '."job-url"' "$bb_repo/rfabric-result.json")"
check "report details name the conclusion" matches "$(jq -r .body.details <<< "$report")" '^Conclusion: fail \(behavioral_failure\)'
check "report data: the job link" equal "$(jq -r '.body.data[] | select(.type == "LINK") | .value.text' <<< "$report")" "$bb_job"
# The CLI's failedCases: every case-side the JUnit report marks failed or errored.
failed_cases=$(jq -c '[.failedCases[].runId] | sort' "$bb_dir/report.json")
annotations=$(requests ".method == \"POST\" and .url == \"$report_url/annotations\"" | jq -s -c '[.[].body[]]')
check "the failing suite has failed cases" matches "$(jq length <<< "$failed_cases")" '^[1-9]'
check "one annotation per failed case" equal "$(jq -c '[.[].external_id] | sort' <<< "$annotations")" "$failed_cases"
check "the annotations name the criteria failure" equal \
  "$(jq -c '[.[].summary | test(": criteria not met")] | unique' <<< "$annotations")" '[true]'
check "one pull request comment posted, the suite's marker first" equal "$(bb_posts)" 1
check "no pull request comment listed or edited" equal "$(bb_reads_or_edits)" 0

say "Bitbucket pipe: the image (local CLI build) runs the entry point"
# The image's CLI: RFABRIC_TEST_IMAGE_CLI, else the CLI under test.
mkdir -p "$work/image-bin"
cp "${image_cli:-$work/bin/rfabric}" "$work/image-bin/rfabric" || exit 1
docker build -q --build-arg RFABRIC_CLI=local --build-context "cli=$work/image-bin" -t "$image_tag" "$root" > /dev/null \
  || { fail "docker build"; exit 1; }
# docker_pipe <docker run options...>: the pipe as Bitbucket runs it, with the exported variables.
docker_pipe() {
  local name options=()
  for name in $(compgen -e); do [[ $name =~ $provider_variables ]] && options+=(-e "$name"); done
  docker run --network host --user "$(id -u):$(id -g)" -v "$bb_repo:$bb_repo" -w "$bb_repo" \
    "${options[@]}" "$@" "$image_tag"
}
docker_pipe --rm > "$work/pipe-image.log" 2>&1
code=$?
cat "$work/pipe-image.log"
check "same exit code as on the host (got $code)" equal "$code" "$bb_code"
check "same job (same pipeline)" equal "$(jq -r '."job-id"' "$bb_repo/rfabric-result.json")" "$bb_job"
check "a second Code Insights report" equal "$(count ".method == \"PUT\" and .url == \"$report_url\"")" 2
check "the image's report equals the host's (the image's jq)" equal \
  "$(requests ".method == \"PUT\" and .url == \"$report_url\"" | tail -n 1 | jq -c .body)" "$(jq -c .body <<< "$report")"
check "the image's annotations equal the host's (the image's jq)" equal \
  "$(requests ".method == \"POST\" and .url == \"$report_url/annotations\"" | jq -s -c '[.[].body[]] | [length, unique]')" \
  "$(jq -c '[2 * length, unique]' <<< "$annotations")"
check "the second run posts one new comment" equal "$(bb_posts)" 2
check "still no pull request comment listed or edited" equal "$(bb_reads_or_edits)" 0

say "Bitbucket pipe: stopping the container (SIGTERM) cancels the job"
export BITBUCKET_PIPELINE_UUID="{bb-stop-$run_id}" RFABRIC_SUITE=$held_suite
rm -rf "$bb_dir"
docker_pipe -d --name "rfabric-cli-test-$run_id" > /dev/null
container_pid=$(docker inspect --format '{{.State.Pid}}' "rfabric-cli-test-$run_id")
if await_file "$bb_dir/job-id" "$container_pid"; then
  sleep 2
  docker stop -t 30 "rfabric-cli-test-$run_id" > /dev/null
  code=$(docker wait "rfabric-cli-test-$run_id")
  cancelled=$(cat "$bb_dir/job-id")
  docker logs "rfabric-cli-test-$run_id" > "$work/pipe-stop.log" 2>&1
  check "exit 40 (got $code)" equal "$code" 40
  check "the CLI cancelled the job" contains "$work/pipe-stop.log" "Cancelled evaluation job $cancelled"
  check "the job is cancelled" equal "$(job "$cancelled" | jq -r .status)" cancelled
  check "report PENDING without a verdict" equal \
    "$(requests ".method == \"PUT\" and .url == \"$reports/rfabric-sim-run-$held_suite\"" | tail -n 1 | jq -r .body.result)" PENDING
else
  fail "the launch never wrote job-id"
  docker logs "rfabric-cli-test-$run_id"
fi
unexport BITBUCKET_ RFABRIC_

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
