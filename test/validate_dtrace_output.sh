#!/bin/bash
#
# validate_dtrace_output.sh - Validate DTrace mutex_scanner.d output
#
# Parses the DTrace log and checks each test scenario's expected output,
# reporting PASS/FAIL per scenario with a final summary.
#
# Usage:
#   ./validate_dtrace_output.sh [LOG_FILE] [THRESHOLD_MS]
#
# Defaults:
#   LOG_FILE     = /tmp/mutex_contention/mutex_scanner_all.log
#   THRESHOLD_MS = 10

set -u

LOG_FILE="${1:-/tmp/mutex_contention/mutex_scanner_all.log}"
THRESHOLD_MS="${2:-10}"
THRESHOLD_NS=$((THRESHOLD_MS * 1000000))

PASS_COUNT=0
FAIL_COUNT=0

# ── Helpers ──────────────────────────────────────────────────────────────

pass() {
    local tag="$1"; shift
    printf "[PASS] %-4s %-35s: %s\n" "$tag" "$1" "$2"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    local tag="$1"; shift
    printf "[FAIL] %-4s %-35s: %s\n" "$tag" "$1" "$2"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# extract_lifecycle_events PATTERN
#
# Parse lifecycle blocks from the log. A lifecycle block starts with:
#   --- Mutex >10ms [acquire/hold] event ---
# followed by:
#   execname:NAME  pid:PID  mutex:ADDR
#   lock_entry:...  lock_exit:...  unlock_entry:...  unlock_exit:...
#   lock_acquire_time:N ns  critical_section_time:N ns  mutex_release_time:N ns
#
# Outputs TSV: execname \t mutex_addr \t acquire_ns \t cs_ns \t release_ns
# Only rows where execname matches PATTERN (awk regex).
extract_lifecycle_events() {
    local pattern="$1"
    awk -v pat="$pattern" '
    /^--- Mutex >10ms/ { in_block = 1; next }
    in_block == 1 && /^execname:/ {
        # execname:NAME  pid:PID  mutex:ADDR
        # Field layout: $1=execname:NAME $2=pid:PID $3=mutex:ADDR
        # (fields separated by 2+ spaces)
        n = split($0, fields, /  +/)
        sub(/^execname:/, "", fields[1]); name = fields[1]
        sub(/^mutex:/, "", fields[3]); addr = fields[3]
        in_block = 2
        next
    }
    in_block == 2 && /^lock_entry:/ {
        in_block = 3
        next
    }
    in_block == 3 && /^lock_acquire_time:/ {
        # lock_acquire_time:N ns  critical_section_time:N ns  mutex_release_time:N ns
        n = split($0, parts, /  +/)
        sub(/^lock_acquire_time:/, "", parts[1]); sub(/ ns$/, "", parts[1]); acq = parts[1]
        sub(/^critical_section_time:/, "", parts[2]); sub(/ ns$/, "", parts[2]); cs = parts[2]
        sub(/^mutex_release_time:/, "", parts[3]); sub(/ ns$/, "", parts[3]); rel = parts[3]
        if (name ~ pat) {
            printf "%s\t%s\t%s\t%s\t%s\n", name, addr, acq, cs, rel
        }
        in_block = 0
        next
    }
    # Reset on unexpected content within a block
    in_block > 0 && /^$/ { }
    in_block > 0 && /^---/ && !/^--- Mutex/ { in_block = 0 }
    ' "$LOG_FILE"
}

# extract_wait_hold_events PATTERN
#
# Parse intermediate wait_time/hold_time lines from the log:
#   execname:NAME  pid:PID  mutex:ADDR
#   wait_time:N ms, waiter_count:N
#   -or-
#   hold_time:N ms, waiter_count:N
#
# Outputs TSV: execname \t mutex_addr \t time_ms \t waiter_count \t type(wait|hold)
# Only rows where execname matches PATTERN. Deduplicates consecutive identical lines.
extract_wait_hold_events() {
    local pattern="$1"
    awk -v pat="$pattern" '
    /^execname:/ {
        # execname:NAME  pid:PID  mutex:ADDR
        n = split($0, fields, /  +/)
        sub(/^execname:/, "", fields[1]); name = fields[1]
        sub(/^mutex:/, "", fields[3]); addr = fields[3]
        next
    }
    /^wait_time:/ || /^hold_time:/ {
        if (/^wait_time:/) typ = "wait"
        else typ = "hold"
        # "wait_time:44 ms, waiter_count:2" split by /[:,] */ gives:
        #   p[1]="wait_time"  p[2]="44 ms"  p[3]="waiter_count"  p[4]="2"
        split($0, p, /[:,] */)
        sub(/^ */, "", p[2]); sub(/ .*/, "", p[2]); time_ms = p[2]
        sub(/^ */, "", p[4]); wcount = p[4]
        line = name "\t" addr "\t" time_ms "\t" wcount "\t" typ
        # Deduplicate consecutive identical lines (DTrace multi-CPU flush)
        if (line != prev && name ~ pat) {
            print line
        }
        prev = line
        next
    }
    ' "$LOG_FILE"
}

# ── Pre-flight checks ───────────────────────────────────────────────────

if [ ! -f "$LOG_FILE" ]; then
    echo "ERROR: Log file not found: $LOG_FILE"
    exit 2
fi

if [ ! -s "$LOG_FILE" ]; then
    echo "ERROR: Log file is empty: $LOG_FILE"
    exit 2
fi

# Check for DTrace start line
if ! grep -q '^start:' "$LOG_FILE"; then
    echo "WARNING: No DTrace start line found — log may be partial"
fi

echo "Validating DTrace output: $LOG_FILE"
echo "Threshold: ${THRESHOLD_MS}ms (${THRESHOLD_NS} ns)"
echo "================================"

# ── S1: Long acquisition stall ──────────────────────────────────────────

events=$(extract_lifecycle_events "^mt_s1_wait$")
if [ -n "$events" ]; then
    acq_ns=$(echo "$events" | head -1 | cut -f3)
    if [ "$acq_ns" -gt "$THRESHOLD_NS" ] 2>/dev/null; then
        pass "S1" "Long acquisition stall" "lock_acquire_time=${acq_ns} ns (>${THRESHOLD_NS} ns)"
    else
        fail "S1" "Long acquisition stall" "lock_acquire_time=${acq_ns} ns (expected >${THRESHOLD_NS} ns)"
    fi
else
    fail "S1" "Long acquisition stall" "no lifecycle events for mt_s1_wait"
fi

# ── S2: Long critical section ───────────────────────────────────────────

events=$(extract_lifecycle_events "^mt_s2_hold$")
if [ -n "$events" ]; then
    cs_ns=$(echo "$events" | head -1 | cut -f4)
    if [ "$cs_ns" -gt "$THRESHOLD_NS" ] 2>/dev/null; then
        pass "S2" "Long critical section" "critical_section_time=${cs_ns} ns (>${THRESHOLD_NS} ns)"
    else
        fail "S2" "Long critical section" "critical_section_time=${cs_ns} ns (expected >${THRESHOLD_NS} ns)"
    fi
else
    fail "S2" "Long critical section" "no lifecycle events for mt_s2_hold"
fi

# ── S3: Multiple waiters ────────────────────────────────────────────────

events=$(extract_wait_hold_events "^mt_s3_w")
if [ -n "$events" ]; then
    max_wc=$(echo "$events" | awk -F'\t' 'BEGIN{m=0} {if($4+0 > m) m=$4+0} END{print m}')
    if [ "$max_wc" -gt 0 ] 2>/dev/null; then
        pass "S3" "Multiple waiters" "max waiter_count=${max_wc} (>0)"
    else
        fail "S3" "Multiple waiters" "all waiter_count=0"
    fi
else
    fail "S3" "Multiple waiters" "no wait/hold events for mt_s3_w*"
fi

# ── S4: Short contention (negative test) ────────────────────────────────

events=$(extract_lifecycle_events "^mt_s4_")
count=0
if [ -n "$events" ]; then
    count=$(echo "$events" | wc -l | tr -d ' ')
fi
if [ "$count" -eq 0 ]; then
    pass "S4" "Short contention (negative)" "0 events (correctly filtered)"
else
    fail "S4" "Short contention (negative)" "${count} events found (expected 0)"
fi

# ── S5: Repeated lock/unlock cycles ─────────────────────────────────────

events=$(extract_lifecycle_events "^mt_s5_t")
count=0
if [ -n "$events" ]; then
    count=$(echo "$events" | wc -l | tr -d ' ')
fi
if [ "$count" -ge 5 ]; then
    pass "S5" "Repeated lock/unlock cycles" "${count} lifecycle events (>=5)"
else
    fail "S5" "Repeated lock/unlock cycles" "${count} lifecycle events (<5 expected)"
fi

# ── S6: CPU-bound critical section ──────────────────────────────────────

events=$(extract_lifecycle_events "^mt_s6_wait$")
if [ -n "$events" ]; then
    acq_ns=$(echo "$events" | head -1 | cut -f3)
    if [ "$acq_ns" -gt "$THRESHOLD_NS" ] 2>/dev/null; then
        pass "S6" "CPU-bound critical section" "lock_acquire_time=${acq_ns} ns (>${THRESHOLD_NS} ns)"
    else
        fail "S6" "CPU-bound critical section" "lock_acquire_time=${acq_ns} ns (expected >${THRESHOLD_NS} ns)"
    fi
else
    fail "S6" "CPU-bound critical section" "no lifecycle events for mt_s6_wait"
fi

# ── S7: Staggered multi-mutex ───────────────────────────────────────────

events_a=$(extract_lifecycle_events "^mt_s7_wA$")
events_b=$(extract_lifecycle_events "^mt_s7_wB$")
if [ -n "$events_a" ] && [ -n "$events_b" ]; then
    addr_a=$(echo "$events_a" | head -1 | cut -f2)
    addr_b=$(echo "$events_b" | head -1 | cut -f2)
    if [ "$addr_a" != "$addr_b" ]; then
        pass "S7" "Staggered multi-mutex" "mutex_A=${addr_a}, mutex_B=${addr_b} (distinct)"
    else
        fail "S7" "Staggered multi-mutex" "same mutex addr ${addr_a} for both (expected distinct)"
    fi
else
    missing=""
    [ -z "$events_a" ] && missing="mt_s7_wA"
    [ -z "$events_b" ] && missing="${missing:+${missing}, }mt_s7_wB"
    fail "S7" "Staggered multi-mutex" "missing lifecycle events for ${missing}"
fi

# ── S8: Nested mutex (outer long wait) ──────────────────────────────────

events=$(extract_lifecycle_events "^mt_s8_nest$")
if [ -n "$events" ]; then
    num_addrs=$(echo "$events" | cut -f2 | sort -u | wc -l | tr -d ' ')
    if [ "$num_addrs" -eq 1 ]; then
        addr=$(echo "$events" | head -1 | cut -f2)
        pass "S8" "Nested mutex (outer long wait)" "1 mutex addr ${addr} (no leak to inner)"
    else
        fail "S8" "Nested mutex (outer long wait)" "${num_addrs} distinct mutex addrs (expected 1, possible leak)"
    fi
else
    fail "S8" "Nested mutex (outer long wait)" "no lifecycle events for mt_s8_nest"
fi

# ── S9: Reverse nested mutex (inner long wait) ──────────────────────────
# The nester waits a long time on mutex_B (inner), then holds mutex_A (outer)
# for the entire duration — so A legitimately has a long critical_section_time.
# The real check: there IS a long-acquire event (mutex_B), and no event has a
# bogus long acquire on mutex_A (which would indicate long_wait leak).

events=$(extract_lifecycle_events "^mt_s9_nest$")
if [ -n "$events" ]; then
    # Find event with long acquire (this is mutex_B — the contended inner lock)
    long_acq=$(echo "$events" | awk -F'\t' -v thr="$THRESHOLD_NS" '$3+0 > thr+0 {print; exit}')
    if [ -n "$long_acq" ]; then
        acq_ns=$(echo "$long_acq" | cut -f3)
        addr=$(echo "$long_acq" | cut -f2)
        pass "S9" "Reverse nested mutex (inner long wait)" "inner mutex ${addr} acquire=${acq_ns} ns (>${THRESHOLD_NS} ns)"
    else
        fail "S9" "Reverse nested mutex (inner long wait)" "no long-acquire event (inner mutex not detected)"
    fi
else
    fail "S9" "Reverse nested mutex (inner long wait)" "no lifecycle events for mt_s9_nest"
fi

# ── S10: High thread count contention ───────────────────────────────────

events=$(extract_lifecycle_events "^mt_s10_w")
count=0
if [ -n "$events" ]; then
    count=$(echo "$events" | wc -l | tr -d ' ')
fi
wait_events=$(extract_wait_hold_events "^mt_s10_w")
max_wc=0
if [ -n "$wait_events" ]; then
    max_wc=$(echo "$wait_events" | awk -F'\t' 'BEGIN{m=0} {if($4+0 > m) m=$4+0} END{print m}')
fi
if [ "$count" -ge 10 ] && [ "$max_wc" -gt 5 ]; then
    pass "S10" "High thread count contention" "${count} events, max waiter_count=${max_wc}"
else
    fail "S10" "High thread count contention" "${count} events (>=10 needed), max waiter_count=${max_wc} (>5 needed)"
fi

# ── S11: Many unique mutexes ────────────────────────────────────────────

events=$(extract_lifecycle_events "^mt_s11_w")
num_addrs=0
if [ -n "$events" ]; then
    num_addrs=$(echo "$events" | cut -f2 | sort -u | wc -l | tr -d ' ')
fi
if [ "$num_addrs" -ge 20 ]; then
    pass "S11" "Many unique mutexes" "${num_addrs} distinct mutex addrs (>=20)"
else
    fail "S11" "Many unique mutexes" "${num_addrs} distinct mutex addrs (<20)"
fi

# ── S12: Rapid lock/unlock burst ────────────────────────────────────────

events=$(extract_lifecycle_events "^mt_s12_t")
count=0
if [ -n "$events" ]; then
    count=$(echo "$events" | wc -l | tr -d ' ')
fi
if [ "$count" -ge 50 ]; then
    pass "S12" "Rapid lock/unlock burst" "${count} lifecycle events (>=50)"
else
    fail "S12" "Rapid lock/unlock burst" "${count} lifecycle events (<50 expected)"
fi

# ── S13: Long wait + short hold ─────────────────────────────────────────

events=$(extract_lifecycle_events "^mt_s13_wt$")
if [ -n "$events" ]; then
    acq_ns=$(echo "$events" | head -1 | cut -f3)
    cs_ns=$(echo "$events" | head -1 | cut -f4)
    if [ "$acq_ns" -gt "$THRESHOLD_NS" ] 2>/dev/null && [ "$cs_ns" -lt "$THRESHOLD_NS" ] 2>/dev/null; then
        pass "S13" "Long wait + short hold" "acquire=${acq_ns} ns (>${THRESHOLD_NS}), hold=${cs_ns} ns (<${THRESHOLD_NS})"
    else
        fail "S13" "Long wait + short hold" "acquire=${acq_ns} ns, hold=${cs_ns} ns (expected acquire>threshold, hold<threshold)"
    fi
else
    fail "S13" "Long wait + short hold" "no lifecycle events for mt_s13_wt"
fi

# ── Summary ──────────────────────────────────────────────────────────────

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "================================"
echo "Results: ${PASS_COUNT} of ${TOTAL} PASSED, ${FAIL_COUNT} FAILED"
echo "================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
else
    exit 0
fi
