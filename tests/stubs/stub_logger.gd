extends RefCounted
class_name StubLogger

## Backs Log.get_logger() in this standalone test harness. Just prints
## to stdout with a level/name prefix instead of routing through
## OGUI's real logging infrastructure — plenty for making test output
## readable, nothing here is asserted on.

var name: String


func _init(p_name: String) -> void:
	name = p_name


func debug(message: String) -> void:
	print("[DEBUG] [%s] %s" % [name, message])


func info(message: String) -> void:
	print("[INFO] [%s] %s" % [name, message])


func warn(message: String) -> void:
	print("[WARN] [%s] %s" % [name, message])


func error(message: String) -> void:
	print("[ERROR] [%s] %s" % [name, message])
