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
#   DTRACE_BIN  - DTrace executable to use (default: dtrace on PATH, then
#                 /usr/sbin/dtrace).
#   FILTER_EXECNAME - Exact execname to report (default: report all).
#   FILTER_PID      - PID to report (default: report all).
#   FILTER_MUTEX    - Mutex address to report, decimal or 0x-prefixed hex
#                     (default: report all).
#   CAPTURE_STACKS  - 1 to emit stack()/ustack() in text output, 0 to
#                     suppress them (default: 1).
#   OUTPUT_FORMAT   - text, tsv, or json for lifecycle events (default: text).

# Resolve this script's own directory so it can be invoked from anywhere
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="${OUTPUT_DIR:-/tmp/mutex_contention}"
RUN_TIME=$1                 # Duration in seconds
THRESHOLD_MS=$2             # Threshold in ms (defaults to 10 if omitted)
CAPTURE_STACKS="${CAPTURE_STACKS:-1}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}"
FILTER_EXECNAME="${FILTER_EXECNAME:-}"
FILTER_PID="${FILTER_PID:-0}"
FILTER_MUTEX="${FILTER_MUTEX:-0}"

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

# Pre-flight: dtrace binary must be reachable. Resolve the executable once and
# invoke it explicitly so a PATH-installed dtrace is not bypassed by the script
# shebang in mutex_scanner.d.
if [[ -n "${DTRACE_BIN:-}" ]]; then
  if [[ "$DTRACE_BIN" == */* ]]; then
    RESOLVED_DTRACE_BIN="$DTRACE_BIN"
  else
    RESOLVED_DTRACE_BIN="$(command -v "$DTRACE_BIN" 2>/dev/null || true)"
  fi
elif command -v dtrace >/dev/null 2>&1; then
  RESOLVED_DTRACE_BIN="$(command -v dtrace)"
elif [[ -x /usr/sbin/dtrace ]]; then
  RESOLVED_DTRACE_BIN="/usr/sbin/dtrace"
else
  RESOLVED_DTRACE_BIN=""
fi

if [[ -z "$RESOLVED_DTRACE_BIN" || ! -x "$RESOLVED_DTRACE_BIN" ]]; then
  echo "Error: 'dtrace' not found on PATH or at /usr/sbin/dtrace." >&2
  echo "       Install DTrace (e.g., dtrace4linux) or set DTRACE_BIN." >&2
  exit 1
fi

# Validate optional production controls before passing them to the C
# preprocessor. Keep the accepted character set conservative to avoid macro
# injection through -D definitions.
if ! [[ "$CAPTURE_STACKS" =~ ^[01]$ ]]; then
  echo "Error: CAPTURE_STACKS must be 0 or 1 (got: '$CAPTURE_STACKS')" >&2
  exit 1
fi

case "$OUTPUT_FORMAT" in
  text|tsv|json) ;;
  *)
    echo "Error: OUTPUT_FORMAT must be text, tsv, or json (got: '$OUTPUT_FORMAT')" >&2
    exit 1
    ;;
esac

if [[ -n "$FILTER_EXECNAME" ]] && ! [[ "$FILTER_EXECNAME" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
  echo "Error: FILTER_EXECNAME may only contain letters, digits, '_', '.', ':', and '-' (got: '$FILTER_EXECNAME')" >&2
  exit 1
fi

if ! [[ "$FILTER_PID" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "Error: FILTER_PID must be 0 or a positive integer (got: '$FILTER_PID')" >&2
  exit 1
fi

if ! [[ "$FILTER_MUTEX" =~ ^(0|[1-9][0-9]*|0[xX][0-9a-fA-F]+)$ ]]; then
  echo "Error: FILTER_MUTEX must be 0, decimal, or 0x-prefixed hex (got: '$FILTER_MUTEX')" >&2
  exit 1
fi

DTRACE_DEFS=(
  "-DCAPTURE_STACKS=$CAPTURE_STACKS"
  "-DFILTER_PID=$FILTER_PID"
  "-DFILTER_MUTEX=$FILTER_MUTEX"
)

if [[ -n "$FILTER_EXECNAME" ]]; then
  DTRACE_DEFS+=("-DFILTER_EXECNAME_SET=1" "-DFILTER_EXECNAME=\"$FILTER_EXECNAME\"")
else
  DTRACE_DEFS+=("-DFILTER_EXECNAME_SET=0" "-DFILTER_EXECNAME=\"\"")
fi

case "$OUTPUT_FORMAT" in
  text)
    DTRACE_DEFS+=("-DOUTPUT_TEXT=1" "-DOUTPUT_TSV=0" "-DOUTPUT_JSON=0")
    ;;
  tsv)
    DTRACE_DEFS+=("-DOUTPUT_TEXT=0" "-DOUTPUT_TSV=1" "-DOUTPUT_JSON=0")
    ;;
  json)
    DTRACE_DEFS+=("-DOUTPUT_TEXT=0" "-DOUTPUT_TSV=0" "-DOUTPUT_JSON=1")
    ;;
esac

# Pre-flight: confirm the kernel mutex_lock provider is available.
# Listing kernel probes requires root; sudo will cache the credential
# for the main run, so the user only enters their password once.
if ! sudo "$RESOLVED_DTRACE_BIN" -ln ':::mutex_lock:entry' 2>/dev/null | grep -q 'mutex_lock'; then
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
echo "$0: $(date): dtrace=$RESOLVED_DTRACE_BIN output_format=$OUTPUT_FORMAT capture_stacks=$CAPTURE_STACKS filter_execname=${FILTER_EXECNAME:-all} filter_pid=$FILTER_PID filter_mutex=$FILTER_MUTEX" >> "$OUTPUT_DIR/shell_script.log" 2>&1

# Run the DTrace scanner — requires root privileges for kernel probes.
# Capture the exit status so a DTrace failure (probe error, kernel
# mismatch, permission denied) is surfaced rather than swallowed.
# Merge stderr into the log so DTrace warnings, error-probe output,
# and drop counts are archived alongside the events.
sudo "$RESOLVED_DTRACE_BIN" -Cq "${DTRACE_DEFS[@]}" -s "$SCRIPT_DIR/mutex_scanner.d" "${RUN_TIME}" "${THRESHOLD_MS:-10}" > "$RUN_LOG" 2>&1
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
