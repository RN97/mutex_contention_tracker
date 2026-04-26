/*
 * mutex_test_kmod.c - Linux kernel module for testing the DTrace
 *                     mutex_scanner.d contention tracker.
 *
 * Spawns kernel threads that create controlled mutex contention
 * scenarios, exercising all probe paths in the DTrace script.
 * Scenarios run sequentially on module load (insmod) with a 200ms
 * gap between each for clean separation in DTrace output.
 *
 * Module parameters:
 *   run_scenario  - Which scenario to run: 0 = all (default), 1-13 = specific
 *   hold_ms       - Base mutex hold time in ms (default: 50). Scenarios
 *                   derive their specific timings from this value.
 *
 * Build:
 *   make              (use a matching compiler if the kernel was built
 *                      with a newer gcc — see Makefile for CC override)
 *
 * Usage:
 *   sudo insmod mutex_test_kmod.ko [run_scenario=N] [hold_ms=N]
 *   sudo rmmod mutex_test_kmod
 *
 * See TEST_INSTRUCTIONS.txt for full details on running with DTrace.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/mutex.h>
#include <linux/delay.h>
#include <linux/slab.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Rohit Nair");
MODULE_DESCRIPTION("Mutex contention test scenarios for DTrace mutex_scanner.d");

static int run_scenario = 0;
module_param(run_scenario, int, 0444);
MODULE_PARM_DESC(run_scenario, "Scenario to run (1-13), 0 = all (default: 0)");

static int hold_ms = 50;
module_param(hold_ms, int, 0444);
MODULE_PARM_DESC(hold_ms, "Default mutex hold time in ms (default: 50)");

/* ========================================================================
 * Scenario 1: Long acquisition stall
 *
 * Tests: lock_acquire_time > threshold
 *
 * Thread A acquires the mutex and sleeps for hold_ms. Thread B attempts
 * to acquire the same mutex 5ms later, blocking for ~hold_ms until
 * Thread A releases. DTrace should report a long lock-acquire event
 * for Thread B.
 * ======================================================================== */

static DEFINE_MUTEX(s1_mutex);
static atomic_t s1_done = ATOMIC_INIT(0);

static int s1_holder(void *data)
{
	mutex_lock(&s1_mutex);
	pr_info("mutex_test: [S1] holder acquired lock, sleeping %dms\n", hold_ms);
	msleep(hold_ms);
	mutex_unlock(&s1_mutex);
	pr_info("mutex_test: [S1] holder released lock\n");
	atomic_inc(&s1_done);
	return 0;
}

static int s1_waiter(void *data)
{
	/* Small delay so the holder grabs the lock first */
	msleep(5);
	pr_info("mutex_test: [S1] waiter attempting lock\n");
	mutex_lock(&s1_mutex);
	pr_info("mutex_test: [S1] waiter acquired lock\n");
	mutex_unlock(&s1_mutex);
	atomic_inc(&s1_done);
	return 0;
}

static int run_scenario_1(void)
{
	struct task_struct *th, *tw;
	int done;

	pr_info("mutex_test: === Scenario 1: Long acquisition stall ===\n");
	atomic_set(&s1_done, 0);
	th = kthread_run(s1_holder, NULL, "mt_s1_hold");
	tw = kthread_run(s1_waiter, NULL, "mt_s1_wait");
	if (IS_ERR(th) || IS_ERR(tw)) {
		pr_err("mutex_test: [S1] failed to create threads\n");
		return 1;
	}
	/* Wait for both threads to finish */
	msleep(hold_ms + 100);
	done = atomic_read(&s1_done);
	if (done == 2)
		pr_info("mutex_test: [S1] PASS: %d/2 threads completed\n", done);
	else
		pr_err("mutex_test: [S1] FAIL: %d/2 threads completed\n", done);
	return done == 2 ? 0 : 1;
}

/* ========================================================================
 * Scenario 2: Long critical section
 *
 * Tests: critical_section_time > threshold
 *
 * Thread A acquires the mutex and holds it for hold_ms*2 (twice the
 * base hold time), simulating extended work inside the critical section.
 * Thread B contends, triggering both a long acquire and a long hold
 * event in DTrace.
 * ======================================================================== */

static DEFINE_MUTEX(s2_mutex);
static atomic_t s2_done = ATOMIC_INIT(0);

static int s2_holder(void *data)
{
	int cs_ms = hold_ms * 2;

	mutex_lock(&s2_mutex);
	pr_info("mutex_test: [S2] holder acquired lock, holding for %dms\n", cs_ms);
	msleep(cs_ms);
	mutex_unlock(&s2_mutex);
	pr_info("mutex_test: [S2] holder released lock\n");
	atomic_inc(&s2_done);
	return 0;
}

static int s2_waiter(void *data)
{
	msleep(5);
	pr_info("mutex_test: [S2] waiter attempting lock\n");
	mutex_lock(&s2_mutex);
	pr_info("mutex_test: [S2] waiter acquired lock\n");
	mutex_unlock(&s2_mutex);
	atomic_inc(&s2_done);
	return 0;
}

static int run_scenario_2(void)
{
	struct task_struct *th, *tw;
	int cs_ms = hold_ms * 2;
	int done;

	pr_info("mutex_test: === Scenario 2: Long critical section (%dms) ===\n", cs_ms);
	atomic_set(&s2_done, 0);
	th = kthread_run(s2_holder, NULL, "mt_s2_hold");
	tw = kthread_run(s2_waiter, NULL, "mt_s2_wait");
	if (IS_ERR(th) || IS_ERR(tw)) {
		pr_err("mutex_test: [S2] failed to create threads\n");
		return 1;
	}
	msleep(cs_ms + 100);
	done = atomic_read(&s2_done);
	if (done == 2)
		pr_info("mutex_test: [S2] PASS: %d/2 threads completed\n", done);
	else
		pr_err("mutex_test: [S2] FAIL: %d/2 threads completed\n", done);
	return done == 2 ? 0 : 1;
}

/* ========================================================================
 * Scenario 3: Multiple waiters (thundering herd)
 *
 * Tests: waiter_count > 1
 *
 * One holder thread sleeps for hold_ms+30ms while 4 waiter threads
 * all attempt to acquire the same mutex simultaneously. DTrace should
 * report waiter_count > 1, showing multiple threads contending on the
 * same lock. Each waiter holds briefly (5ms) after acquiring so the
 * remaining waiters keep contending.
 * ======================================================================== */

#define S3_NUM_WAITERS 4
static DEFINE_MUTEX(s3_mutex);
static atomic_t s3_done = ATOMIC_INIT(0);

static int s3_holder(void *data)
{
	int herd_ms = hold_ms + 30;

	mutex_lock(&s3_mutex);
	pr_info("mutex_test: [S3] holder acquired lock, sleeping %dms\n", herd_ms);
	msleep(herd_ms);
	mutex_unlock(&s3_mutex);
	pr_info("mutex_test: [S3] holder released lock\n");
	atomic_inc(&s3_done);
	return 0;
}

static int s3_waiter(void *data)
{
	int id = (int)(long)data;

	msleep(10);
	pr_info("mutex_test: [S3] waiter-%d attempting lock\n", id);
	mutex_lock(&s3_mutex);
	pr_info("mutex_test: [S3] waiter-%d acquired lock\n", id);
	/* Hold briefly so remaining waiters keep contending */
	msleep(5);
	mutex_unlock(&s3_mutex);
	atomic_inc(&s3_done);
	return 0;
}

static int run_scenario_3(void)
{
	struct task_struct *th;
	int i, done;
	int herd_ms = hold_ms + 30;
	int expected = 1 + S3_NUM_WAITERS;

	pr_info("mutex_test: === Scenario 3: Multiple waiters (%d) ===\n", S3_NUM_WAITERS);
	atomic_set(&s3_done, 0);
	th = kthread_run(s3_holder, NULL, "mt_s3_hold");
	if (IS_ERR(th)) {
		pr_err("mutex_test: [S3] failed to create holder\n");
		return 1;
	}
	for (i = 0; i < S3_NUM_WAITERS; i++) {
		th = kthread_run(s3_waiter, (void *)(long)i, "mt_s3_w%d", i);
		if (IS_ERR(th))
			pr_err("mutex_test: [S3] failed to create waiter-%d\n", i);
	}
	/* Wait: holder hold + each waiter holds 5ms sequentially + margin */
	msleep(herd_ms + (S3_NUM_WAITERS * 10) + 100);
	done = atomic_read(&s3_done);
	if (done == expected)
		pr_info("mutex_test: [S3] PASS: %d/%d threads completed\n", done, expected);
	else
		pr_err("mutex_test: [S3] FAIL: %d/%d threads completed\n", done, expected);
	return done == expected ? 0 : 1;
}

/* ========================================================================
 * Scenario 4: Short contention (below threshold)
 *
 * Tests: DTrace filtering — this scenario should NOT appear in output
 *
 * Holder holds the mutex for only 1ms. With the default 10ms DTrace
 * threshold, the contention is too brief to trigger reporting. Use
 * this as a negative test to verify threshold filtering works.
 * ======================================================================== */

static DEFINE_MUTEX(s4_mutex);
static atomic_t s4_done = ATOMIC_INIT(0);

static int s4_holder(void *data)
{
	mutex_lock(&s4_mutex);
	pr_info("mutex_test: [S4] holder acquired lock, holding 1ms\n");
	msleep(1);
	mutex_unlock(&s4_mutex);
	atomic_inc(&s4_done);
	return 0;
}

static int s4_waiter(void *data)
{
	msleep(1);
	mutex_lock(&s4_mutex);
	pr_info("mutex_test: [S4] waiter acquired lock (should be below threshold)\n");
	mutex_unlock(&s4_mutex);
	atomic_inc(&s4_done);
	return 0;
}

static int run_scenario_4(void)
{
	struct task_struct *th, *tw;
	int done;

	pr_info("mutex_test: === Scenario 4: Short contention (below threshold) ===\n");
	atomic_set(&s4_done, 0);
	th = kthread_run(s4_holder, NULL, "mt_s4_hold");
	tw = kthread_run(s4_waiter, NULL, "mt_s4_wait");
	if (IS_ERR(th) || IS_ERR(tw)) {
		pr_err("mutex_test: [S4] failed to create threads\n");
		return 1;
	}
	msleep(100);
	done = atomic_read(&s4_done);
	if (done == 2)
		pr_info("mutex_test: [S4] PASS: %d/2 threads completed\n", done);
	else
		pr_err("mutex_test: [S4] FAIL: %d/2 threads completed\n", done);
	return done == 2 ? 0 : 1;
}

/* ========================================================================
 * Scenario 5: Repeated lock/unlock cycles
 *
 * Tests: DTrace histogram aggregation across many events
 *
 * Two threads alternate acquiring the same mutex for 20 iterations
 * each, holding 20ms per iteration. DTrace should report many events
 * and the end-of-run histograms should show a clear distribution
 * centered around the ~20ms hold/acquire times.
 * ======================================================================== */

#define S5_ITERATIONS 20
static DEFINE_MUTEX(s5_mutex);
static atomic_t s5_done = ATOMIC_INIT(0);

static int s5_cycler(void *data)
{
	int id = (int)(long)data;
	int i;

	for (i = 0; i < S5_ITERATIONS; i++) {
		mutex_lock(&s5_mutex);
		pr_info("mutex_test: [S5] thread-%d iteration %d, holding 20ms\n", id, i);
		msleep(20);
		mutex_unlock(&s5_mutex);
		/* Yield briefly so the other thread has a chance to contend */
		msleep(1);
	}
	atomic_inc(&s5_done);
	return 0;
}

static int run_scenario_5(void)
{
	struct task_struct *t0, *t1;
	int done;

	pr_info("mutex_test: === Scenario 5: Repeated lock/unlock (%d iterations x 2 threads) ===\n",
		S5_ITERATIONS);
	atomic_set(&s5_done, 0);
	t0 = kthread_run(s5_cycler, (void *)0L, "mt_s5_t0");
	t1 = kthread_run(s5_cycler, (void *)1L, "mt_s5_t1");
	if (IS_ERR(t0) || IS_ERR(t1)) {
		pr_err("mutex_test: [S5] failed to create threads\n");
		return 1;
	}
	/* Worst case: all iterations serialized — (20ms+1ms)*20*2 + margin */
	msleep(S5_ITERATIONS * 2 * 25 + 200);
	done = atomic_read(&s5_done);
	if (done == 2)
		pr_info("mutex_test: [S5] PASS: %d/2 threads completed\n", done);
	else
		pr_err("mutex_test: [S5] FAIL: %d/2 threads completed\n", done);
	return done == 2 ? 0 : 1;
}

/* ========================================================================
 * Scenario 6: CPU-bound critical section (busy-wait)
 *
 * Tests: contention from CPU-bound work (not sleeping)
 *
 * Holder acquires the mutex and busy-loops using udelay() for ~30ms
 * instead of sleeping. A waiter thread contends. This verifies that
 * DTrace probes fire regardless of how time is spent in the critical
 * section (CPU-bound vs sleeping).
 *
 * Note: udelay() max safe value is ~1000us per call, so we loop.
 * ======================================================================== */

static DEFINE_MUTEX(s6_mutex);
static atomic_t s6_done = ATOMIC_INIT(0);

static int s6_busy_holder(void *data)
{
	unsigned long i, loops;

	mutex_lock(&s6_mutex);
	pr_info("mutex_test: [S6] holder acquired lock, busy-waiting ~30ms\n");
	loops = 30;  /* 30 iterations x 1000us = ~30ms */
	for (i = 0; i < loops; i++)
		udelay(1000);
	mutex_unlock(&s6_mutex);
	pr_info("mutex_test: [S6] holder released lock\n");
	atomic_inc(&s6_done);
	return 0;
}

static int s6_waiter(void *data)
{
	msleep(5);
	pr_info("mutex_test: [S6] waiter attempting lock\n");
	mutex_lock(&s6_mutex);
	pr_info("mutex_test: [S6] waiter acquired lock\n");
	mutex_unlock(&s6_mutex);
	atomic_inc(&s6_done);
	return 0;
}

static int run_scenario_6(void)
{
	struct task_struct *th, *tw;
	int done;

	pr_info("mutex_test: === Scenario 6: CPU-bound critical section ===\n");
	atomic_set(&s6_done, 0);
	th = kthread_run(s6_busy_holder, NULL, "mt_s6_hold");
	tw = kthread_run(s6_waiter, NULL, "mt_s6_wait");
	if (IS_ERR(th) || IS_ERR(tw)) {
		pr_err("mutex_test: [S6] failed to create threads\n");
		return 1;
	}
	msleep(200);
	done = atomic_read(&s6_done);
	if (done == 2)
		pr_info("mutex_test: [S6] PASS: %d/2 threads completed\n", done);
	else
		pr_err("mutex_test: [S6] FAIL: %d/2 threads completed\n", done);
	return done == 2 ? 0 : 1;
}

/* ========================================================================
 * Scenario 7: Staggered multi-mutex contention
 *
 * Tests: independent per-mutex tracking with distinct timing profiles
 *
 * Two separate mutexes (A and B) each have a holder+waiter pair
 * running concurrently. Mutex A is held for 40ms, Mutex B for 60ms.
 * DTrace should report two distinct mutex addresses with different
 * timing profiles, verifying that per-mutex state tracking is correct.
 * ======================================================================== */

static DEFINE_MUTEX(s7_mutex_a);
static DEFINE_MUTEX(s7_mutex_b);

static atomic_t s7_done = ATOMIC_INIT(0);

struct s7_args {
	struct mutex *mtx;
	int hold_time;
	const char *name;
};

static int s7_holder(void *data)
{
	struct s7_args *args = data;

	mutex_lock(args->mtx);
	pr_info("mutex_test: [S7] %s holder acquired, holding %dms\n",
		args->name, args->hold_time);
	msleep(args->hold_time);
	mutex_unlock(args->mtx);
	pr_info("mutex_test: [S7] %s holder released\n", args->name);
	atomic_inc(&s7_done);
	return 0;
}

static int s7_waiter(void *data)
{
	struct s7_args *args = data;

	msleep(5);
	pr_info("mutex_test: [S7] %s waiter attempting lock\n", args->name);
	mutex_lock(args->mtx);
	pr_info("mutex_test: [S7] %s waiter acquired lock\n", args->name);
	mutex_unlock(args->mtx);
	atomic_inc(&s7_done);
	return 0;
}

/* Static so they persist for the full thread lifetime */
static struct s7_args s7a_args = { .mtx = &s7_mutex_a, .hold_time = 40, .name = "mutex_A" };
static struct s7_args s7b_args = { .mtx = &s7_mutex_b, .hold_time = 60, .name = "mutex_B" };

static int run_scenario_7(void)
{
	struct task_struct *ha, *wa, *hb, *wb;
	int done;

	pr_info("mutex_test: === Scenario 7: Staggered multi-mutex (A=%dms, B=%dms) ===\n",
		s7a_args.hold_time, s7b_args.hold_time);

	atomic_set(&s7_done, 0);
	ha = kthread_run(s7_holder, &s7a_args, "mt_s7_hA");
	wa = kthread_run(s7_waiter, &s7a_args, "mt_s7_wA");
	hb = kthread_run(s7_holder, &s7b_args, "mt_s7_hB");
	wb = kthread_run(s7_waiter, &s7b_args, "mt_s7_wB");
	if (IS_ERR(ha) || IS_ERR(wa) || IS_ERR(hb) || IS_ERR(wb)) {
		pr_err("mutex_test: [S7] failed to create threads\n");
		return 1;
	}
	msleep(s7b_args.hold_time + 100);
	done = atomic_read(&s7_done);
	if (done == 4)
		pr_info("mutex_test: [S7] PASS: %d/4 threads completed\n", done);
	else
		pr_err("mutex_test: [S7] FAIL: %d/4 threads completed\n", done);
	return done == 4 ? 0 : 1;
}

/* ========================================================================
 * Scenario 8: Nested mutex acquisition (outer long wait)
 *
 * Tests: per-mutex long_wait[addr] isolation (the nested mutex fix)
 *
 * Thread A (holder) acquires mutex_A and holds it for hold_ms.
 * Thread B (nester) waits for mutex_A (long wait), then inside A's
 * critical section acquires mutex_B (uncontended, short wait/hold).
 * DTrace should report:
 *   - mutex_A: long acquisition for Thread B (long_wait[A] set)
 *   - mutex_B: NOT reported (short wait, short hold, no long_wait[B])
 * This verifies long_wait[A] does NOT leak to mutex_B.
 * ======================================================================== */

static DEFINE_MUTEX(s8_mutex_a);
static DEFINE_MUTEX(s8_mutex_b);
static atomic_t s8_done = ATOMIC_INIT(0);

static int s8_holder(void *data)
{
	mutex_lock(&s8_mutex_a);
	pr_info("mutex_test: [S8] holder acquired mutex_A, sleeping %dms\n", hold_ms);
	msleep(hold_ms);
	mutex_unlock(&s8_mutex_a);
	pr_info("mutex_test: [S8] holder released mutex_A\n");
	atomic_inc(&s8_done);
	return 0;
}

static int s8_nester(void *data)
{
	msleep(5);
	pr_info("mutex_test: [S8] nester attempting mutex_A (will block ~%dms)\n", hold_ms);
	mutex_lock(&s8_mutex_a);
	pr_info("mutex_test: [S8] nester acquired mutex_A, now locking mutex_B (uncontended)\n");

	/* Nested lock: B is uncontended so acquire is instant */
	mutex_lock(&s8_mutex_b);
	pr_info("mutex_test: [S8] nester acquired mutex_B inside A's critical section\n");
	msleep(1);  /* Trivial hold */
	mutex_unlock(&s8_mutex_b);
	pr_info("mutex_test: [S8] nester released mutex_B\n");

	mutex_unlock(&s8_mutex_a);
	pr_info("mutex_test: [S8] nester released mutex_A\n");
	atomic_inc(&s8_done);
	return 0;
}

static int run_scenario_8(void)
{
	struct task_struct *th, *tn;
	int done;

	pr_info("mutex_test: === Scenario 8: Nested mutex (outer long wait) ===\n");
	atomic_set(&s8_done, 0);
	th = kthread_run(s8_holder, NULL, "mt_s8_hold");
	tn = kthread_run(s8_nester, NULL, "mt_s8_nest");
	if (IS_ERR(th) || IS_ERR(tn)) {
		pr_err("mutex_test: [S8] failed to create threads\n");
		return 1;
	}
	msleep(hold_ms + 100);
	done = atomic_read(&s8_done);
	if (done == 2)
		pr_info("mutex_test: [S8] PASS: %d/2 threads completed\n", done);
	else
		pr_err("mutex_test: [S8] FAIL: %d/2 threads completed\n", done);
	return done == 2 ? 0 : 1;
}

/* ========================================================================
 * Scenario 9: Reverse nested mutex (inner long wait)
 *
 * Tests: per-mutex long_wait[addr] in reverse nesting order
 *
 * Thread A (nester) acquires mutex_A uncontended, then contends on
 * mutex_B inside A's critical section. Thread B (holder_b) holds
 * mutex_B for hold_ms.
 * DTrace should report:
 *   - mutex_B: long acquisition for nester (long_wait[B] set)
 *   - mutex_A: may appear with long critical_section_time (because
 *     the nester holds A while waiting for B inside), but must NOT
 *     have a long lock_acquire_time (which would indicate leak)
 * This verifies long_wait[B] does NOT leak to mutex_A's acquire path.
 * ======================================================================== */

static DEFINE_MUTEX(s9_mutex_a);
static DEFINE_MUTEX(s9_mutex_b);
static atomic_t s9_done = ATOMIC_INIT(0);

static int s9_holder_b(void *data)
{
	mutex_lock(&s9_mutex_b);
	pr_info("mutex_test: [S9] holder_B acquired mutex_B, sleeping %dms\n", hold_ms);
	msleep(hold_ms);
	mutex_unlock(&s9_mutex_b);
	pr_info("mutex_test: [S9] holder_B released mutex_B\n");
	atomic_inc(&s9_done);
	return 0;
}

static int s9_nester(void *data)
{
	msleep(5);
	/* A is uncontended — instant acquire */
	pr_info("mutex_test: [S9] nester acquiring mutex_A (uncontended)\n");
	mutex_lock(&s9_mutex_a);
	pr_info("mutex_test: [S9] nester acquired mutex_A, now contending on mutex_B\n");

	/* B is held by holder_b — will block for ~hold_ms */
	mutex_lock(&s9_mutex_b);
	pr_info("mutex_test: [S9] nester acquired mutex_B inside A's critical section\n");
	msleep(1);  /* Trivial hold */
	mutex_unlock(&s9_mutex_b);
	pr_info("mutex_test: [S9] nester released mutex_B\n");

	mutex_unlock(&s9_mutex_a);
	pr_info("mutex_test: [S9] nester released mutex_A\n");
	atomic_inc(&s9_done);
	return 0;
}

static int run_scenario_9(void)
{
	struct task_struct *hb, *tn;
	int done;

	pr_info("mutex_test: === Scenario 9: Reverse nested mutex (inner long wait) ===\n");
	atomic_set(&s9_done, 0);
	hb = kthread_run(s9_holder_b, NULL, "mt_s9_hB");
	tn = kthread_run(s9_nester, NULL, "mt_s9_nest");
	if (IS_ERR(hb) || IS_ERR(tn)) {
		pr_err("mutex_test: [S9] failed to create threads\n");
		return 1;
	}
	msleep(hold_ms + 100);
	done = atomic_read(&s9_done);
	if (done == 2)
		pr_info("mutex_test: [S9] PASS: %d/2 threads completed\n", done);
	else
		pr_err("mutex_test: [S9] FAIL: %d/2 threads completed\n", done);
	return done == 2 ? 0 : 1;
}

/* ========================================================================
 * Scenario 10: High thread count contention
 *
 * Tests: dynvar space pressure, lock_wait_cnt accuracy with many waiters
 *
 * 16 threads all contend on a single mutex. The holder holds for
 * hold_ms, then each waiter holds for 15ms after acquiring so the
 * remaining waiters keep contending. DTrace should report waiter_count
 * values up to 15 and handle dynvar allocation for all threads.
 * ======================================================================== */

#define S10_NUM_THREADS 16
static DEFINE_MUTEX(s10_mutex);
static atomic_t s10_done = ATOMIC_INIT(0);

static int s10_holder(void *data)
{
	mutex_lock(&s10_mutex);
	pr_info("mutex_test: [S10] holder acquired lock, sleeping %dms\n", hold_ms);
	msleep(hold_ms);
	mutex_unlock(&s10_mutex);
	pr_info("mutex_test: [S10] holder released lock\n");
	atomic_inc(&s10_done);
	return 0;
}

static int s10_waiter(void *data)
{
	int id = (int)(long)data;

	msleep(10);
	pr_info("mutex_test: [S10] waiter-%d attempting lock\n", id);
	mutex_lock(&s10_mutex);
	pr_info("mutex_test: [S10] waiter-%d acquired lock\n", id);
	/* Hold briefly so remaining waiters keep contending */
	msleep(15);
	mutex_unlock(&s10_mutex);
	atomic_inc(&s10_done);
	return 0;
}

static int run_scenario_10(void)
{
	struct task_struct *th;
	int i, done;

	pr_info("mutex_test: === Scenario 10: High thread count (%d threads) ===\n",
		S10_NUM_THREADS);
	atomic_set(&s10_done, 0);
	th = kthread_run(s10_holder, NULL, "mt_s10_hold");
	if (IS_ERR(th)) {
		pr_err("mutex_test: [S10] failed to create holder\n");
		return 1;
	}
	for (i = 0; i < S10_NUM_THREADS - 1; i++) {
		th = kthread_run(s10_waiter, (void *)(long)i, "mt_s10_w%d", i);
		if (IS_ERR(th))
			pr_err("mutex_test: [S10] failed to create waiter-%d\n", i);
	}
	/* Wait: holder hold + each waiter holds 15ms sequentially + margin */
	msleep(hold_ms + ((S10_NUM_THREADS - 1) * 20) + 200);
	done = atomic_read(&s10_done);
	if (done == S10_NUM_THREADS)
		pr_info("mutex_test: [S10] PASS: %d/%d threads completed\n", done, S10_NUM_THREADS);
	else
		pr_err("mutex_test: [S10] FAIL: %d/%d threads completed\n", done, S10_NUM_THREADS);
	return done == S10_NUM_THREADS ? 0 : 1;
}

/* ========================================================================
 * Scenario 11: Many unique mutexes
 *
 * Tests: dynvar space with many unique mutex address keys
 *
 * Dynamically allocates 50 mutexes. For each mutex, a holder+waiter
 * pair contends briefly (hold_ms/2). All pairs run concurrently.
 * Stresses the dynvar pool with 50 unique mutex addresses x multiple
 * timestamp entries each.
 * ======================================================================== */

#define S11_NUM_MUTEXES 50

struct s11_pair_args {
	struct mutex *mtx;
	int pair_id;
	int hold_time;
};

static atomic_t s11_done = ATOMIC_INIT(0);

static int s11_holder(void *data)
{
	struct s11_pair_args *args = data;

	mutex_lock(args->mtx);
	msleep(args->hold_time);
	mutex_unlock(args->mtx);
	atomic_inc(&s11_done);
	return 0;
}

static int s11_waiter(void *data)
{
	struct s11_pair_args *args = data;

	msleep(5);
	mutex_lock(args->mtx);
	msleep(1);
	mutex_unlock(args->mtx);
	atomic_inc(&s11_done);
	return 0;
}

/* Static storage for pair args so they persist for thread lifetime */
static struct s11_pair_args s11_args[S11_NUM_MUTEXES];

static int run_scenario_11(void)
{
	struct mutex *mutexes;
	struct task_struct *th;
	int i, done;
	int pair_hold = hold_ms / 2;
	int expected = S11_NUM_MUTEXES * 2;

	pr_info("mutex_test: === Scenario 11: Many unique mutexes (%d) ===\n",
		S11_NUM_MUTEXES);

	mutexes = kmalloc_array(S11_NUM_MUTEXES, sizeof(struct mutex), GFP_KERNEL);
	if (!mutexes) {
		pr_err("mutex_test: [S11] failed to allocate mutexes\n");
		return 1;
	}

	atomic_set(&s11_done, 0);
	for (i = 0; i < S11_NUM_MUTEXES; i++) {
		mutex_init(&mutexes[i]);
		s11_args[i].mtx = &mutexes[i];
		s11_args[i].pair_id = i;
		s11_args[i].hold_time = pair_hold;
	}

	/* Launch all holder+waiter pairs concurrently */
	for (i = 0; i < S11_NUM_MUTEXES; i++) {
		th = kthread_run(s11_holder, &s11_args[i], "mt_s11_h%d", i);
		if (IS_ERR(th)) {
			pr_err("mutex_test: [S11] failed to create holder-%d\n", i);
			continue;
		}
		th = kthread_run(s11_waiter, &s11_args[i], "mt_s11_w%d", i);
		if (IS_ERR(th))
			pr_err("mutex_test: [S11] failed to create waiter-%d\n", i);
	}

	/* Wait for all pairs to finish + margin */
	msleep(pair_hold + 200);
	done = atomic_read(&s11_done);
	/* Generous threshold: 100 threads, allow some creation failures */
	if (done >= 90)
		pr_info("mutex_test: [S11] PASS: %d/%d threads completed\n", done, expected);
	else
		pr_err("mutex_test: [S11] FAIL: %d/%d threads completed\n", done, expected);
	kfree(mutexes);
	return done >= 90 ? 0 : 1;
}

/* ========================================================================
 * Scenario 12: Rapid lock/unlock burst
 *
 * Tests: sustained high-frequency events, DTrace buffer pressure
 *
 * 4 threads each do 100 rapid lock/unlock cycles on the same mutex,
 * holding for 15ms per cycle. Generates a large volume of events
 * quickly to stress DTrace's bufsize, aggsize, and dynvar turnover.
 * ======================================================================== */

#define S12_NUM_THREADS  4
#define S12_ITERATIONS   100
#define S12_HOLD_MS      15
static DEFINE_MUTEX(s12_mutex);
static atomic_t s12_done = ATOMIC_INIT(0);

static int s12_cycler(void *data)
{
	int id = (int)(long)data;
	int i;

	for (i = 0; i < S12_ITERATIONS; i++) {
		mutex_lock(&s12_mutex);
		msleep(S12_HOLD_MS);
		mutex_unlock(&s12_mutex);
		/* Minimal yield so other threads can contend */
		msleep(1);
	}
	pr_info("mutex_test: [S12] thread-%d completed %d cycles\n", id, S12_ITERATIONS);
	atomic_inc(&s12_done);
	return 0;
}

static int run_scenario_12(void)
{
	struct task_struct *th;
	int i, done;

	pr_info("mutex_test: === Scenario 12: Rapid burst (%d threads x %d cycles) ===\n",
		S12_NUM_THREADS, S12_ITERATIONS);
	atomic_set(&s12_done, 0);
	for (i = 0; i < S12_NUM_THREADS; i++) {
		th = kthread_run(s12_cycler, (void *)(long)i, "mt_s12_t%d", i);
		if (IS_ERR(th))
			pr_err("mutex_test: [S12] failed to create thread-%d\n", i);
	}
	/* Worst case: all cycles serialized — (15ms+1ms)*100*4 + margin */
	msleep(S12_NUM_THREADS * S12_ITERATIONS * (S12_HOLD_MS + 1) + 500);
	done = atomic_read(&s12_done);
	if (done == S12_NUM_THREADS)
		pr_info("mutex_test: [S12] PASS: %d/%d threads completed\n", done, S12_NUM_THREADS);
	else
		pr_err("mutex_test: [S12] FAIL: %d/%d threads completed\n", done, S12_NUM_THREADS);
	return done == S12_NUM_THREADS ? 0 : 1;
}

/* ========================================================================
 * Scenario 13: Long wait with short hold (explicit path test)
 *
 * Tests: mutex_unlock:entry predicate where long_wait[addr] is set
 *        but the hold time itself is below threshold
 *
 * Thread A (holder) holds the mutex for hold_ms. Thread B (waiter)
 * blocks for ~hold_ms acquiring it (long_wait), then immediately
 * releases (hold time ~0). DTrace should report the full lifecycle:
 * long acquisition time + near-zero hold time.
 * ======================================================================== */

static DEFINE_MUTEX(s13_mutex);
static atomic_t s13_done = ATOMIC_INIT(0);

static int s13_holder(void *data)
{
	mutex_lock(&s13_mutex);
	pr_info("mutex_test: [S13] holder acquired lock, sleeping %dms\n", hold_ms);
	msleep(hold_ms);
	mutex_unlock(&s13_mutex);
	pr_info("mutex_test: [S13] holder released lock\n");
	atomic_inc(&s13_done);
	return 0;
}

static int s13_waiter(void *data)
{
	msleep(5);
	pr_info("mutex_test: [S13] waiter attempting lock (will block ~%dms)\n", hold_ms);
	mutex_lock(&s13_mutex);
	pr_info("mutex_test: [S13] waiter acquired lock, releasing immediately\n");
	/* Immediate release — hold time is near zero */
	mutex_unlock(&s13_mutex);
	pr_info("mutex_test: [S13] waiter released lock (short hold, long wait path)\n");
	atomic_inc(&s13_done);
	return 0;
}

static int run_scenario_13(void)
{
	struct task_struct *th, *tw;
	int done;

	pr_info("mutex_test: === Scenario 13: Long wait + short hold ===\n");
	atomic_set(&s13_done, 0);
	th = kthread_run(s13_holder, NULL, "mt_s13_hld");
	tw = kthread_run(s13_waiter, NULL, "mt_s13_wt");
	if (IS_ERR(th) || IS_ERR(tw)) {
		pr_err("mutex_test: [S13] failed to create threads\n");
		return 1;
	}
	msleep(hold_ms + 100);
	done = atomic_read(&s13_done);
	if (done == 2)
		pr_info("mutex_test: [S13] PASS: %d/2 threads completed\n", done);
	else
		pr_err("mutex_test: [S13] FAIL: %d/2 threads completed\n", done);
	return done == 2 ? 0 : 1;
}

/* ========================================================================
 * Module init / exit
 *
 * On load: runs the requested scenario(s) sequentially, with a 200ms
 * gap between scenarios when running all (for clean DTrace separation).
 *
 * On unload: logs a message. Ensure all scenarios have completed
 * (check dmesg) before calling rmmod.
 * ======================================================================== */

static int __init mutex_test_init(void)
{
	int failures = 0;
	int total = 0;

	pr_info("mutex_test: Loading module (run_scenario=%d, hold_ms=%d)\n",
		run_scenario, hold_ms);

	if (run_scenario == 0 || run_scenario == 1) {
		failures += run_scenario_1();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 2) {
		failures += run_scenario_2();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 3) {
		failures += run_scenario_3();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 4) {
		failures += run_scenario_4();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 5) {
		failures += run_scenario_5();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 6) {
		failures += run_scenario_6();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 7) {
		failures += run_scenario_7();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 8) {
		failures += run_scenario_8();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 9) {
		failures += run_scenario_9();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 10) {
		failures += run_scenario_10();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 11) {
		failures += run_scenario_11();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 12) {
		failures += run_scenario_12();
		total++;
	}
	if (run_scenario == 0)
		msleep(200);

	if (run_scenario == 0 || run_scenario == 13) {
		failures += run_scenario_13();
		total++;
	}

	pr_info("mutex_test: All requested scenarios launched\n");
	pr_info("mutex_test: Results: %d of %d PASSED, %d FAILED\n",
		total - failures, total, failures);
	return 0;
}

static void __exit mutex_test_exit(void)
{
	pr_info("mutex_test: Module unloaded\n");
}

module_init(mutex_test_init);
module_exit(mutex_test_exit);
