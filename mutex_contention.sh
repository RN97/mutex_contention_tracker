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
#   /tmp/mutex_contention/mutex_scanner_<timestamp>.log  - DTrace events for this run
#   /tmp/mutex_contention/mutex_scanner_all.log          - symlink to most recent run
#   /tmp/mutex_contention/shell_script.log               - script execution timestamps

# Resolve this script's own directory so it can be invoked from anywhere
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="/tmp/mutex_contention"
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

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Timestamped log file so successive runs do not clobber prior results
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_LOG="$OUTPUT_DIR/mutex_scanner_${TIMESTAMP}.log"
LATEST_LINK="$OUTPUT_DIR/mutex_scanner_all.log"

# Log start time and parameters
echo "$0: $(date): Tracking mutex contention (lock_acquire > ${THRESHOLD_MS:-10}ms) for ${RUN_TIME}s -> $RUN_LOG" >> "$OUTPUT_DIR/shell_script.log" 2>&1

# Run the DTrace scanner — requires root privileges for kernel probes
sudo "$SCRIPT_DIR/mutex_scanner.d" "${RUN_TIME}" "${THRESHOLD_MS:-10}" > "$RUN_LOG"

# Update the "latest run" symlink atomically
ln -sfn "$RUN_LOG" "$LATEST_LINK"

# If the script itself was invoked under sudo, hand outputs back to the
# real user so they can be read/cleaned without further privilege.
# (When invoked as a normal user, redirections already create files
# under that user, so SUDO_USER is unset and this block is a no-op.)
if [[ -n "$SUDO_USER" ]]; then
  chown -h "$SUDO_USER" "$OUTPUT_DIR" "$RUN_LOG" "$LATEST_LINK" \
                       "$OUTPUT_DIR/shell_script.log" 2>/dev/null || true
fi

# Log completion
echo "$0: $(date): Completed log collection ${RUN_TIME}"
echo "$0: $(date): Completed log collection ${RUN_TIME}" >> "$OUTPUT_DIR/shell_script.log" 2>&1
