# Isolated native-preview rehearsal

These are disposable research tools for the [hardening gate](../../2026-11-10-native-preview-hardening.md),
not shipped runtime modules. They use the production signed helper, API, framing
and decoder; no fake capture provider or alternate lifecycle store.

Run from this checkout on the prepared Mac (Xcode, pnpm and signing identity
required). `prepare.mjs` stages binaries only; it does not install on a headset:

```sh
node .plans/probes/native-preview/prepare.mjs
node .plans/probes/native-preview/operate.mjs --live
```

The operator must remain in an interactive terminal. `--live` opens only the owned
Mac fixture and dedicated iOS simulator. It uses a new private home and free port.
`status`, `sources`, `pulse`, `portrait`, `landscape`, `cover`, `uncover`, `open`
and `stop` operate only that rig. `launch` is the explicit physical install/start
step and must wait for the user's testing slot. `adopt` follows pairing; it uses
the actual persisted headset client ID from authenticated diagnostics.
`restart-viewer` supplies no preference overrides.

With the local rig ready, another terminal can run:

```sh
node .plans/probes/native-preview/local-checks.mjs
```

It performs a 20-second delayed-ACK run, then 40 seconds of two concurrent real
captures with source-only occlusion, late resize, static/update and resume changes.
Do not issue fixture-mutating operator commands while that script is active. It
returns fixture geometry/visibility to normal, never installs a headset app, and
writes only private local configs and bounded metadata under
`/tmp/slz-preview-hardening`. Video stays in memory. Use `stop` afterward.
The pixel hashes detect image differences, not semantic correctness or actual
headset presentation; collect the wearer's verdict separately.

The current device and dedicated simulator IDs are explicit in `operate.mjs`.
Do not replace them with an arbitrary connected device or user's simulator. Source
selection requires one exact fixture process/title and one dedicated simulator
window; unexpected counts fail. The cover tracks only the fixture's rectangle.

`prepare.mjs` uses the current development certificate/team; override
`SLOPZOOKA_SIGN_IDENTITY` if needed and verify the team before rebuilding elsewhere.
It refuses to overwrite an actively running companion bundle through the existing
Mac builder. It does not create/boot a new simulator: this Mac's dedicated simulator
must already exist. Fixture Info.plists are experiment resources, not product
identities. `ReceiverProbe.swift` builds with strict concurrency/warnings-as-errors.

Credentials, pairing-code observations, source metadata and raw logs stay in
mode-0600 files inside private temporary directories. Commit only selected sanitized
summaries. `stop` checks the private session socket's home ownership before shutting
down test PTYs, and stops only its own Mac app, fixture and dedicated simulator.
It never stops installed SlopZooka, its existing session service or their terminals.

The next headset slot follows the [combined Direct-video and scene-restoration
script](../../2026-11-10-direct-native-video.md#combined-headset-slot-approximately-35-minutes-after-pairing).
It exercises both native streams alongside terminal input, then app restart and
LAN return; do not use the historical Direct-unavailable expectation.
