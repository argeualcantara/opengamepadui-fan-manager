extends RefCounted
class_name HardwareWriteQueue

## Serializes hardware writes through one shared background thread,
## coalescing by key so a newer submit for the same key replaces an
## unstarted one instead of queuing up, while different keys never
## drop each other.

var _busy: bool = false
var _pending_jobs: Dictionary = {}
var _thread: Thread


## Runs job on the shared thread now, or as soon as the current job
## finishes if one is already running. A second submit with the same
## key before that job starts replaces it.
func submit(key: String, job: Callable) -> void:
	if _busy:
		_pending_jobs[key] = job
		return
	_start(job)


func _start(job: Callable) -> void:
	_busy = true
	if _thread and _thread.is_started():
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


## Blocks until any in-flight job finishes. Call before this object is freed.
func shutdown() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
