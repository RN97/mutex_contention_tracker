# Mutex Contention Tracker

DTrace-based tool for tracking kernel mutex contention across lock acquisition, hold, and release phases. Identifies mutexes with wait times exceeding a configurable threshold and provides detailed timing breakdowns with kernel and user-space stack traces.

## Requirements

- Linux or Unix-like system with DTrace support (Solaris, macOS, or a Linux distribution with `dtrace4linux`)
- Root/sudo privileges (required for kernel tracing)

## Setup

Ensure the scripts have executable permissions before running:

```bash
chmod +x mutex_contention.sh mutex_scanner.d
```

## Usage

```bash
./mutex_contention.sh RUN_TIME_SECONDS [THRESHOLD_MS]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `RUN_TIME_SECONDS` | Yes | — | Duration to monitor in seconds |
| `THRESHOLD_MS` | No | 10 | Lock acquire/hold time threshold in milliseconds |

### Example

```bash
# Monitor for 120 seconds, flag any lock acquisition taking longer than 5ms
./mutex_contention.sh 120 5
```

## Output

Results are written to `/tmp/mutex_contention/` by default. Override the location by exporting `OUTPUT_DIR` before invoking the wrapper (useful when `/tmp` is small or you want results on persistent storage):

```bash
OUTPUT_DIR=/var/log/mutex_contention ./mutex_contention.sh 60 5
```

Each run produces:

- **mutex_scanner_<timestamp>.log** — All contention events with timing and stack traces for a single run; DTrace stdout and stderr are both captured here so warnings and drop counts are archived alongside the events
- **mutex_scanner_all.log** — Symlink to the most recent run's log
- **shell_script.log** — Execution timestamps and status (appended across runs)

### What gets reported

For each mutex event exceeding the threshold:

- Process name, PID, and mutex address
- **lock_acquire_time** — Time spent waiting to acquire the lock
- **critical_section_time** — Time the lock was held
- **mutex_release_time** — Time spent releasing the lock
- Kernel stack trace (`stack()`) and user-space stack trace (`ustack()`)
- Number of concurrent waiters on the mutex

At the end of the run, quantized histograms (in microseconds) summarize the distribution of lock stall, critical section, and unlock stall times. A diagnostic line also reports any DTrace errors and detected dynvar drops for the run (see `KNOWN_LIMITATIONS.txt` for context).

## Testing

The `test/` directory ships a kernel module that exercises all DTrace probe paths via 13 scenarios (basic contention, thundering herd, nested mutexes, high-thread-count, rapid burst, etc.) and an automated validator.

```bash
# 1. Start the monitor (in one terminal, from the project root)
./mutex_contention.sh 120 10

# 2. Build and load the test module (in another terminal)
cd test/
make                                     # if your kernel needs a newer gcc, see test/Makefile
sudo insmod mutex_test_kmod.ko           # runs all 13 scenarios sequentially
sudo rmmod mutex_test_kmod               # unload after dmesg shows completion

# 3. Validate the DTrace output
./validate_dtrace_output.sh              # PASS/FAIL per scenario, exit 0 = all pass
```

Sample logs are checked in for offline validation:

```bash
./validate_dtrace_output.sh sample_output.log    10    # S1-S7
./validate_dtrace_output.sh sample_output_2.log  10    # all 13 scenarios
```

See `test/TEST_INSTRUCTIONS.txt` for the full scenario catalog and module parameters.

## Files

| File | Description |
|------|-------------|
| `mutex_contention.sh` | Shell wrapper — argument validation, output directory setup, DTrace invocation |
| `mutex_scanner.d` | DTrace script — instruments `mutex_lock` and `mutex_unlock` kernel probes |
| `KNOWN_LIMITATIONS.txt` | DTrace edge cases (dynvar drops, thread-exit leaks) and mitigations |
| `test/mutex_test_kmod.c` | Linux kernel module — 13 mutex contention test scenarios |
| `test/Makefile` | Out-of-tree kernel module build |
| `test/validate_dtrace_output.sh` | Parses DTrace log and asserts expected per-scenario behavior |
| `test/TEST_INSTRUCTIONS.txt` | Full instructions for building and running the test module |
| `test/sample_output.log` | Sample DTrace output covering scenarios S1–S7 |
| `test/sample_output_2.log` | Sample DTrace output covering all 13 scenarios |
