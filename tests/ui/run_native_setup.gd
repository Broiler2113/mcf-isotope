extends "res://tests/SuiteBase.gd"

func run() -> void:
	var runtime := NativeAcceleration.status()
	ck(runtime.state in ["active", "partial", "fallback", "disabled"], "startup reports a recognized acceleration state")
	# Settings uses the Keybinds autoload, so load it after the test tree starts.
	var settings_script := load("res://src/ui/SettingsWindow.gd") as GDScript
	ck(settings_script != null and settings_script.can_instantiate(), "settings script loads after autoloads are ready")
	if not fails.is_empty(): return
	var window: Node = settings_script.open(root)
	await process_frame
	await process_frame
	ck(window._tabs.get_tab_title(0) == "General", "performance status is available in the normal settings page")
	ck(window._acceleration_status.text == runtime.title and window._acceleration_detail.text == runtime.detail,
		"settings show the actual loaded acceleration status")
	ck(window._performance_box.find_children("*", "BaseButton", true, false).is_empty(),
		"automatic acceleration needs no activation switch or setup button")
	# A previously active status must never survive a later unavailable/disabled
	# report, and the reason must remain readable instead of disappearing in a tooltip.
	for fixture: Dictionary in [
		{"state": "active", "title": "C++ acceleration active", "detail": "Enabled automatically for all game systems.", "active_count": 5},
		{"state": "partial", "title": "C++ acceleration partly active", "detail": "Some systems are using standard processing.", "active_count": 2},
		{"state": "fallback", "title": "C++ acceleration unavailable", "detail": "This system uses standard processing. The game remains playable.", "active_count": 0},
		{"state": "disabled", "title": "C++ acceleration disabled", "detail": "Disabled for this local development session.", "active_count": 0},
	]:
		window._refresh_acceleration(fixture)
		await process_frame
		ck(window._acceleration_status.text == fixture.title and window._acceleration_detail.text == fixture.detail,
			"settings replace the previous state and explanation: " + fixture.state)
		ck(window._acceleration_detail.visible and window._acceleration_detail.autowrap_mode != TextServer.AUTOWRAP_OFF,
			"the acceleration explanation stays visible and wraps within settings")
	window._refresh_acceleration()
	ck(window._acceleration_status.text == runtime.title, "refresh returns to live runtime status")
	window._tabs.current_tab = 1
	window._build()
	await process_frame
	ck(window._tabs.current_tab == 1, "rebuilding settings retains the selected tab")
	ck(window._acceleration_status.text == NativeAcceleration.status().title, "rebuilt settings read live status again")
	window.free()
	await process_frame
