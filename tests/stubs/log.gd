extends RefCounted
class_name Log

## Minimal stand-in for OGUI's real core/systems/debug/log.gd, just
## enough for this repo's own scripts (which only ever call
## Log.get_logger(name) and then .debug()/.info()/.warn()/.error() on
## the result) to run standalone here, without pulling in OGUI's real
## CustomLogger/LogManager machinery. Not a copy of OGUI's Log,  this
## repo has no autoload/global-class dependency on OGUI beyond this
## one call shape, so a tiny stub covers it fully.

const StubLogger = preload("res://stubs/stub_logger.gd")


static func get_logger(name: String, _level: int = 0) -> StubLogger:
	return StubLogger.new(name)
