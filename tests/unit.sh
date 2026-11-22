#!/usr/bin/env bash
# Checks of the script logic that needs no stack (`mise run test` runs it before tests/run.sh):
# the release line promotion (scripts/promote.sh) against a local git origin and a simulated
# registry, a request body past the size limit of one argument (scripts/sim-run.sh api_call),
# the Bitbucket annotation limit (scripts/pipe.sh) with the Code Insights calls recorded, and the
# commands each wrapper entry point runs for a definition directory on each event (a pull
# request with unchanged or changed definitions, a base-branch push, a fork pull request, an
# empty suite selection, apply preview problems) and the client id they sign in with, in
# simulated GitHub, GitLab and Bitbucket environments, with the CLI and curl stubbed. Needs git
# and jq.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

say() { printf '\n== %s\n' "$*"; }
check() { # check <description> <command...>
  if "${@:2}"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}
equal() { [[ $1 == "$2" ]]; }

# ------------------------------------------------------------------------------------------
say "promote.sh: the stable patches of a line"
# shellcheck source=../scripts/promote.sh
patches() { (source "$root/scripts/promote.sh" && printf '%s\n' "${@:2}" | stable_patches "$1" | paste -sd ' ' -); }
check "numeric patch order, newest first" equal "$(patches 0.1 v0.1.9 v0.1.11 v0.1.10)" "v0.1.11 v0.1.10 v0.1.9"
check "ref names" equal "$(patches 0.1 refs/tags/v0.1.2 refs/tags/v0.1.10)" "v0.1.10 v0.1.2"
check "prereleases, the floating tag and other lines ignored" equal \
  "$(patches 0.1 v0.1.3 v0.1.4-rc.1 v0.1 v0.10.7 v1.1.9 v0.2.0)" v0.1.3
check "no release of the line" equal "$(patches 0.3 v0.1.3 v0.2.0)" ""

say "promote.sh: overlapping releases, a cancelled promotion"
# origin: a bare repository with release v0.1.9 (v0.1 points at it); its pre-receive hook logs
# each push and refuses every push while $work/refuse exists. The registry: one file per image
# tag under $work/registry holding its digest; every read fails while $work/registry/down exists.
git init -q --bare "$work/origin.git"
printf '#!/usr/bin/env bash\ncat >> "%s/pushes.log"\n[[ ! -e "%s/refuse" ]]\n' "$work" "$work" \
  > "$work/origin.git/hooks/pre-receive"
chmod +x "$work/origin.git/hooks/pre-receive"
git init -q "$work/clone"
git -C "$work/clone" remote add origin "$work/origin.git"
# release <version> [annotated]: a commit tagged v<version>, pushed; prints the commit.
release() {
  git -C "$work/clone" -c user.email=ci@example.com -c user.name=ci commit -q --allow-empty -m "$1"
  if [[ -n ${2:-} ]]; then
    git -C "$work/clone" -c user.email=ci@example.com -c user.name=ci tag -a -m "v$1" "v$1"
  else
    git -C "$work/clone" tag "v$1"
  fi
  git -C "$work/clone" push -q origin HEAD:refs/heads/main "refs/tags/v$1"
  git -C "$work/clone" rev-parse HEAD
}
mkdir -p "$work/registry" "$work/bin"
publish() { printf 'sha256:%s' "$1" > "$work/registry/$1"; }
cat > "$work/bin/docker" << 'EOF'
#!/usr/bin/env bash
# docker buildx imagetools inspect --format <format> <image> | create --tag <image> <image>
[[ ! -e $REGISTRY/down ]] || { echo "ERROR: registry unreachable" >&2; exit 1; }
case $3 in
  inspect) cat "$REGISTRY/${6##*:}" 2> /dev/null || { echo "ERROR: $6: not found" >&2; exit 1; } ;;
  create) printf '%s\n' "$*" >> "$REGISTRY/../docker.log" && cp "$REGISTRY/${6##*:}" "$REGISTRY/${5##*:}" ;;
esac
EOF
chmod +x "$work/bin/docker"
: > "$work/docker.log"
c9=$(release 0.1.9)
# v0.1 points at 0.1.9 as an annotated tag, as a tag made by hand may be.
git -C "$work/clone" -c user.email=ci@example.com -c user.name=ci tag -a -m v0.1 v0.1 "$c9"
git -C "$work/clone" push -q origin refs/tags/v0.1
publish 0.1.9
cp "$work/registry/0.1.9" "$work/registry/0.1"
# The job's clone: a shallow checkout of one release, without the other tags.
git clone -q --depth 1 --branch v0.1.9 "file://$work/origin.git" "$work/job" 2> /dev/null
promote() { (cd "$work/job" && PATH="$work/bin:$PATH" REGISTRY="$work/registry" IMAGE=registry.example/cli "$root/scripts/promote.sh" "$1"); }
floating() { git -C "$work/origin.git" rev-parse "v0.1^{commit}"; }
image() { cat "$work/registry/0.1"; }
lines() { wc -l < "$1" | tr -d ' '; }

: > "$work/pushes.log"
promote 0.1.9 > /dev/null 2>&1
check "an annotated v0.1 already at the release: exits 0" equal "$?" 0
check "it pushes nothing" equal "$(lines "$work/pushes.log")" 0
check "it copies no image" equal "$(lines "$work/docker.log")" 0
# Three overlapping releases, tagged before any promotion runs; v0.1.11 annotated, as a tag may be.
c11=$(release 0.1.11 annotated)
release 0.1.12 > /dev/null
c13=$(release 0.1.13)
publish 0.1.11
promote 0.1.11 > "$work/promote-11.log" 2>&1
check "0.1.11 done first, 0.1.12 and 0.1.13 still building: exits 0" equal "$?" 0
check "it moves the git tag to 0.1.11" equal "$(floating)" "$c11"
check "it moves the image tag to 0.1.11" equal "$(image)" sha256:0.1.11
publish 0.1.13 # its promotion is cancelled
publish 0.1.12
promote 0.1.12 > "$work/promote-12.log" 2>&1
check "the 0.1.12 run exits 0" equal "$?" 0
check "it moves the git tag to 0.1.13" equal "$(floating)" "$c13"
check "it moves the image tag to 0.1.13" equal "$(image)" sha256:0.1.13
check "it says so" grep -qx "v0.1 and registry.example/cli:0.1 point at 0.1.13" "$work/promote-12.log"
check "release tags untouched" equal "$(git -C "$work/origin.git" rev-parse "v0.1.11^{commit}")" "$c11"
pushes=$(lines "$work/pushes.log") creates=$(lines "$work/docker.log")
promote 0.1.12 > /dev/null 2>&1
check "a promotion with both references in place exits 0" equal "$?" 0
check "it pushes nothing" equal "$(lines "$work/pushes.log")" "$pushes"
check "it copies no image" equal "$(lines "$work/docker.log")" "$creates"

say "promote.sh: a refused git push, a registry error"
c14=$(release 0.1.14)
publish 0.1.14
touch "$work/refuse"
promote 0.1.14 > /dev/null 2>&1
check "a refused git push fails" equal "$?" 1
check "it leaves the git tag" equal "$(floating)" "$c13"
check "it leaves the image tag" equal "$(image)" sha256:0.1.13
rm "$work/refuse"
promote 0.1.14 > /dev/null 2>&1
check "the re-run exits 0" equal "$?" 0
check "it moves both references" equal "$(floating) $(image)" "$c14 sha256:0.1.14"
release 0.1.15 > /dev/null # its image is never published
promote 0.1.15 > "$work/promote-15.log" 2>&1
check "the release's own image unreadable, the older v0.1 target's readable: fails" equal "$?" 1
check "it moves neither reference" equal "$(floating) $(image)" "$c14 sha256:0.1.14"
check "it says why" grep -qF "the image registry.example/cli:0.1.15 of this release cannot be read" "$work/promote-15.log"
touch "$work/registry/down"
promote 0.1.13 > "$work/promote-down.log" 2>&1
check "an older release, an unreadable registry: fails" equal "$?" 1
check "it moves neither reference back" equal "$(floating) $(image)" "$c14 sha256:0.1.14"
check "it says why" grep -qF "v0.1 points at v0.1.14, whose image registry.example/cli:0.1.14 cannot be read" "$work/promote-down.log"
rm "$work/registry/down"
promote 0.1 > /dev/null 2>&1
check "an argument that is not <major>.<minor>.<patch> exits 2" equal "$?" 2

# ------------------------------------------------------------------------------------------
say "sim-run.sh: a request body past the size limit of one argument"
# curl records the body it reads; past 131072 bytes it would not start with the body as an argument.
printf '#!/usr/bin/env bash\ncat > "%s/curl-body"\nprintf "{}\\n200"\n' "$work" > "$work/bin/curl"
chmod +x "$work/bin/curl"
large=$(jq -cn '[range(20000) | {external_id: "evr_\(.)"}]')
# shellcheck source=../scripts/sim-run.sh
(source "$root/scripts/sim-run.sh" && PATH="$work/bin:$PATH" api_call POST http://api.example/x "$large" > /dev/null)
check "a ${#large}-byte body is sent" equal "$?" 0
check "curl receives it whole" equal "$(cat "$work/curl-body")" "$large"

# ------------------------------------------------------------------------------------------
say "pipe.sh: annotations up to Bitbucket's limit"
# annotate <failed cases>: insights for a report with that many failed cases; the recorded Code
# Insights calls in $work/insights-<n>.jsonl.
annotate() {
  local clone="$work/bitbucket-$1"
  mkdir -p "$clone/test-results/rfabric"
  jq -n --argjson n "$1" '{jobId: "evj_01JZ0000000000000000000000", conclusionStatus: "fail",
    operationalClassification: "behavioral_failure",
    failedCases: [range($n) | {runId: "evr_\(.)", caseKey: "case-\(.)", side: "candidate", cellId: null,
      scenarioId: "evs_1", seed: ., outcome: "failure", reason: "criteria not met"}]}' \
    > "$clone/test-results/rfabric/report.json"
  printf '{"job-id": "evj_01JZ0000000000000000000000"}' > "$clone/test-results/rfabric/outputs.json"
  # Sourced, pipe.sh returns before its main block, whose exit shellcheck takes as reached.
  # shellcheck disable=SC2317,SC2329
  (
    export BITBUCKET_CLONE_DIR=$clone BITBUCKET_REPO_FULL_NAME=acme/robot BITBUCKET_COMMIT=abc RFABRIC_SUITE=pass
    # shellcheck source=../scripts/pipe.sh
    source "$root/scripts/pipe.sh"
    insights_api() { # records the call; Bitbucket accepts it
      jq -nc --arg method "$1" --arg path "$2" --argjson body "$3" '{method: $method, path: $path, body: $body}' \
        >> "$work/insights-$1.jsonl"
      api_status=200
    }
    insights 10
  )
  mv "$work/insights-PUT.jsonl" "$work/insights-$1-report.jsonl"
  mv "$work/insights-POST.jsonl" "$work/insights-$1-annotations.jsonl"
}
annotated() { jq -s '[.[].body | length] | "\(length) requests, \(add) annotations, largest \(max)"' -r "$work/insights-$1-annotations.jsonl"; }
details() { jq -r .body.details "$work/insights-$1-report.jsonl"; }

annotate 1000
check "1000 failed cases: every one annotated, 100 per request" equal "$(annotated 1000)" "10 requests, 1000 annotations, largest 100"
check "1000 failed cases: no limit note" equal "$(details 1000)" "Conclusion: fail (behavioral_failure)."
annotate 1234
check "1234 failed cases: the first 1000 annotated" equal "$(annotated 1234)" "10 requests, 1000 annotations, largest 100"
check "1234 failed cases: the first cases are the annotated ones" equal \
  "$(jq -s -r '[.[].body[].external_id] | first + " " + last' "$work/insights-1234-annotations.jsonl")" "evr_0 evr_999"
check "1234 failed cases: the details say so" equal "$(details 1234)" \
  "Conclusion: fail (behavioral_failure).
1234 failed cases, the first 1000 annotated; the scorecard lists them all."

# ------------------------------------------------------------------------------------------
say "wrappers: a definition directory's commands per event (stubbed CLI)"
# The stub CLI appends each call to $FAKE/calls and answers from the scenario: definitions.json
# (the apply preview or apply result) with exit FAKE_DEFINITIONS_CODE, `sim run --dir` with
# FAKE_SIM_CODE (20: no approved suite matches), `eval test-run` with FAKE_TEST_RUN_CODE.
# curl (provider comments, Code Insights) answers 200.
mkdir -p "$work/stub-bin"
cat > "$work/stub-bin/rfabric" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"
printf '%s\n' "${RFABRIC_CLIENT_ID:-}" >> "$FAKE/client-ids"
value() { # value <flag> <args...>: the value after the flag
  local name=$1
  shift
  while [[ $# -gt 0 ]]; do [[ $1 == "$name" ]] && { printf '%s' "$2"; return; }; shift; done
}
markdown=$(value --markdown "$@")
case "$1 $2" in
  "artifact-build register") echo '{"id": "art_01JZ00000000000000000000IM"}' ;;
  "eval apply")
    title="apply"
    [[ " $* " == *" --preview "* ]] && title="apply preview"
    printf '# Definition directory - %s\n\n%s\n' "$title" "$(jq -r '.problems[]? | "- problem: \(.message)"' "$FAKE/definitions.json")" > "$markdown"
    cat "$FAKE/definitions.json"
    exit "${FAKE_DEFINITIONS_CODE:-0}"
    ;;
  "sim run")
    if [[ ${FAKE_SIM_CODE:-0} -eq 20 ]]; then
      printf '# Simulation suites\n\nNot passing: no approved suite matches.\n' > "$markdown"
      echo "Error: no approved suite matches" >&2
      exit 20
    fi
    echo "! suite put-away: baseline artifact art_x from job evj_01JZ0000000000000000BASE01 on refs/heads/main" >&2
    echo "✓ Simulation job evj_01JZ0000000000000000000001 (queued, 5 runs, suite put-away@2)" >&2
    printf '<testsuites/>\n' > "$(value --junit-dir "$@")/put-away.xml"
    printf '# Simulation suites\n\n| `put-away@2` | pass |\n' > "$markdown"
    echo '[{"suite": "put-away", "version": 2, "jobId": "evj_01JZ0000000000000000000001", "exitCode": 0,
      "report": {"id": "evrp_01JZ0000000000000000000001", "conclusionStatus": "pass", "operationalClassification": "complete_pass", "failedCases": []}}]'
    exit "${FAKE_SIM_CODE:-0}"
    ;;
  "eval test-run")
    printf '# Test run - not yet approved\n\n| `put-away@3` | exit %s |\n' "${FAKE_TEST_RUN_CODE:-0}" > "$markdown"
    exit "${FAKE_TEST_RUN_CODE:-0}"
    ;;
  "evaluation-job get") printf '{"appUrl": "https://app.example/jobs/%s"}\n' "$3" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nif [[ " $* " == *" GET "* ]]; then printf "[]\\n200"; else printf "{}\\n200"; fi\n' > "$work/stub-bin/curl"
chmod +x "$work/stub-bin/rfabric" "$work/stub-bin/curl"

# definitions <file> <entry actions...> [problem]: an apply result with one entry per action.
definitions() {
  mkdir -p "$(dirname "$1")"
  jq -n --args '{action: "preview", entries: [$ARGS.positional[] | select(. != "problem")
    | {path: "scenarios/put-away.yaml", kind: "scenario", slug: "put-away", action: ., changes: []}],
    problems: [$ARGS.positional[] | select(. == "problem") | {path: "scenarios/put-away.yaml", field: "mission",
    code: "reference_unresolved", message: "reference task@1 is not published"}], removed: [], unchecked: []}' "${@:2}" > "$1"
}

# scenario <provider> <event> <name> [VARIABLE=value...]: runs the provider's entry points for
# the definition directory eval in a fresh environment holding only that provider's variables
# and the given ones; sets code (the step's exit code), calls (the stub CLI's commands: the
# subcommand plus --preview, --changed, --suite, --baseline and --base-branch with their values,
# sorted, one per line, `evaluation-job get` left out), client_ids (the distinct client ids the
# CLI calls signed in with, space separated) and result (the run's result directory).
scenario() {
  local provider=$1 event=$2 home="$work/$1-$3" variables=()
  shift 3
  mkdir -p "$home/runner" "$home/repo"
  export FAKE=$home
  : > "$home/calls"
  : > "$home/client-ids"
  [[ -s $home/definitions.json ]] || definitions "$home/definitions.json" unchanged
  variables=(PATH="$work/stub-bin:$PATH" HOME="$HOME" FAKE="$home" RFABRIC_DIR=eval RFABRIC_CLIENT_ID=rf_svc_test
    RFABRIC_CANDIDATE=art_01JZ00000000000000000000CA RFABRIC_WALL_DEADLINE=600)
  case $provider:$event in
    github:*)
      printf '{"repository": {"default_branch": "main"}, "pull_request": {"number": 42}}' > "$home/event.json"
      variables+=(GITHUB_ACTIONS=true GITHUB_REPOSITORY=acme/robot GITHUB_EVENT_PATH="$home/event.json"
        GITHUB_API_URL=http://github.invalid GITHUB_TOKEN=job-token RUNNER_TEMP="$home/runner"
        GITHUB_OUTPUT="$home/output" GITHUB_STEP_SUMMARY="$home/summary")
      ;;&
    github:pull_request) variables+=(GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/42/merge ACTIONS_ID_TOKEN_REQUEST_URL=http://token.invalid) ;;
    github:fork) variables+=(GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/42/merge) ;;
    github:push) variables+=(GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main ACTIONS_ID_TOKEN_REQUEST_URL=http://token.invalid) ;;
    gitlab:*) variables+=(GITLAB_CI=true CI_PROJECT_DIR="$home/repo" CI_PROJECT_ID=4242 CI_DEFAULT_BRANCH=main) ;;&
    gitlab:pull_request) variables+=(CI_MERGE_REQUEST_IID=7 CI_MERGE_REQUEST_PROJECT_ID=4242 RFABRIC_ID_TOKEN=token) ;;
    gitlab:fork) variables+=(CI_PROJECT_ID=4343 CI_MERGE_REQUEST_IID=7 CI_MERGE_REQUEST_PROJECT_ID=4242 RFABRIC_ID_TOKEN=fork-token) ;;
    gitlab:push) variables+=(CI_COMMIT_BRANCH=main RFABRIC_ID_TOKEN=token) ;;
    bitbucket:*)
      variables+=(BITBUCKET_CLONE_DIR="$home/repo" BITBUCKET_COMMIT=abc BITBUCKET_REPO_FULL_NAME=acme/robot
        RFABRIC_BITBUCKET_PROXY=http://proxy.invalid)
      ;;&
    bitbucket:pull_request) variables+=(BITBUCKET_PR_ID=5 BITBUCKET_BRANCH=feature BITBUCKET_STEP_OIDC_TOKEN=token) ;;
    bitbucket:fork) variables+=(BITBUCKET_PR_ID=5 BITBUCKET_BRANCH=feature) ;;
    bitbucket:push) variables+=(BITBUCKET_BRANCH=main BITBUCKET_STEP_OIDC_TOKEN=token) ;;
  esac
  variables+=("$@")
  case $provider in
    github)
      : > "$home/output"
      env -i "${variables[@]}" "$root/scripts/github.sh" run > "$home/run.log" 2>&1
      code=$?
      result=$(sed -n 's/^dir=//p' "$home/output")
      env -i "${variables[@]}" RFABRIC_RESULT_DIR="$result" GITHUB_OUTPUT="$home/publish-output" \
        "$root/scripts/github.sh" publish > "$home/publish.log" 2>&1
      ;;
    gitlab)
      env -i "${variables[@]}" "$root/scripts/gitlab.sh" run > "$home/run.log" 2>&1
      code=$?
      env -i "${variables[@]}" CI_JOB_STATUS=success "$root/scripts/gitlab.sh" after > "$home/after.log" 2>&1
      result="$home/repo/rfabric-sim-run"
      ;;
    bitbucket)
      env -i "${variables[@]}" "$root/scripts/pipe.sh" > "$home/run.log" 2>&1
      code=$?
      result="$home/repo/test-results/rfabric"
      ;;
  esac
  calls=$(awk '$1 " " $2 != "evaluation-job get" {
    line = $1 " " $2
    for (i = 3; i <= NF; i++) {
      if ($i == "--preview" || $i == "--changed") line = line " " $i
      if ($i == "--suite" || $i == "--baseline" || $i == "--base-branch" || $i == "--candidate") line = line " " $i " " $(i + 1)
    }
    print line }' "$home/calls" | sort)
  client_ids=$(sort -u "$home/client-ids" | paste -sd ' ' -)
}
summary() { cat "$result/summary.md"; }
contains() { grep -qF -- "$2" <<< "$1"; }

for provider in github gitlab bitbucket; do
  scenario "$provider" pull_request unchanged RFABRIC_PULL_REQUEST_CLIENT_ID=
  check "$provider pull request, pull-request-client-id empty: client-id signs in" equal "$client_ids" rf_svc_test
  check "$provider pull request, definitions unchanged: preview then the blocking run, no test run" equal "$calls" \
    "eval apply --preview
sim run --candidate art_01JZ00000000000000000000CA"
  check "$provider pull request, definitions unchanged: exit 0 (got $code)" equal "$code" 0
  # shellcheck disable=SC2016 # the backticks are markdown
  check "$provider pull request, definitions unchanged: the summary holds the scorecard only" equal "$(summary)" \
    "$(printf '# Simulation suites\n\n| `put-away@2` | pass |')"
  check "$provider pull request: the suites output" equal "$(jq -c .suites "$result/outputs.json")" \
    '[{"suite":"put-away","version":2,"jobId":"evj_01JZ0000000000000000000001","exitCode":0,"reportId":"evrp_01JZ0000000000000000000001","conclusion":"pass","operationalClassification":"complete_pass","jobUrl":"https://app.example/jobs/evj_01JZ0000000000000000000001"}]'
  check "$provider pull request: the launch line's job is recorded, never the baseline's" equal "$(cat "$result/job-id")" \
    evj_01JZ0000000000000000000001
  check "$provider pull request: one JUnit file per suite" test -s "$result/put-away.xml"

  definitions "$work/$provider-changed/definitions.json" version
  scenario "$provider" pull_request changed FAKE_TEST_RUN_CODE=10 RFABRIC_CANDIDATE= RFABRIC_IMAGE=ghcr.io/acme/controller@sha256:4f2a
  check "$provider pull request, a changed scenario: image registered once, preview, blocking run and test run on it" equal "$calls" \
    "artifact-build register
eval apply --preview
eval test-run --candidate art_01JZ00000000000000000000IM --changed
sim run --candidate art_01JZ00000000000000000000IM"
  check "$provider pull request, a changed scenario: a failing test run never fails the step (got $code)" equal "$code" 0
  check "$provider pull request, a changed scenario: the test run's exit code is kept" equal "$(cat "$result/test-run-exit-code")" 10
  check "$provider pull request, a changed scenario: summary: scorecard, apply preview, test run" equal \
    "$(grep '^# ' <<< "$(summary)")" "$(printf '# Simulation suites\n# Definition directory - apply preview\n# Test run - not yet approved')"

  scenario "$provider" push base RFABRIC_BASELINE=auto
  check "$provider base-branch push: apply, then the blocking run with the default branch as base" equal "$calls" \
    "eval apply
sim run --candidate art_01JZ00000000000000000000CA --baseline auto --base-branch main"
  check "$provider base-branch push: exit 0 (got $code)" equal "$code" 0

  scenario "$provider" pull_request pull-request-credential RFABRIC_PULL_REQUEST_CLIENT_ID=rf_svc_pull_request
  check "$provider pull request, pull-request-client-id set: every CLI call signs in with it" equal "$client_ids" rf_svc_pull_request
  check "$provider pull request, pull-request-client-id set: exit 0 (got $code)" equal "$code" 0

  scenario "$provider" push base-branch-credential RFABRIC_PULL_REQUEST_CLIENT_ID=rf_svc_pull_request
  check "$provider base-branch push, pull-request-client-id set: client-id signs in" equal "$client_ids" rf_svc_test

  scenario "$provider" fork fork
  check "$provider fork pull request: no CLI call" equal "$calls" ""
  check "$provider fork pull request: fails (got $code)" equal "$code" 1
  check "$provider fork pull request: the summary asks for a trusted run" contains "$(summary)" "A trusted run on the same commit is needed"

  scenario "$provider" pull_request empty FAKE_SIM_CODE=20 RFABRIC_SUITES="nothing, missing"
  check "$provider empty selection: the selection reaches the blocking run" equal "$calls" \
    "eval apply --preview
sim run --candidate art_01JZ00000000000000000000CA --suite nothing --suite missing"
  check "$provider empty selection: not passing, exit 20 (got $code)" equal "$code" 20
  check "$provider empty selection: the summary says no approved suite matches" contains "$(summary)" "no approved suite matches"

  definitions "$work/$provider-problems/definitions.json" version problem
  scenario "$provider" pull_request problems FAKE_DEFINITIONS_CODE=3
  check "$provider apply preview problems: nothing runs after the preview" equal "$calls" "eval apply --preview"
  check "$provider apply preview problems: exit 3 (got $code)" equal "$code" 3
  check "$provider apply preview problems: the summary lists them" contains "$(summary)" "- problem: reference task@1 is not published"
done

# A canceled GitLab job cancels its evaluation jobs in after_script, a new shell: on a merge
# request it signs in with the pull request client id, as the run did.
canceled="$work/gitlab-pull-request-credential"
rm "$canceled/repo/rfabric-sim-run/exit-code"
: > "$canceled/calls"
: > "$canceled/client-ids"
env -i PATH="$work/stub-bin:$PATH" HOME="$HOME" FAKE="$canceled" RFABRIC_DIR=eval RFABRIC_CLIENT_ID=rf_svc_test \
  RFABRIC_PULL_REQUEST_CLIENT_ID=rf_svc_pull_request GITLAB_CI=true CI_PROJECT_DIR="$canceled/repo" CI_PROJECT_ID=4242 \
  CI_DEFAULT_BRANCH=main CI_MERGE_REQUEST_IID=7 CI_MERGE_REQUEST_PROJECT_ID=4242 CI_JOB_STATUS=canceled \
  "$root/scripts/gitlab.sh" after > "$canceled/after-canceled.log" 2>&1
check "GitLab canceled merge request job: after_script cancels the evaluation job" equal "$(cat "$canceled/calls")" \
  "evaluation-job cancel evj_01JZ0000000000000000000001 --output json"
check "GitLab canceled merge request job: the cancel signs in with pull-request-client-id" equal \
  "$(sort -u "$canceled/client-ids")" rf_svc_pull_request

check "GitHub: the suites output is a step output" equal \
  "$(sed -n 's/^suites=//p' "$work/github-unchanged/publish-output" | jq -r '.[0].suite')" put-away
check "GitHub: the fork notice is an error annotation" grep -q '^::error title=rFabric::Not run: this pull request job cannot reach rFabric' \
  "$work/github-fork/publish.log"
check "GitLab: dotenv keeps the six outputs" equal "$(cut -d= -f1 "$work/gitlab-unchanged/repo/rfabric-sim-run/outputs.env" | tr '\n' ' ')" \
  "RFABRIC_JOB_ID RFABRIC_REPORT_ID RFABRIC_CONCLUSION RFABRIC_OPERATIONAL_CLASSIFICATION RFABRIC_JOB_URL RFABRIC_ARTIFACT_ID "
check "Bitbucket: rfabric-result.json holds the suites output" equal \
  "$(jq -r '.suites[0].jobId' "$work/bitbucket-unchanged/repo/rfabric-result.json")" evj_01JZ0000000000000000000001

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
