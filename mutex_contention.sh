#!/bin/bash
#
# mutex_contention.sh - Wrapper script for the DTrace mutex contention tracker.
#
# Validates arguments, creates the output directory, and invokes the
# mutex_scanner.d DTrace script with elevated privileges. All DTrace
# output is captured to a timestamped log file for post-run analysis;
# a `mutex_scanner_all.log` symlink always points at the most recent run.
#
# Usage:
#   ./mutex_contention.sh RUN_TIME_SECONDS [THRESHOLD_MS]
#
# Arguments:
#   RUN_TIME_SECONDS  - Duration to monitor (required, positive integer)
#   THRESHOLD_MS      - Lock acquire/hold threshold in ms (optional, default: 10)
#
# Output:
#   $OUTPUT_DIR/mutex_scanner_<timestamp>.log  - DTrace events for this run
#   $OUTPUT_DIR/mutex_scanner_all.log          - symlink to most recent run
#   $OUTPUT_DIR/shell_script.log               - script execution timestamps
#
# Environment:
#   OUTPUT_DIR  - Directory for log output (default: /tmp/mutex_contention).
#                 Useful when /tmp is small or you want results on persistent
#                 storage. Created if it does not exist.

# Resolve this script's own directory so it can be invoked from anywhere
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="${OUTPUT_DIR:-/tmp/mutex_contention}"
RUN_TIME=$1                 # Duration in seconds
THRESHOLD_MS=$2             # Threshold in ms (defaults to 10 if omitted)

# Validate RUN_TIME: required, positive integer
if [[ -z "$RUN_TIME" ]]; then
  echo "Usage: $0 RUN_TIME_SECONDS [THRESHOLD_MS]" >&2
  exit 1
fi
if ! [[ "$RUN_TIME" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: RUN_TIME_SECONDS must be a positive integer (got: '$RUN_TIME')" >&2
  exit 1
fi

# Validate THRESHOLD_MS if provided: positive integer
if [[ -n "$THRESHOLD_MS" ]] && ! [[ "$THRESHOLD_MS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: THRESHOLD_MS must be a positive integer (got: '$THRESHOLD_MS')" >&2
  exit 1
fi

# Pre-flight: dtrace binary must be reachable
if ! command -v dtrace >/dev/null 2>&1 && [[ ! -x /usr/sbin/dtrace ]]; then
  echo "Error: 'dtrace' not found on PATH or at /usr/sbin/dtrace." >&2
  echo "       Install DTrace (e.g., dtrace4linux) before running this tool." >&2
  exit 1
fi

# Pre-flight: confirm the kernel mutex_lock provider is available.
# Listing kernel probes requires root; sudo will cache the credential
# for the main run, so the user only enters their password once.
if ! sudo dtrace -ln ':::mutex_lock:entry' 2>/dev/null | grep -q 'mutex_lock'; then
  echo "Error: DTrace provider ':::mutex_lock:entry' not found." >&2
  echo "       The kernel may be missing mutex probes, or DTrace is not loaded." >&2
  exit 1
fi

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Timestamped log file so successive runs do not clobber prior results
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_LOG="$OUTPUT_DIR/mutex_scanner_${TIMESTAMP}.log"
LATEST_LINK="$OUTPUT_DIR/mutex_scanner_all.log"

# Log start time and parameters
echo "$0: $(date): Tracking mutex contention (lock_acquire > ${THRESHOLD_MS:-10}ms) for ${RUN_TIME}s -> $RUN_LOG" >> "$OUTPUT_DIR/shell_script.log" 2>&1

# Run the DTrace scanner — requires root privileges for kernel probes.
# Capture the exit status so a DTrace failure (probe error, kernel
# mismatch, permission denied) is surfaced rather than swallowed.
# Merge stderr into the log so DTrace warnings, error-probe output,
# and drop counts are archived alongside the events.
sudo "$SCRIPT_DIR/mutex_scanner.d" "${RUN_TIME}" "${THRESHOLD_MS:-10}" > "$RUN_LOG" 2>&1
DTRACE_RC=$?

# Update the "latest run" symlink atomically (do this even on failure
# so the partial log is still reachable via the canonical path).
ln -sfn "$RUN_LOG" "$LATEST_LINK"

# If the script itself was invoked under sudo, hand outputs back to the
# real user so they can be read/cleaned without further privilege.
# (When invoked as a normal user, redirections already create files
# under that user, so SUDO_USER is unset and this block is a no-op.)
if [[ -n "$SUDO_USER" ]]; then
  chown -h "$SUDO_USER" "$OUTPUT_DIR" "$RUN_LOG" "$LATEST_LINK" \
                       "$OUTPUT_DIR/shell_script.log" 2>/dev/null || true
fi

# Log completion (and surface DTrace failures clearly)
if [[ $DTRACE_RC -ne 0 ]]; then
  echo "$0: $(date): DTrace exited with status $DTRACE_RC. See $RUN_LOG." | tee -a "$OUTPUT_DIR/shell_script.log" >&2
else
  echo "$0: $(date): Completed log collection ${RUN_TIME}" | tee -a "$OUTPUT_DIR/shell_script.log"
fi

exit $DTRACE_RC
