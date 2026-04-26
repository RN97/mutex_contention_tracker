#!/usr/sbin/dtrace -Cqs
/*
 * mutex_scanner.d - DTrace script to track kernel mutex contention.
 *
 * Instruments the four phases of a kernel mutex lifecycle:
 *   1. Lock acquisition  (mutex_lock entry -> return)
 *   2. Critical section   (mutex_lock return -> mutex_unlock entry)
 *   3. Lock release       (mutex_unlock entry -> return)
 *
 * Only events where the lock acquisition time OR critical section hold
 * time exceeds a configurable threshold (in ms) are reported. For each
 * such event, the script outputs:
 *   - Process name, PID, and mutex address
 *   - Nanosecond-precision timestamps for all four phase boundaries
 *   - Kernel stack trace (stack()) and user-space stack trace (ustack())
 *   - Current waiter count on the mutex
 *
 * At the end of the run, three quantized histograms (in microseconds)
 * summarize the distribution of lock stalls, critical sections, and
 * unlock stalls across all reported events.
 *
 * Usage:
 *   sudo ./mutex_scanner.d <run_time_secs> <threshold_ms>
 *
 * Args:
 *   $1 - Run time in seconds
 *   $2 - Threshold in milliseconds (events below this are filtered out)
 */

/* Buffer configuration — sized to handle high-frequency mutex activity */
#pragma D option bufsize=32m
#pragma D option aggsize=32m
#pragma D option dynvarsize=32m

/* Global state */
long run_time;          /* Requested run duration (seconds) */
long prog_run_time;     /* Actual measured run duration (seconds) */

long start_timestamp;   /* Absolute timestamp at script start (ns) */
long end_timestamp;     /* Absolute timestamp at script end (ns) */

long threshold_ms;      /* Threshold in milliseconds (from $2) */
long threshold_ns;      /* Threshold converted to nanoseconds */

/*
 * Global associative array: tracks how many threads are currently
 * waiting to acquire each mutex address. Incremented on mutex_lock
 * entry, decremented on mutex_lock return.
 */
int lock_wait_cnt[long];

/*
 * Diagnostic counters surfaced at END so silent DTrace pathologies
 * (errors and dynvar drops) become visible to the operator instead
 * of disappearing into KNOWN_LIMITATIONS.txt. See that file for the
 * full discussion of when these can fire under normal load.
 */
int dtrace_err_cnt;             /* DTrace ERROR probe firings */
int drop_lock_entry_ts;         /* lock_entry_ts dynvar lost between entry and return */
int drop_lock_exit_ts;          /* lock_exit_ts dynvar lost between return and unlock */

BEGIN
{
	run_time = $1;
	threshold_ms = $2;
	threshold_ns = threshold_ms * 1000000;
	start_timestamp = timestamp;
	printf("start:%ld ns, threshold:%ld ms (%ld ns)\n",
	       start_timestamp, threshold_ms, threshold_ns);
}

/*
 * PROBE: mutex_lock entry
 *
 * Fired when any thread begins attempting to acquire a mutex.
 * Records the mutex address and entry timestamp per-thread,
 * and increments the global waiter count for this mutex.
 */
:::mutex_lock:entry
{
	self->mutex = arg0;
	self->lock_entry_ts[arg0] = timestamp;
	lock_wait_cnt[arg0] += 1;
}

/*
 * PROBE: mutex_lock return (LONG WAIT — above threshold)
 *
 * Fired when a thread successfully acquires the mutex and the
 * acquisition took longer than the threshold. Reports the wait
 * time and kernel stack, and sets the long_wait flag so the
 * subsequent unlock is also tracked for the full lifecycle report.
 */
:::mutex_lock:return
/
	(self->mutex != 0) &&
	(self->lock_entry_ts[self->mutex] != 0) &&
	(this->wait = timestamp - self->lock_entry_ts[self->mutex]) &&
	(this->wait > threshold_ns)
/
{
	self->lock_exit_ts[self->mutex] = timestamp;
	lock_wait_cnt[self->mutex] -= 1;
	self->long_wait[self->mutex] = 1;

	printf("execname:%s  pid:%d  mutex:%p\n",
	       execname, pid, (void *)self->mutex);
	printf("wait_time:%lu ms, waiter_count:%d\n",
	       this->wait / 1000000, lock_wait_cnt[self->mutex]);

	printf("\n--- stack() ---\n");
	stack();

	self->mutex = 0;
}

/*
 * PROBE: mutex_lock return (SHORT WAIT — below threshold)
 *
 * The acquisition was fast enough to be below the threshold.
 * Still record the exit timestamp (needed if the hold time later
 * exceeds the threshold), but do not report anything.
 */
:::mutex_lock:return
/
	(self->mutex != 0) &&
	(self->lock_entry_ts[self->mutex] != 0) &&
	(this->wait = timestamp - self->lock_entry_ts[self->mutex]) &&
	(this->wait <= threshold_ns)
/
{
	self->lock_exit_ts[self->mutex] = timestamp;
	lock_wait_cnt[self->mutex] -= 1;
	self->mutex = 0;
}

/*
 * PROBE: mutex_lock return (DYNVAR DROP — entry timestamp lost)
 *
 * The lock_entry_ts dynvar was silently dropped due to dynvar space
 * exhaustion. Clean up the state that mutex_lock:entry left behind
 * so it does not leak or cause bogus events downstream.
 */
:::mutex_lock:return
/
	(self->mutex != 0) &&
	(self->lock_entry_ts[self->mutex] == 0)
/
{
	lock_wait_cnt[self->mutex] -= 1;
	drop_lock_entry_ts += 1;
	self->mutex = 0;
}

/*
 * PROBE: mutex_unlock entry (LONG HOLD — above threshold)
 *
 * The critical section (time between acquiring and releasing the
 * lock) exceeded the threshold. Report hold time and waiter count.
 */
:::mutex_unlock:entry
/
	(self->lock_exit_ts[arg0] != 0) &&
	(this->hold = timestamp - self->lock_exit_ts[arg0]) &&
	(this->hold > threshold_ns)
/
{
	self->mutex = arg0;
	self->unlock_entry_ts = timestamp;

	printf("execname:%s  pid:%d  mutex:%p\n",
	       execname, pid, (void *)self->mutex);
	printf("hold_time:%lu ms, waiter_count:%d\n",
	       this->hold / 1000000, lock_wait_cnt[self->mutex]);
}

/*
 * PROBE: mutex_unlock entry (SHORT HOLD, but long_wait was set)
 *
 * The hold time is below threshold, but the acquisition was slow
 * (long_wait flag). We still need to track the unlock so the full
 * lifecycle report in mutex_unlock:return can compute all three
 * timing phases.
 */
:::mutex_unlock:entry
/
	(self->lock_exit_ts[arg0] != 0) &&
	(self->long_wait[arg0]) &&
	(this->hold = timestamp - self->lock_exit_ts[arg0]) &&
	(this->hold <= threshold_ns)
/
{
	self->mutex = arg0;
	self->unlock_entry_ts = timestamp;
}

/*
 * PROBE: mutex_unlock entry (SHORT HOLD, no long_wait)
 *
 * Neither the acquisition nor the hold time crossed the threshold.
 * Clean up per-thread state for this mutex — no report needed.
 */
:::mutex_unlock:entry
/
	(self->lock_exit_ts[arg0] != 0) &&
	(self->long_wait[arg0] == 0) &&
	(this->hold = timestamp - self->lock_exit_ts[arg0]) &&
	(this->hold <= threshold_ns)
/
{
	self->lock_entry_ts[arg0] = 0;
	self->lock_exit_ts[arg0] = 0;
}

/*
 * PROBE: mutex_unlock entry (DYNVAR DROP — lock_exit_ts lost)
 *
 * The lock_exit_ts dynvar was dropped in mutex_lock:return due to
 * dynvar space exhaustion. We know the mutex was tracked (lock_entry_ts
 * is set) but the exit timestamp is missing. Clean up the orphaned
 * state to prevent dynvar leaks.
 */
:::mutex_unlock:entry
/
	(self->lock_entry_ts[arg0] != 0) &&
	(self->lock_exit_ts[arg0] == 0)
/
{
	self->lock_entry_ts[arg0] = 0;
	self->long_wait[arg0] = 0;
	drop_lock_exit_ts += 1;
}

/*
 * PROBE: mutex_unlock return (FULL LIFECYCLE REPORT)
 *
 * Fires only when self->mutex is set (meaning either the acquisition
 * or the hold time crossed the threshold). Computes all three timing
 * phases and emits the complete event report with stack traces and
 * histogram aggregation.
 *
 * Timing phases:
 *   acquire = lock_exit - lock_entry   (time waiting for the lock)
 *   cs      = unlock_entry - lock_exit (time holding the lock)
 *   unlock  = unlock_exit - unlock_entry (time releasing the lock)
 */
:::mutex_unlock:return
/ (self->mutex != 0) /
{
	self->unlock_exit_ts = timestamp;

	this->acquire = self->lock_exit_ts[self->mutex] - self->lock_entry_ts[self->mutex];
	this->cs = self->unlock_entry_ts - self->lock_exit_ts[self->mutex];
	this->unlock = self->unlock_exit_ts - self->unlock_entry_ts;

	printf("\n--- Mutex >%ldms [acquire/hold] event ---\n", threshold_ms);
	printf("execname:%s  pid:%d  mutex:%p\n",
	       execname, pid, (void *)self->mutex);
	printf("lock_entry:%lu  lock_exit:%lu  unlock_entry:%lu  unlock_exit:%lu\n",
	       self->lock_entry_ts[self->mutex] - start_timestamp,
	       self->lock_exit_ts[self->mutex] - start_timestamp,
	       self->unlock_entry_ts - start_timestamp,
	       self->unlock_exit_ts - start_timestamp);

	printf("lock_acquire_time:%lu ns  critical_section_time:%lu ns  mutex_release_time:%lu ns\n",
	       this->acquire,
	       this->cs,
	       this->unlock);

	printf("\n--- stack() ---\n");
	stack();
	printf("\n--- ustack() ---\n");
	ustack();
	printf("     --------------------------------------------    \n\n");

	/* Aggregate histograms in microseconds for readability */
	@time1["Mutex lock stall (us)"] = quantize(this->acquire / 1000);
	@time2["Critical section (us)"] = quantize(this->cs / 1000);
	@time3["Mutex unlock stall (us)"] = quantize(this->unlock / 1000);

	/* Reset per-thread state for this mutex */
	self->lock_entry_ts[self->mutex] = 0;
	self->lock_exit_ts[self->mutex] = 0;
	self->unlock_entry_ts = 0;
	self->unlock_exit_ts = 0;
	self->long_wait[self->mutex] = 0;
	self->mutex = 0;
}

/* Exit after requested run time (checked once per second) */
tick-1sec
/ ((timestamp - start_timestamp) / 1000000000) >= run_time /
{
	exit(0);
}

/*
 * PROBE: dtrace ERROR
 *
 * Counts every D-script runtime error (e.g. invalid load, divide-by-zero,
 * predicate exception) so the operator sees a non-zero number at END
 * rather than silently malformed output.
 */
dtrace:::ERROR
{
	dtrace_err_cnt += 1;
}

/* Print summary and histograms on exit */
END
{
	end_timestamp = timestamp;
	prog_run_time = (end_timestamp - start_timestamp) / 1000000000;
	printf("Mutex contention tracking ran for %ld secs, start_time=%ldns end_time=%ldns run_time_given=%ld secs\n",
	       prog_run_time, start_timestamp, end_timestamp, run_time);
	printf("Diagnostics: dtrace_errors=%d  dynvar_drops_lock_entry_ts=%d  dynvar_drops_lock_exit_ts=%d\n",
	       dtrace_err_cnt, drop_lock_entry_ts, drop_lock_exit_ts);
	printf("(Non-zero drops indicate dynvar pressure — see KNOWN_LIMITATIONS.txt; raise dynvarsize if persistent.)\n");
	printa(@time1);
	printa(@time2);
	printa(@time3);
}
