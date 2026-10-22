# MCF Isotope

Releases are source-only. Download the release archive, import `project.godot` in Godot 4.7, and run the project
with the GL Compatibility renderer. Native policy libraries are optional; source checkouts without them use
the existing socket/HARD fallback. Application exports remain paused.

Release notes start with the changes. Do not prepend the source-download and
Godot-import instructions to release descriptions.

If you disconnect from a multiplayer match, choose **Rejoin last match** from the
main menu. After connecting to the same running host, you can accept your army
back from its AI at the next round boundary. Declining leaves the AI in control.
The remembered connection works for direct connections and relay rooms. It cannot
restore a match whose host has closed it, or migrate a match to another host.
