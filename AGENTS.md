# Working on AIO Widgets

- Keep deployable scripts in `widgets/`, with AIO name, type, version, and minimum-version metadata.
- Preserve widget filenames during updates so launcher preferences remain associated with the existing script.
- Keep widgets self-contained until common behavior actually needs a shared helper. Shared helpers must have unique `aio_widgets_` filenames and live in `shared/`.
- Follow AIO's handedness preference, theme text colors, and display density. Do not change launcher preferences while reading them.
- Keep labels, bars, and percentages aligned. Compact mode shows window labels and bars; expanded mode adds percentages and reset times. Use the native settings gear for controls.
- Retain balanced outer margins relative to the launcher divider. Do not force rectangular SVGs into square icons or use negative margins to correct their height; that caused collapse/expand jank.
- Preserve intrinsic image sizing and skip unchanged redraws. Folding must update content without extra network requests or animation regressions.
- Use HTTPS, explicit request throttling, useful offline states, and API-reset timestamps. Do not assume a window has reset before checking its API reading.
- Credentials belong in per-widget phone preferences. Never embed them in scripts, fixtures, screenshots, or Git history. Test data must be synthetic.
- Run `./tools/check.sh` after behavioral changes. Visual changes also require checking the real widget on a connected phone, including folding and both handedness modes when relevant.
- Install only the selected widget using `tools/install.py`. Avoid removing or replacing unrelated scripts, preferences, or caches. Restart the launcher only when needed or explicitly requested with `--reload`.
- Do not copy APKs, decompiled launcher code, recordings, authentication files, or scratch files into this repository.
