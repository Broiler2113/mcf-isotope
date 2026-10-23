# MCF Isotope

Download the release project, import `project.godot` in Godot 4.7, and run with the
GL Compatibility renderer. C++ acceleration is included and starts automatically
on Windows x64, Intel Mac with macOS 11+, and Apple
Silicon with macOS 13+. No compiler, terminal commands, or plugin setup are needed
to play.

**Settings → Interface → Performance** shows whether acceleration is active.
First-person geometry, terrain preparation, AI planning, pathfinding, and visibility
use the bundled C++ library. If acceleration is unavailable, the game remains
playable through the original GDScript implementations.

The complete source and the native libraries for all three desktop targets are in
the same project archive. See the [native guide](native/visuals/README.md) for
verification and optional developer builds. Learned-policy inference has its own
optional library; without it, learned AI retains the existing socket/HARD fallback.

Builds and CI checks target Windows and macOS only. Linux support and Linux CI
are paused until explicitly requested again.

Release notes start with the changes. Do not prepend the source-download and
Godot-import instructions to release descriptions.

If you disconnect from a multiplayer match, choose **Rejoin last match** from the
main menu. After connecting to the same running host, you can accept your army
back from its AI at the next round boundary. Declining leaves the AI in control.
The remembered connection works for direct connections and relay rooms. It cannot
restore a match whose host has closed it, or migrate a match to another host.
