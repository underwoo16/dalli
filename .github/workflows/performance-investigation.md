---
name: Performance investigation
description: Find measured, backwards-compatible Dalli optimizations in the development container.
intent: Improve Dalli performance without changing existing behavior or overwhelming maintainers.
on:
  schedule: every 3 days
  workflow_dispatch:
  skip-if-match:
    query: is:pr is:open label:performance
    max: 3
concurrency:
  group: performance-investigation-${{ github.repository }}
  cancel-in-progress: false
permissions:
  contents: read
  pull-requests: read
  copilot-requests: write
timeout-minutes: 60
strict: true
network:
  allowed: []
tools:
  github:
    mode: gh-proxy
    toolsets: [repos, pull_requests]
  cli-proxy: true
  timeout: 900
pre-agent-steps:
  - name: Prepare the existing devcontainer and performance dependencies
    run: |
      docker build --build-arg USER_UID="$(id -u)" -t dalli-devcontainer .devcontainer
      docker build -t dalli-performance -f - . <<'DOCKERFILE'
      FROM dalli-devcontainer
      COPY --chown=vscode:vscode Gemfile Rakefile dalli.gemspec /workspace/
      COPY --chown=vscode:vscode lib /workspace/lib
      COPY --chown=vscode:vscode bin /workspace/bin
      COPY --chown=vscode:vscode scripts /workspace/scripts
      COPY --chown=vscode:vscode .devcontainer /workspace/.devcontainer
      RUN bash .devcontainer/setup.sh
      RUN memcached -d && memcached -d -p 11222 && \
          BENCH_TARGET=get BENCH_TIME=1 BENCH_WARMUP=1 bundle exec bin/benchmark && \
          BENCH_TARGET=get BENCH_TIME=1 bundle exec bin/profile
      DOCKERFILE
mcp-scripts:
  measure:
    description: Evaluate the current source read-only in an offline devcontainer; return benchmark, profile, test or lint output.
    timeout: 900
    inputs:
      operation:
        type: string
        required: true
        description: One of benchmark, profile, test, lint.
      target:
        type: string
        default: get
        description: One of get, set, get_multi, set_multi, all.
      payload:
        type: string
        default: "700000"
        description: Payload size in bytes; one of 100, 4096, 700000.
    env:
      GITHUB_WORKSPACE: ${{ github.workspace }}
    run: |
      set -euo pipefail
      case "$INPUT_OPERATION" in benchmark|profile|test|lint) ;; *) exit 1 ;; esac
      case "$INPUT_TARGET" in get|set|get_multi|set_multi|all) ;; *) exit 1 ;; esac
      case "$INPUT_PAYLOAD" in 100|4096|700000) ;; *) exit 1 ;; esac
      timeout 840 docker run --rm --network none --cap-drop ALL \
        --security-opt no-new-privileges --read-only --cpus 2 --memory 4g --pids-limit 256 \
        --tmpfs /tmp:rw,exec,mode=1777 \
        --volume "$GITHUB_WORKSPACE:/source:ro" \
        --env HOME=/tmp/home --env RUBY_YJIT_ENABLE=1 \
        --env BENCH_TARGET="$INPUT_TARGET" --env BENCH_PAYLOAD_SIZE="$INPUT_PAYLOAD" \
        --env BENCH_TIME=10 --env BENCH_WARMUP=3 \
        dalli-performance bash -euo pipefail -c '
          mkdir -p /tmp/home /tmp/dalli
          cp -a /source/lib /source/test /source/bin /source/Gemfile /source/Rakefile \
            /source/dalli.gemspec /source/.rubocop.yml /source/.rubocop_todo.yml \
            /source/README.md /source/LICENSE /source/CHANGELOG.md /tmp/dalli/
          cp /workspace/Gemfile.lock /tmp/dalli/Gemfile.lock
          cd /tmp/dalli
          ruby --version
          memcached -h | sed -n '1p'
          printf "YJIT=%s target=%s payload=%s time=%s warmup=%s\n" \
            "$RUBY_YJIT_ENABLE" "$BENCH_TARGET" "$BENCH_PAYLOAD_SIZE" "$BENCH_TIME" "$BENCH_WARMUP"
          memcached -d
          memcached -d -p 11222
          case "$1" in
            benchmark) bundle exec bin/benchmark ;;
            profile)
              bundle exec bin/profile > /tmp/profile.log 2>&1 || { tail -n 40 /tmp/profile.log; exit 1; }
              grep -E "^(yjit|Warming|Calculating)|i/s|Comparison" /tmp/profile.log | head -n 60 || true
              bundle exec bin/profile_summary --top 12 *_profile.json
              ;;
            test) bundle exec rake ;;
            lint) bundle exec rubocop --cache false ;;
          esac
        ' -- "$INPUT_OPERATION"
jobs:
  safe_outputs:
    pre-steps:
      - name: Recheck the open performance PR budget before publishing
        uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0
        with:
          script: |
            let count = 0;
            for await (const page of github.paginate.iterator(github.rest.issues.listForRepo, {
              ...context.repo, state: "open", labels: "performance", per_page: 100
            })) {
              count += page.data.filter(item => item.pull_request).length;
              if (count >= 3) {
                core.setFailed("There are already at least three open performance pull requests.");
                return;
              }
            }
safe-outputs:
  report-failure-as-issue: false
  create-pull-request:
    max: 1
    labels: [performance]
    draft: true
    fallback-as-issue: false
    allowed-files:
      - lib/**/*.rb
      - test/**/*.rb
    protected-files: blocked
  noop:
    report-as-issue: false
---

# Performance investigation

On this scheduled or manually dispatched run, investigate one worthwhile performance
optimization. Use the repository's existing devcontainer, `bin/benchmark` and
`bin/profile`; do not substitute host measurements or invent results.

## Investigate and measure

1. Read `CONTRIBUTING.md`, `CLAUDE.md`, `Performance.md`, and the relevant source and
   tests. Use read-only `gh pr list --state open --label performance --limit 3`
   to inspect existing work, including drafts. If three PRs are open, call `noop`.
   Avoid overlapping existing PRs or repeating rejected optimizations.
2. Use `mcpscripts measure --operation profile --target get --payload 100`
   (adjusting the allowlisted operation, target and payload) for benchmark, profiling, test, and lint
   execution. Each call runs exactly one target and payload, so call it in a loop to
   cover every combination. Its fixed commands run in fresh offline containers built from
   `.devcontainer/Dockerfile` and initialized with `.devcontainer/setup.sh`.
   Source is mounted read-only, with computation and generated files confined to
   disposable container storage. No credentials or Docker socket are passed in.
   Profile output is a compact top-function summary per profile, not raw Vernier JSON.
   Keep all tool output and your own messages small: never print or paste large raw
   files, and use `head`/`grep`/`jq` on any saved output.
3. **Survey broadly, starting with profiles.** Before choosing a candidate, run
   `profile` for each of `get`, `set`, `get_multi` and `set_multi` at payloads 100 and
   4096 (plus 700000 where large values matter). Rank hotspots by self and total
   time and by allocations, and read the relevant source. Choose the candidate from
   the profile, then confirm it with benchmarks. A clear hotspot is a valid lead even
   when throughput is noisy. Do not anchor on `get`.
   Save the actual output in the agent workspace outside the repository.
4. Make one small optimization in `lib/` with regression coverage in `test/`.
   Only fully backwards-compatible changes qualify: preserve public APIs,
   return values, exceptions, defaults, key/value serialization and compression,
   protocol behavior, ordering, failover, timeouts, TLS, and thread/fork safety.
   Do not raise minimum Ruby/memcached versions, add dependencies, weaken tests,
   modify the benchmark harness, or change workflows/devcontainer configuration.
5. Re-run the same benchmark and profile configurations after the change. Obtain
   at least five benchmark runs per revision, alternating baseline and candidate
   runs (A/B/A/B) so drift affects both equally, and compare medians and spread
   (coefficient of variation) with identical target, payload,
   YJIT, warmup, timing, CPU/memory limits, and dependency versions. Include small
   and large payloads and relevant adjacent operations. Treat a gain as real
   when the median improvement exceeds the run-to-run spread. If throughput is too
   noisy to tell, use lower-noise evidence instead: fewer allocations, objects or
   method calls in the profile, or a reduced amount of work per operation. Such a
   deterministic reduction can justify a change even when throughput is within noise,
   provided it is shown and no operation regresses. Reject changes that regress
   other operations; revert unsuccessful experiments.
   If a baseline is noisy, do not stop: rerun with more runs, move to another
   target or payload, or fall back to profile/allocation evidence.
6. Require successful `measure(operation: "lint")` (`bundle exec rubocop`) and
   `measure(operation: "test")` (`bundle exec rake`) after the final edit.
   Review the diff for compatibility, security, and accidental generated files.

## Keep output small

The run's step summary is capped at 1 MiB and the run fails if it is exceeded, so
everything you print or write counts. Never cat or echo raw profile JSON or full
benchmark logs. Quote only the relevant excerpts (a few dozen lines at most) in your
reasoning, final messages, and the PR description, and keep any final summary or
`noop` message under about 3,000 characters.

## Publish only a justified change

Recheck the open `performance` PR count immediately before requesting output.
If fewer than three remain open, use only `create-pull-request` to propose at most
one draft PR; the safe output applies the `performance` label. Keep existing PRs
open and leave review and merging to maintainers. Never create issues or comments.

The PR description must include:

- The bottleneck, the change, and why all existing behavior remains compatible.
- Exact reproduction commands/tool arguments, base commit, Ruby and memcached
  versions, YJIT state, payloads, timings, repetitions, and container resource limits.
- A before/after table of measured throughput or latency, variability across runs,
  percentage change, and quantitative profile evidence explaining the improvement.
  Include representative raw output, not just a claim or an inaccessible file path.
- Test/lint results and any remaining limitations, plus a link to this Actions run.

Call `noop` only after the escalation above: all four targets profiled at multiple
payloads, noise handled via repeated A/B runs and profile/allocation evidence, and at
least one concrete candidate tried or rejected with reasons. Also use it if the
change overlaps existing work, compatibility is uncertain, or the PR budget is
exhausted. A noisy benchmark on one target is never sufficient reason. The `noop`
message must list: targets and payloads measured, observed run-to-run variance, the
top profile hotspots, and the candidate ideas considered and why each was rejected.
If tooling, dependencies, or validation are unavailable or fail,
do not request a PR; report the incomplete investigation instead.
