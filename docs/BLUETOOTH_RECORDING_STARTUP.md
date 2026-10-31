# Bluetooth recording startup — 2.1.6

The 2.1.5 (45.1) report shows three interrupted attempts approximately 0.7 seconds
following countdown, no saved take, and a -120 dB meter reading. The old short-file
message erased the initiating stop reason; the exact device trigger is unproven.

Prepare permission, route and recorder before countdown. Start with a fenced,
bounded two-second wait for two advancing microphone-clock observations before
publishing capturing and enabling the unchanged 200 ms drift guard. Silent audio
is valid; amplitude is not a readiness test. Use the finished-review/player clock
for placement. Handle notifications synchronously on their main delivery queue,
ignoring setup changes only while the configured route remains valid. Actual
route/configuration loss, interruption and background still stop capture.

Typed completion retains cause and save outcome. Existing takes and project schema
are preserved. New attempt diagnostics use UUIDs, finite clock/frame/sample-rate
values and allowlisted phases; no accessory names, serials or media are logged.

Required CI includes native tests/archive. The production readiness loop is tested
with delayed clocks (including 0.7/1.5 seconds), no progress and cancellation.
Physical acceptance remains pending: AirPods Pro A2698 (firmware 9A348), reported
iOS 27.2. Record five consecutive >=10-second takes on the affected review,
including a fresh connection and warm retries; verify countdown off, video with
and without audio, built-in mic, Pause/Resume, deliberate disconnection,
playback/reopen/export and source/WAV preservation. Record actual iPhone model,
OS/build and diagnostics. Simulator tests do not prove Bluetooth operation.
