# Mutex Contention Tracker

DTrace-based tool for tracking kernel mutex contention across lock acquisition, hold, and release phases. Identifies mutexes with wait times exceeding a configurable threshold and provides detailed timing breakdowns with kernel and user-space stack traces.

## Requirements

- Linux or Unix-like system with DTrace support (Oracle Linux, Solaris, macOS)
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

Results are written to `/tmp/mutex_contention/`:

- **mutex_scanner_all.log** — All contention events with timing and stack traces
- **shell_script.log** — Execution timestamps and status

### What gets reported

For each mutex event exceeding the threshold:

- Process name, PID, and mutex address
- **lock_acquire_time** — Time spent waiting to acquire the lock
- **critical_section_time** — Time the lock was held
- **mutex_release_time** — Time spent releasing the lock
- Kernel stack trace (`stack()`) and user-space stack trace (`ustack()`)
- Number of concurrent waiters on the mutex

At the end of the run, quantized histograms (in microseconds) summarize the distribution of lock stall, critical section, and unlock stall times.

## Files

| File | Description |
|------|-------------|
| `mutex_contention.sh` | Shell wrapper — argument validation, output directory setup, DTrace invocation |
| `mutex_scanner.d` | DTrace script — instruments `mutex_lock` and `mutex_unlock` kernel probes |
| `test/mutex_test_kmod.c` | Linux kernel module — 7 mutex contention test scenarios |
| `test/Makefile` | Out-of-tree kernel module build |
| `test/TEST_INSTRUCTIONS.txt` | Instructions for building and running the test module |
| `test/sample_output.log` | Sample DTrace output from a test run |
