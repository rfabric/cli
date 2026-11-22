#!/usr/bin/env bash
# Checks of the script logic that needs no stack (`mise run test` runs it before tests/run.sh):
# the release line promotion (scripts/promote.sh) against a local git origin and a simulated
# registry, a request body past the size limit of one argument (scripts/sim-run.sh api_call),
# and the Bitbucket annotation limit (scripts/pipe.sh) with the Code Insights calls recorded.
# Needs git and jq.
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
patches() { (source "$root/scripts/promote.sh" && printf '%s\n' "${@:2}" | stable_patches "$1" | paste -sd ' '); }
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

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
