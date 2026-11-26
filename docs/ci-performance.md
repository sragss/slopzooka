# CI timing audit

## Baseline

Measured on November 26, 2026 from GitHub Actions records for `sragss/slopzooka`.
The sample takes the latest 12 successful runs per workflow and event from the
most recent 100 repository runs, spanning November 13–26. Wall time is workflow
creation to completion, queue time is creation to job start, and job and step
times come from their own timestamps. Failures and cancellations were inspected
separately because they can omit part of the workload. The sample covers the
two workflows at the audited worktree's base commit (`5665347`).
[Companion PR](https://github.com/sragss/slopzooka/actions/runs/45845510648) ·
[Simulator PR](https://github.com/sragss/slopzooka/actions/runs/45845510817) ·
[Queued main push](https://github.com/sragss/slopzooka/actions/runs/45847383532)

| Workflow and event | Median wall | p90 wall (nearest rank) | Median job | Median / max queue |
| --- | ---: | ---: | ---: | ---: |
| Companion PR | 6m 30s | 12m 41s | 6m 19s | 4s / 10m 01s |
| Companion push | 6m 07s | 7m 10s | 6m 02s | 4s / 7m 26s |
| visionOS PR | 2m 45s | 3m 29s | 2m 35s | 4s / 59s |
| visionOS push | 2m 41s | 6m 04s | 2m 37s | 4s / 2m 46s |

| Serial steps on successful PRs | Median |
| --- | ---: |
| Companion runner setup, checkout, pnpm setup, Node setup with cache, frozen install | 2s / 2s / 2s / 6.5s / 4s |
| SwiftLint download and checksum | 1s |
| Both linters, type check, format check | 20s / 8s / 3s |
| Companion integration tests | 82s |
| Swift state and native media tests | 94s |
| WebKit keyboard tests | 63s |
| Standalone browser rebuild and tracked asset diff | 1s / 0s |
| Signed Mac package build and smoke test | 46s / 31s |
| SlopZooka simulator and Voice Playground simulator | 95s / 44s |

The baseline had one serial job per workflow, no matrix, and no artifact
transfer between jobs. The 57 MB macOS arm64 pnpm cache hit on sampled logs.
Frozen install still links dependencies and applies the node-pty permission fix.
SwiftLint setup is cheap enough to keep the checksum-verified download.
Packaging regenerates the browser assets and stages production dependencies, two
native helpers and an embedded Node runtime. The package smoke test consumes
that same signed bundle locally. The integration and keyboard suites exercise
different WebKit behavior. The state executable compiles native
test modules, while the simulator workflow compiles the shipping app and the
Voice Playground target. Recent failures included Codex integration assertions,
which remain covered. [Cache and successful job log](https://github.com/sragss/slopzooka/actions/runs/45845510648/job/139997998254) ·
[Failed integration job](https://github.com/sragss/slopzooka/actions/runs/45845663565/job/139998521884)

Connection Lab checks landed on main during the audit. The first successful
PR run took 1m 59s, including 19s of queue, 14s of Swift state checks, and 75s
of simulator build. Its path-filtered macOS job also competes for runner slots.
The paired estimates below cover Companion and visionOS only.
[Connection Lab PR run](https://github.com/sragss/slopzooka/actions/runs/45849368880)

## Changes and projected completion times

Companion uses at most two macOS slots per run. One job runs integration
and WebKit keyboard. The other runs Swift lint and state, then builds and
smoke-tests the signed Mac app. The package job checks the browser asset diff
immediately after the build that regenerated the assets. Linux runs
TypeScript lint, type checking, and formatting. The `companion` aggregate
requires all three jobs to succeed. Both workflows key push runs by run ID,
so each push remains eligible for verification. New PR revisions supersede old
ones. The visionOS path filters include the media and transport packages that
the project compiles.

On this Apple Silicon Mac with Xcode 26.3, compiling each Swift state test
module in one pass reduced a complete suite run from 50.5s to 38.7s (23%).
Both runs passed the same checks. The test build still uses Swift's default
`-Onone` optimization level.

| Successful run cohort | Measured median | Enough immediate Mac slots | One Mac slot fewer |
| --- | ---: | ---: | ---: |
| Companion PR workflow (12) | 6m 30s | ~3m 12s with two slots | ~5m 59s with one |
| Companion push workflow (12) | 6m 07s | ~3m 08s with two slots | ~5m 46s with one |
| PRs with both workflows (9 paired runs) | 6m 34s | ~3m 10s with three slots | ~5m 05s–5m 29s with two |
| Pushes with both workflows (9 paired runs) | 6m 38s | ~3m 23s with three slots | ~5m 35s–5m 53s with two |

The replay reassigns each run's measured steps to jobs and reuses its macOS
setup and teardown for each job. It includes 5s for initial queueing, 8s for
the Linux aggregate, up to 45s for Linux source checks, and 8s for Swift
lint. Only the state step takes the measured local compiler gain. The PR
job medians are 2m 41s for integration and keyboard and 2m 59s for native
checks and packaging. The two-slot mixed ranges compare the best and worst
order of the three macOS jobs on each paired run. A waiting job starts in
the model as soon as a slot frees up. Other workflows and
revisions can delay any slot further.

In the baseline, the single Companion Mac job started within 10s in 20 of
24 successful runs. The other four waited 84s, 370s, 446s, and 601s. Those
records establish time to acquire the first slot. Four Mac jobs from this
repository overlapped at 15:05 UTC on November 26. The job timestamps do
not identify idle capacity or the reason for a wait.
In the replay, a 60s delay on the longer Companion job raises the PR median
from 3m 12s to 4m 12s. Median total Companion Mac time falls from 6m 19s to
~5m 46s on PRs. Two slots per run, or three with visionOS, leave room for
other work under the five-slot macOS limit on most plans. A revision that
also triggers Connection Lab can reach four slots. [GitHub Actions limits](https://docs.github.com/en/actions/reference/limits)

The earlier four-job proposal modeled 1m 56s with all four slots immediately
available. Replaying that proposal with two slots gives 3m 24s–3m 33s,
depending on start order. With one slot it gives 6m 32s. The two-job layout
reuses setup within each job and reduces Mac time under contention.

## Next investments

1. **Measure runner contention after rollout.** Compare like-for-like PR and push
   samples, starting with the same commands below. Track per-job queue, total Mac
   time, p90 wall time, and obsolete PR cancellations. If the second Mac job
   often waits most of a job's duration, benchmark a single Mac job with one
   setup and isolated concurrent steps. Test CPU contention and native fixture
   reliability before adopting it. The visionOS builds stay together on one Mac.
2. **Add dedicated capacity if sustained queueing warrants it.** A quota
   increase or dedicated runner fleet needs account permissions or GitHub
   Support. For a public repository, use isolated ephemeral runners for
   untrusted PR code. Keep repository secrets outside those jobs.
3. **Profile the remaining integration, simulator, and package jobs.** The package
   must still verify signing and run smoke checks against the same bundle. A 4×
   median on mixed PRs calls for completion in ~99s, about the current simulator
   compile alone. Benchmark a faster Mac runner or a compiler cache against cold
   builds before adopting it. Compare restore/save time and key it by runner
   architecture, Xcode and SDK versions, configuration, and build inputs.
   Separate package build and smoke jobs would add a runner and a signed-bundle
   transfer, including file permissions and symlinks. Measure before introducing
   that handoff or expanding dependency caching.

No branch protection or ruleset status requirements were returned for main.
If protection is enabled later, the `companion` job is the aggregate that
covers all companion work. Hosted Linux execution, queue behavior, and timings
need confirmation after publishing the workflow changes.

### Collect another sample

```sh
gh run list -R sragss/slopzooka --limit 100 \
  --json databaseId,workflowName,event,headSha,conclusion,createdAt,updatedAt
gh api "repos/sragss/slopzooka/actions/runs/${run_id}/jobs?per_page=100"
gh api "repos/sragss/slopzooka/actions/runs/${run_id}/artifacts"
gh api "repos/sragss/slopzooka/actions/caches?per_page=20"
```
