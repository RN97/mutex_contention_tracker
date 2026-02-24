#!/bin/bash
#
# mutex_contention.sh - Wrapper script for the DTrace mutex contention tracker.
#
# Validates arguments, creates the output directory, and invokes the
# mutex_scanner.d DTrace script with elevated privileges. All DTrace
# output is captured to a log file for post-run analysis.
#
# Usage:
#   ./mutex_contention.sh RUN_TIME_SECONDS [THRESHOLD_MS]
#
# Arguments:
#   RUN_TIME_SECONDS  - Duration to monitor (required)
#   THRESHOLD_MS      - Lock acquire/hold threshold in ms (optional, default: 10)
#
# Output:
#   /tmp/mutex_contention/mutex_scanner_all.log  - DTrace contention events
#   /tmp/mutex_contention/shell_script.log       - Script execution timestamps

OUTPUT_DIR="/tmp/mutex_contention"
RUN_TIME=$1                 # Duration in seconds
THRESHOLD_MS=$2             # Threshold in ms (defaults to 10 if omitted)

# Validate required argument
if [[ -z "$RUN_TIME" ]]; then
  echo "Usage: $0 RUN_TIME_SECONDS [THRESHOLD_MS]" >&2
  exit 1
fi

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Log start time and parameters
echo "$0: $(date): Tracking mutex contention (lock_acquire > ${THRESHOLD_MS:-10}ms) for ${RUN_TIME}s" >> "$OUTPUT_DIR/shell_script.log" 2>&1

# Run the DTrace scanner — requires root privileges for kernel probes
sudo ./mutex_scanner.d "${RUN_TIME}" "${THRESHOLD_MS:-10}" > "$OUTPUT_DIR/mutex_scanner_all.log"

# Log completion
echo "$0: $(date): Completed log collection ${RUN_TIME}"
echo "$0: $(date): Completed log collection ${RUN_TIME}" >> "$OUTPUT_DIR/shell_script.log" 2>&1
