# Pedals Ghostty Swift overlay

This package preserves the `GhosttyKit`, `GhosttyTerminal`, and `GhosttyTheme`
Swift sources from `libghostty-spm` 1.3.1 and references the exact same
checksummed XCFramework release. Pedals carries one queue-ordering extension:
host-managed output can be parsed synchronously on the UI host's render
executor, so Ghostty never renders a surface while another queue mutates it.
It also exposes a render-only request for host-managed output, keeping surface
size synchronization exclusively in the view layout lifecycle. UIKit
IOSurface layers are updated without implicit animation and clipped to their
terminal view during keyboard-driven layout changes.

Upstream: <https://github.com/Lakr233/libghostty-spm/tree/1.3.1>

The copied upstream sources remain under their original MIT license. Local
changes are intentionally limited to the in-memory output/render path and its
tests.
