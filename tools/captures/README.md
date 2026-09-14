# Real captured AirPlay sessions

Local scratch, not git-tracked (`*.cap` in `.gitignore`) -- real `-capture`
recordings are 10-150MB+ and specific to whatever content was mirrored
when they were made, not reproducible artifacts.

Consumed by `tools/test-render-health-e2e.sh`, which replays every
`.cap` file found here via `-replay` and asserts a healthy render/decode
ratio. With none present, that script prints "No captures found... --
nothing to test" and exits cleanly (not a failure) -- this directory is
allowed to be empty.

To add one: enable `-capture <file>.cap` on the live `uxplay.service`
(see `docs/threadtest.md`/`PROGRESS.md` for the flag), reproduce a real
AirPlay mirroring session against whatever content is relevant, then
copy the resulting file here. Useful specifically for bugs that only
reproduce with real client traffic (see `test-render-health-e2e.sh`'s
own header comment for a concrete example: a real client's
non-native-resolution content triggered a render-rate collapse that no
synthetic capture ever reproduced).
