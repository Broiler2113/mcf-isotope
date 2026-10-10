extends "res://tests/NetSmokeBase.gd"
func _initialize() -> void:
	tag = "kick-guest"
	start_net(false)
	step("kicked guest returns to menu", func() -> bool: return scene_is("MainMenu.gd"))
