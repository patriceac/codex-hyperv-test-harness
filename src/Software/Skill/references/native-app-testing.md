# Native application testing

These opt-in actions use the same broker, disconnected worker, payload, read-only host inputs, cancellation, live observation and terminal evidence as ordinary tests. Submit the canonical application artifact. Do not run helpers on the physical host or operate worker VMs directly.

## Readiness and coordinates

`wait_window` and desktop capture readiness do not prove that an application has rendered. Prefer `wait_result_file` when an application writes an atomic ready marker. Otherwise wait for a visible content condition before sending input:

```json
[
  {"type":"wait_window","timeoutMs":30000},
  {"type":"wait_content","name":"scene-ready","timeoutMs":20000,"pollMs":100,"stableMs":250,
   "viewport":{"width":320,"height":200,"scaling":"integer_fit"},
   "pixels":[{"x":20,"y":30,"color":"#00FF00"}]},
  {"type":"click_client","x":20,"y":30,"viewport":{"width":320,"height":200,"scaling":"integer_fit"}}
]
```

`wait_content` requires exactly one condition: `pixels` (up to 64 positions/colors), `referencePath` (image comparison below), or `notColor` plus `minFraction` (fraction of the region differing from that RGB color). A nonblack region alone is a weak readiness signal; choose application-specific content when possible. `channelTolerance` is an integer 0–255, default 0. `timeoutMs` is required, 100–300000; `pollMs` is 25–2000, default 100; `stableMs` defaults to 0 and cannot exceed the timeout. Stability means the condition holds at every sampled frame throughout that interval, not proof of unobserved frames or identical animation pixels. A timeout sets `TestPassed=false`, `TestFailureKind=ContentReadinessTimeout`, stops subsequent input/waits, and retains the last frame/condition and later requested diagnostic screenshots.

`click_client` coordinates are physical client pixels unless `viewport` is supplied. It measures `GetClientRect` and `ClientToScreen` in a per-monitor DPI-aware thread; title bars and borders are excluded. Evidence records window/client rectangles, screen origin, DPI, viewport rectangle, scales and final screen click. `click_relative` keeps its existing outer-window behavior.

Viewport width/height are 1–4096 logical pixels. `integer_fit` uses the largest whole-number uniform scale that fits; it rejects a client smaller than the reference. `fit` uses a uniform fractional scale with dimensions rounded down; `stretch` independently fills both axes. Fit modes center the viewport, putting any spare odd pixel on the right/bottom. Clicks select the center of a logical pixel. These rules are caller declarations, not inferred game settings: use the rule the application actually implements. Minimized, off-desktop, oversized and out-of-bounds targets fail. Captures contain the visible desktop pixels, including occlusion; they are not hidden-window renders.

Visual actions optionally take `region:{x,y,width,height}` within the client/declared viewport. Captures normalize each logical pixel by its physical center sample, without interpolation. A region's pixel conditions, masks and reference image are relative to that region. Geometry is measured again for every capture/click.

## Image assertions and transient capture

```json
[
  {"type":"assert_image","name":"wall","viewport":{"width":320,"height":200,"scaling":"integer_fit"},
   "region":{"x":0,"y":32,"width":224,"height":136},"referencePath":"{HOSTINPUT:references}\\wall.png",
   "channelTolerance":2,"maxMismatchFraction":0.001,"masks":[{"x":0,"y":0,"width":8,"height":8}]},
  {"type":"capture_burst","name":"flash","durationMs":1000,"fps":30,"maxFrames":30,"maxBytes":16777216,
   "viewport":{"width":320,"height":200,"scaling":"integer_fit"},
   "trigger":{"type":"click_client","x":160,"y":90,"viewport":{"width":320,"height":200,"scaling":"integer_fit"}}}
]
```

`assert_image` compares RGB channels; alpha is ignored. The caller supplies a PNG through `{PAYLOAD}` or a declared read-only `{HOSTINPUT:name}`. Reference dimensions must exactly match the normalized region. At most 32 rectangular masks may exclude pixels; masking the entire image is rejected. A pixel mismatches if any RGB channel exceeds `channelTolerance`. `maxMismatchFraction` (0–1, default 0) sets the allowed mismatched fraction of unmasked pixels. Evidence includes actual/reference/diff PNGs, the reference hash, masks/tolerances, compared and mismatched counts, fraction, mean channel error and maximum channel error. Diff red means mismatch, blue means masked, dark gray means matched. Failed comparison is an application verdict; capture, transport and cleanup results remain separate.

`capture_burst` requires duration 50–10000 ms, requested rate 1–60 fps, maxFrames 1–240 and maxBytes 1024–67108864. `maxBytes` bounds encoded frame bytes; the separately bounded metadata reservation is 1 MiB. It returns timestamps for acquisition start/end, elapsed time, per-frame geometry, actual count/bytes, trigger timing and a stop reason. Rate is best effort: capture/PNG encoding consumes time and missed slots are skipped, never backdated. Do not infer a game's presentation FPS from these samples. The optional trigger is one bounded `click_client` only. Helpers are loaded before application launch and the first frame is captured before triggering input. This avoids per-frame process startup and preserves pre-trigger evidence. It cannot retrospectively capture effects that occurred before the action began. There is no input trigger if the first frame cannot fit the byte budget.

Evidence is under `native-<name>/`. Names are unique ASCII identifiers starting with a letter, up to 48 characters. A request allows at most 32 native actions and reserves at most 256 MiB for their evidence. Individual PNGs/references are capped at 32 MiB; visual surfaces at 8388608 pixels. Unknown fields and nonintegral bounds are rejected by the shared client/broker/guest contract. Use separate requests when a plan exceeds these limits.

## Controller and audio qualification

```json
[
  {"type":"controller","operation":"connect"},
  {"type":"controller","operation":"state","buttons":["A","LeftShoulder"],"leftX":0.5,"leftY":-0.25,"rightTrigger":1,"holdMs":250},
  {"type":"controller","operation":"disconnect"}
]
```

Controller operations are `probe`, `connect`, `state`, `disconnect`. The guest uses Microsoft's [InputInjector virtual gamepad API](https://learn.microsoft.com/en-us/uwp/api/windows.ui.input.preview.injection.inputinjector.initializegamepadinjection), which requires the `inputInjectionBrokered` capability. Probe and connect require a newly enumerated Windows.Gaming.Input device within five seconds; successful API initialization alone is insufficient. Evidence records the before/after device counts and elapsed time, and missing enumeration returns `CapabilityUnavailable` after disconnecting. Probe disconnects the temporary device; connect retains a request-owned device. State holds 10–10000 ms and always releases to neutral; job cleanup also disconnects. Allowed buttons: Menu, View, A, B, X, Y, DPadUp/Down/Left/Right, LeftShoulder/RightShoulder, LeftThumbstick/RightThumbstick. Sticks use `leftX/leftY/rightX/rightY` in −1…1; triggers use `leftTrigger/rightTrigger` in 0…1; omitted values are neutral.

Missing/denied support returns `CapabilityUnavailable` with the concrete guest reason and prerequisite. The harness does not grant restricted capabilities or install a driver during a test. An API call receipt proves injection only; require the application to acknowledge input to prove reception. The generic acceptance consumer waits for device enumeration and reads the button and analog state through Windows.Gaming.Input. It records XInput observation separately; Windows.Gaming.Input reception does not prove XInput compatibility. Godot or another engine still needs its own acceptance. Synthetic application events, Windows virtual device input and physical Xbox input are distinct proof levels; none of these actions proves a physical controller. The retired [ViGEm backend](https://docs.nefarius.at/projects/ViGEm/End-of-Life/) is not installed or silently substituted.

```json
[
  {"type":"audio_probe","name":"endpoints"},
  {"type":"capture_audio","name":"playback","durationMs":2000,"maxBytes":4194304}
]
```

Audio probe enumerates actual render/capture endpoint IDs, states and default selection. `capture_audio` uses supported [WASAPI render-endpoint loopback](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording), optionally selecting an exact `endpointId`. It requires an active render endpoint; a console-only VM may have none and returns `CapabilityUnavailable`. Duration is 100–30000 ms and total WAV bytes are bounded to 1024–33554432. `playback.wav` retains the endpoint mix format; metadata records endpoint, raw WAVEFORMATEX bytes, format/channels/rate, elapsed/audio durations, device/QPC positions, packets, discontinuities and timestamp errors. No packets is explicitly recorded; silence is not fabricated to fill time. The capture includes the guest endpoint mix, potentially including other guest sounds. An application-produced or decoded WAV is different evidence and must be labeled that way. Neither proves physical speaker audibility.

## Opt-in deterministic application protocol

Applications must explicitly implement this protocol and receive the protocol directory through their own test argument, for example `--test-protocol "{OUTDIR}\\app-protocol"`. It is inactive for ordinary applications. Ready-file support alone can continue using `wait_result_file`.

```json
[
  {"type":"app_command","name":"ready","operation":"ready","timeoutMs":5000},
  {"type":"app_command","name":"seed","operation":"seed","seed":123,"timeoutMs":5000},
  {"type":"app_command","name":"advance","operation":"advance","ticks":10,"timeoutMs":5000},
  {"type":"app_command","name":"checkpoint","operation":"checkpoint","timeoutMs":5000,"jsonPointer":"/state/ticks","equalsJson":"10"}
]
```

The harness atomically writes `app-protocol/<nonce>.command.json` with `protocol:"codex-app-test-v1"`, `requestId`, unique `id`, `operation`, and `seed` or `ticks` when applicable. The application polls that directory only when opted in, freezes automatic simulation advancement, and handles each nonce once. It atomically publishes `<nonce>.response.json`, echoing protocol/requestId/id/operation, with Boolean `ok` and a JSON `state` snapshot. File creation must be atomic (write temporary file, then rename); a partial JSON file is a protocol failure. ACK identity is checked, so previous requests/commands cannot satisfy a new wait. Replies are capped at 1 MiB. Optional RFC 6901 `jsonPointer`/typed `equalsJson` use the existing JSON assertion evaluator on the reply.

`ready` must succeed before other operations. A missing ready ACK reports `CapabilityUnavailable`; a later timeout is an application failure. `seed` accepts 0–2147483647; `advance` accepts 1–100000 ticks; timeouts are 100–60000 ms. `checkpoint` observes state without advancing simulation. Apps should apply supplied seeds to every relevant random source, advance exactly the requested ticks, and report enough state for meaningful assertions. The harness cannot make an unmodified application deterministic. Initial fixtures may use existing read-only host-input transport; no arbitrary command, expression, executable or response path is accepted here.

`NativeAppCanary.cs` is the original example consumer. Its acceptance resets a seed and repeats ticks, compares checkpoint values, proves logical and physical client-pixel clicks, captures a short effect and its disappearance, and separately verifies the readiness timeout. Controller/audio acceptance records either actual stack/endpoint evidence or an explicit unavailability reason. Integration into a particular game's test mode belongs to that game's codebase.
