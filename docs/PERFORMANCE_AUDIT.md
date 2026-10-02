# Runner Menu performance audit

Audit date: 2 October 2026. Scope: local polling, process discovery, diagnostic logs,
view refreshes, startup, subprocesses, and the existing updater and dedicated agent.

Repeated parsing of unchanged listener logs was the main confirmed source of background
CPU work. The changes cache parsed results, process appended bytes, and read live log
tails backwards in small blocks. The audit also found unnecessary dashboard work,
overlapping refreshes, repeated failed version probes, and continuous status animations.
These have been addressed locally and covered by regression tests where practical.

The original app used approximately 8% of one CPU core while monitoring eight real
installations with the menu closed. Its CPU sample pointed to log parsing and timestamp
formatting. The measurements below use synthetic installations so they can be repeated
without GitHub access or controlling real runners. Their CPU percentages are specific
to that larger workload and should not be substituted for the real-folder measurement.

## Changes made

| Area | Finding and resulting behavior |
| --- | --- |
| Listener insights | Polling reread whole logs. A backend-owned actor now reuses unchanged file signatures and assembled results; growing files parse appended bytes after checking small checkpoints. |
| Cache correctness | Rotation, truncation, replacement, POSIX permission changes, and read failures invalidate or retry the relevant file. Incomplete UTF-8 lines remain buffered until complete. Removed sources are pruned. |
| Live log console | Whole-file decoding became backwards reads in 64 KiB blocks, stopping after enough lines. Unchanged results no longer trigger redundant view assignments. |
| Dashboard | Unchanged tails previously repeated timestamp parsing and merging every second. Parsed tails and merged results are cached. Pausing exits the task; resuming creates a new task. |
| Refresh scheduling | Concurrent refresh callers now share one observation and wait for its completion. Cancelled observations do not publish a stale result. Unchanged statuses, insights, and authentication are not republished. |
| Poll interval | Invalid or non-finite settings are normalized to the supported 2–30 second range, with 5 seconds as the non-finite fallback. The polling task exits on cancellation or loss of its store. |
| Version probing | Missing versions previously caused repeated executable launches. Failed reads now wait 60 seconds before another attempt; successful versions remain cached. |
| Process scan | One scan serves the whole observation batch; empty batches skip it. The scan requests executable paths instead of every process's arguments, and parses only exact listener or worker executable names. |
| Runner discovery | Ordinary directories no longer cause a `.runner` configuration read. Configuration is loaded only after the runner scripts are found. Existing depth and exclusion rules remain in place. |
| Worker log lookup | Filename timestamps reuse a formatter; the lookup avoids sorting and metadata reads for every worker log. Finder actions perform the lookup off the main actor. |
| Status animation | Busy and live indicators pulse once instead of continuously. Reduce Motion is still respected, and status text and colours continue to indicate activity. |

## Automated verification

The suite now contains 93 tests across 15 suites, adding 31 tests to the checkout's
original 62. Performance regressions are checked primarily through deterministic work
counts rather than machine-dependent timing thresholds.

| Coverage | Assertions |
| --- | --- |
| Incremental listener reads | Initial read covers the file once; unchanged polls read no content; append reads only new bytes plus checkpoints; cached results match uncached parsing. |
| File changes and failures | Truncation, atomic replacement, in-place rewrite, rewrite during a read, rotation, deletion, permission recovery, and transient read failures. |
| Parsing | Partial UTF-8 characters, stable job identifiers, blank lines, CRLF, job completion and duration, and lossy decoding. |
| Read limits | A 400-line tail from a 64 MiB sparse fixture reads one 64 KiB block; longer lines and block boundaries preserve output; history reads at most 12 rotations. |
| Concurrent reads | Thirty simultaneous callers share the parsed snapshot. Concurrent store refreshes share an observation and return after it finishes. |
| Dashboard cache | Unchanged sources perform no extra tail reads; one changed file causes one read; names, limits, removal, rotation, and failed reads preserve correct output. |
| Process handling | Spaces and Unicode in paths, tabs, invalid PIDs, executable lookalikes, symlink normalization, 10,000 unrelated rows, and one scan per batch. |
| Scheduling | Invalid intervals persist correctly, failed version probes back off, successful versions stay cached, cancelled observations are discarded, and polling does not retain its store across sleeps. |
| Discovery and subprocesses | One hundred ordinary directories cause no configuration reads; both output pipes drain more than 64 KiB without deadlock, and nonzero exits preserve both streams. |

The Release app and bundled agent must also build successfully through `build-app.sh`,
including the bundle's signature verification. Unit tests do not establish visual
correctness, permission approval, or the performance of every expanded view.

## Service benchmarks

The optimized benchmark uses eight runners, four approximately 1 MiB listener logs per
runner, and 33,558,720 total log bytes. Cached and uncached job results are compared for
every runner. Warm timings are medians of nine samples; initial parsing and the append
are single observations. Measurements were collected on macOS 27.0, arm64.

| Operation | Elapsed time | Content bytes read |
| --- | ---: | ---: |
| Initial parsing of all listener logs | 1,818 ms | 33,558,720 |
| Unchanged listener refresh | 6.68 ms | 0 |
| Append a 62-byte job event | 8.49 ms | 574, including checkpoints |
| Tail 400 lines | 2.03 ms | 65,536 |
| Merge eight runners without the dashboard cache | 19.14 ms | Not separately counted |
| Merge eight unchanged runners with the dashboard cache | 10.28 ms | 0 |
| Parse 10,001 process rows | 19.71 ms | Not applicable |
| Find a worker log among 1,000 filenames | 307 ms | No file contents |

Unchanged polling still enumerates and reads file metadata; zero content bytes does not
mean zero filesystem work. Worker lookup remains a relatively expensive user action, so
moving it off the main actor matters. Concurrent work on this Mac caused substantial
wall-time variation across runs. These values describe this run, not universal latency
budgets. The byte-count and call-count assertions are the stable regression protection.

## Native CPU measurements

| Case | Original CPU | Updated CPU | Original sampled RSS | Updated sampled RSS |
| --- | ---: | ---: | ---: | ---: |
| Menu closed | 22.02% | 0.60% | 39.61 MiB | 56.75 MiB |
| Main window requested | 47.71% | 1.13% | 83.78 MiB | 77.31 MiB |

App CPU fell by approximately 97% in both cases on this workload. The closed-menu
resident-memory sample increased by about 17 MiB, while the window sample decreased.
This is a CPU improvement with a memory trade-off in the closed-menu case; it is not a
general claim of reduced memory use. Every final case confirmed eight distinct runner
directories before starting its timed interval. Exact results are retained in
[performance-results.json](performance-results.json).

CPU percentages refer to one core and to the app process itself; they exclude its child
processes and the system compositor. Each case excludes startup and version checks,
then measures CPU-time growth over 30 seconds and samples resident memory every two
seconds. The fixture contains eight sleeping listener executables and one sleeping
worker, so it exercises a busy status without executing a job.

The harness runs separately signed copies with distinct bundle identifiers and
temporary settings. It requires a successful version probe from each of the eight
directories before measurement. The production process scanner must also find all
eight listeners and the one busy runner. The window case requests the existing main
window development affordance; it is not a visual UI acceptance test or a measurement
of all expanded cards, the dashboard, or every log tab.

The original saved app identifies source `22fd1991`; the updated app is a local dirty
build based on `ceac9087`. The two builds also contain other differences predating this
audit, so the native results do not isolate every change's individual contribution.
A separate intermediate build
already reduced closed-menu CPU to about 0.5% but still used 9–14% with the main window
requested. Changing the continuous pulses provides an additional comparison for that
remaining rendering cost; attribution should be treated as an inference from the
measurements. After the pulse change, the final window case used 1.13% CPU. The
additional animation stack-sampling attempt timed out.

Resident memory is a short-run sample, not a leak assessment. Allocation and caching
can trade memory for CPU, and a lower CPU result does not establish lower memory use
in every case.

## Remaining findings and coverage gaps

| Priority | Finding | Follow-up |
| --- | --- | --- |
| P2 | `Shell.run` has no timeout or cancellation of its child. A stalled `gh`, `ps`, or version probe can hold the shared refresh open indefinitely. | Add bounded execution for read-only observation commands, with cancellation and pipe-drain tests. Preserve the distinct requirements of long-running lifecycle commands. |
| P2 | Startup loads runner configuration synchronously on the main actor. The rebuilt app's real Documents-folder launch waited for renewed macOS permission. | Move startup reads off the main actor and expose loading or permission status. Repeat the real-folder CPU measurement after access is available. CPU readings from the blocked launch were excluded. |
| P2 | First parsing and cache rebuilding still scale with retained log contents. Retained events, job history, and a newline-free pending line have no hard byte cap. | Measure larger histories and establish explicit memory and first-load budgets before adding a retention policy. The 12-file limit does not bound file sizes. |
| P2 | Discovery caps depth but has no budget for the number of visited directories. A wide directory tree can still be expensive. | Add a traversal budget and cancellation, including wide-tree tests. The agent's 200-result cap bounds results, not all traversal work. |
| P3 | Log caches assume ordinary append or rotation behavior. A rewrite that restores the same metadata, or changes only the middle while growing and preserving both checkpoints, can escape detection. | Document append-only expectations; add stronger verification if edited logs must be supported. Full hashing on every poll would reintroduce the cost removed here. |
| Coverage | Expanded job rows have one-second relative-time updates; log consoles still perform bounded reads every two seconds. | Profile expanded cards, dashboard live/paused, all console sources, and Reduce Motion with representative job counts. |
| Coverage | Long-run memory, energy, wakeups, slow storage, Intel Macs, minimum-supported macOS, and a signed dedicated-agent session were not profiled. | Run a longer controlled soak and dedicated-account performance checks. Existing agent security and discovery tests remain functional coverage. |

The updater already streams hashing in 1 MiB blocks, and worker run-link extraction
reads at most 300,000 bytes. Neither was a confirmed source of the idle CPU problem.
No real runner was started, stopped, registered, or updated by these performance tests.

## Repeating the audit

Run unit tests and service benchmarks:

```bash
./run-tests.sh
./run-performance-benchmarks.sh
```

For native measurements, retain the synthetic fixtures and use the `fixture_root`
printed in the benchmark JSON:

```bash
./build-app.sh
./run-performance-benchmarks.sh --keep-fixtures > build/performance/benchmarks.json
python3 scripts/check-native-performance.py \
  --app build/RunnerMenu.app \
  --baseline /path/to/saved/RunnerMenu.app \
  --fixtures /path/from/fixture_root \
  --process-probe build/performance/benchmark-performance \
  --output build/performance/native-results.json \
  --seconds 30
```

The native harness refuses a fixture directory without the benchmark's marker. It
creates fake executables only inside that marked synthetic workload, uses a fake `gh`,
and closes its app copies and sleeping processes afterwards. Optional
`--sample-directory build/performance/stacks` collects window stack samples after the
timed interval; a failed optional sample is recorded separately from the CPU result.
Remove the retained temporary fixtures when finished. Raw build output stays under
ignored `build/performance`; the selected results accompanying this report omit local
fixture paths and private runner information.
