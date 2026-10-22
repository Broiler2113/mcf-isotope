class_name CheatIntent
extends Intent

## Canonical gameplay operation. Caller is set by the live authority, never trusted
## from a guest. Replay applies the already-authorized historical stream.
var op: String
var args: Dictionary
var issuer: int

func _init(operation := "", payload: Dictionary = {}, caller := -1) -> void:
	super(-1)
	op = operation
	args = payload.duplicate(true)
	issuer = caller
