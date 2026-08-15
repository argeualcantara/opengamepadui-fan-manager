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
