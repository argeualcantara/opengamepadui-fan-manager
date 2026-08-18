extends RefCounted
class_name HardwareWriteQueue

# runs hardware writes on one shared background thread, coalesced by key -
# a newer submit for the same key replaces an unstarted one instead of
# piling up, different keys don't step on each other

var logger := Log.get_logger("FanManager HardwareWriteQueue")

var _busy: bool = false
var _pending_jobs: Dictionary = {}
var _thread: Thread
var _stopped := false


func submit(key: String, job: Callable, last_job: bool = false) -> void:
	if _stopped:
		logger.debug("submit('%s'): queue is stopped, ignoring" % key)
		return
	if last_job:
		_stopped = true
	if _busy:
		_pending_jobs[key] = job
		return
	_start(job)


func _start(job: Callable) -> void:
	_busy = true
	var thread_running = _thread and _thread.is_started()
	if thread_running:
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_run.bind(job))


func _run(job: Callable) -> void:
	job.call()
	call_deferred("_on_job_done")


func _on_job_done() -> void:
	_busy = false
	if _pending_jobs.is_empty():
		return
	var next_key: String = _pending_jobs.keys()[0]
	var next_job: Callable = _pending_jobs[next_key]
	_pending_jobs.erase(next_key)
	_start(next_job)


# makes sure all jobs are run to ensure the last write after queue stops
# accepting new jobs.
func shutdown() -> void:
	while true:
		var thread_running = _thread and _thread.is_started()
		if thread_running:
			_thread.wait_to_finish()
		_busy = false
		if _pending_jobs.is_empty():
			return
		var next_key: String = _pending_jobs.keys()[0]
		var next_job: Callable = _pending_jobs[next_key]
		_pending_jobs.erase(next_key)
		_start(next_job)
