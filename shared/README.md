# Shared helpers

Add a helper here when more than one widget needs it. Give Lua modules an
`aio_widgets_` prefix to avoid collisions with AIO's built-in libraries and
other installed scripts.

The installer copies shared `.lua` files alongside widgets in AIO's script
directory. OpenCode Go currently uses AIO's built-in libraries and remains
self-contained.
