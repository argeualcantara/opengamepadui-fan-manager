extends GutTest

var queue: HardwareWriteQueue


func before_each() -> void:
	queue = HardwareWriteQueue.new()


func after_each() -> void:
	queue.shutdown()


func test_submit_runs_the_job() -> void:
	var ran := [false]
	queue.submit("fan-0", func(): ran[0] = true)

	await wait_seconds(0.2, "let the background thread and its deferred callback run")

	assert_true(ran[0])


func test_second_submit_with_same_key_while_busy_replaces_the_pending_job() -> void:
	var order := []
	queue.submit("fan-0", func():
		OS.delay_msec(100)
		order.append("first")
	)
	queue.submit("fan-0", func(): order.append("second"))
	queue.submit("fan-0", func(): order.append("third"))

	await wait_seconds(0.4, "let the running job finish and the coalesced one run")

	assert_eq(order, ["first", "third"])


func test_different_keys_both_run() -> void:
	var order := []
	queue.submit("fan-0", func():
		OS.delay_msec(100)
		order.append("fan-0")
	)
	queue.submit("fan-1", func(): order.append("fan-1"))

	await wait_seconds(0.4, "let both jobs run")

	assert_eq(order.size(), 2)
	assert_true(order.has("fan-0"))
	assert_true(order.has("fan-1"))


func test_shutdown_waits_for_the_running_job() -> void:
	var ran := [false]
	queue.submit("fan-0", func():
		OS.delay_msec(50)
		ran[0] = true
	)

	queue.shutdown()

	assert_true(ran[0])


# regression: shutdown() calling straight after a submit() that landed in
# _pending_jobs (because something else was still running) used to return
# without ever starting that pending job - _on_job_done() is what pulls it
# out of _pending_jobs, and that only runs later via call_deferred, which
# never gets a chance to fire while shutdown() is blocking synchronously
func test_shutdown_drains_a_job_still_pending_when_called() -> void:
	var ran := [false, false]
	queue.submit("fan-0", func():
		OS.delay_msec(50)
		ran[0] = true
	)
	queue.submit("fan-1", func(): ran[1] = true)

	queue.shutdown()

	assert_true(ran[0], "the already-running job should have finished")
	assert_true(ran[1], "the job still in _pending_jobs should also have run")


func test_submit_before_last_job_still_runs() -> void:
	var ran := [false]
	var noop_job := func(): pass
	queue.submit("fan-0", func(): ran[0] = true)
	queue.submit("mode", noop_job, true)

	queue.shutdown()

	assert_true(ran[0])


func test_last_job_runs() -> void:
	var ran := [false]
	var mode_job := func(): ran[0] = true
	queue.submit("mode", mode_job, true)

	queue.shutdown()

	assert_true(ran[0])


func test_submit_after_last_job_is_ignored() -> void:
	var ran := [false, false]
	var mode_job := func(): ran[0] = true
	var fan_job := func(): ran[1] = true
	queue.submit("mode", mode_job, true)
	queue.submit("fan-0", fan_job)

	queue.shutdown()

	assert_true(ran[0], "the last job itself should still run")
	assert_false(ran[1], "a submit() after the last_job=true one must not run")
