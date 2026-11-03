Toss — wireless capture backend

This is a capture component. It never operates ChatGPT/Codex, pastes, sends a
message, pairs a device, invokes USB capture, or requests remote unlock.

0.3.0 preconnected persistent worker (SOURCE / OFFLINE VERIFIED; NOT DEVICE-TIMED)

The native helper now runs capture_service.py as its own anonymous-pipe child:
  python capture_service.py --state-dir /private/paired-state \
    --output-dir /private/capture-cache --idle-seconds 600 [--preconnect]
The parent is the only command sender. No TCP/HTTP listener is exposed.
stdin accepts one JSONL object per request, with exactly these keys:
  {"action":"capture","request_id":"<canonical-lowercase-UUID>",
   "output_file":"/private/capture-cache/new.png","timeout":40}
There is no unsolicited startup/ready output. stdout emits one bounded (<16KiB)
schema_version=1 receipt per request; libraries' stdout/stderr are suppressed.
The prior success receipt fields and native CaptureReceipt validation remain.
Additional diagnostics: connection_reused (boolean), timings_ms (connect,
screenshot RPC, validation and total). Timing fields contain only finite ms.

The process imports dependencies once. With explicit --preconnect (user Enable),
it prepares only the authenticated RSD/tunnel, without DVT or a screenshot.
Without that flag it authenticates only on a capture request. It retains the
connection for at most 600 idle seconds after connection or a successful request.
Every accepted UUID opens new DVT/Screenshot objects and calls get_screenshot once.
It never captures during idle, caches frames for later delivery, or falls back to
an old image. Only the connection and Python imports are reused. Initial capture,
idle expiry and the next request after a failure can still take several seconds.
One request is active; busy requests and repeated UUIDs are rejected, not queued.
Any capture/protocol error discards the session; the native helper also discards
the child. There is no automatic capture retry. Every result still passes exact
UUID/time/hash/private-file/size checks and current-chat revalidation before paste.

The fixed cache directory is owner-only, its inode is retained, and output must
be its direct child; publication is atomic/no-overwrite with mode0600. A stopped
or killed capture can leave a private output or staging file in the narrow gap
between publication and parent receipt; it can never be reused for another UUID.
Both completed iPad-*.png and temporary .capture-service-*.png receive24-hour-on-next-launch cache cleanup. Normal shutdown closes the
connection; a parent-death watchdog and isolated-process-group cleanup bound stuck workers.
A Swift/Foundation child may already lead its process group: setsid EPERM is
accepted only when child pgid equals its pid and differs from the parent group.
Group teardown can end the child with SIGKILL even after a completed receipt;
per-request success is the validated JSONL receipt, not process exit status.
The Swift reader uses POSIX short reads: Foundation's read(upToCount:) waits for
a full requested buffer/EOF on this macOS. F_SETNOSIGPIPE protects the write pipe.

The 0.2.1 helper has user-confirmed wireless attachment and success-sound results.
This 0.3.0 change has offline process/contract/synthetic coverage only; 0.2.1
remains the installed working build until deployment and user-triggered acceptance.

Legacy single-request CLI (Python 3.13 with OpenSSL PSK support, pinned dependencies):
  python capture_once.py --state-dir /private/paired-state \
    --output-file /private/request-folder/new.png \
    --request-id 00000000-0000-4000-8000-000000000001 --timeout 45

--state-dir points to the existing initial-setup state, not a copy shipped with
this tool. It needs owner-only directory permissions and owner-only target.json
and strict-remote-pairing.plist files. The backend reads existing pairing state;
it never substitutes a different iPad and never falls back to USB. The only
supported pinned device is the tested iPad14,3 (iPad Pro 11-inch, fourth gen).
The caller creates an owner-only output directory (0700), and supplies a new
file path per request. Existing output paths, including symlinks, are rejected
and left untouched. On other failures no output image is published.

stdout contains exactly one compact JSON object, never raw exceptions, keys,
device IDs, IP addresses, or paths. Success includes:
  schema_version: 1
  request_id: exact canonical UUID supplied by caller
  ok: true
  reason: "captured"
  request_started_monotonic, request_completed_monotonic
  capture_started_monotonic, capture_completed_monotonic
  width, height, bytes, sha256
  transport: "authenticated_wifi", source: "DVT_takeScreenshot"
  device_frame_timestamp_available: false, lock_state_verified: false
Success exits 0. Failures exit 1 with ok=false and an allowlisted reason.
The caller must require matching request_id, success exit, valid dimensions and
hash, and delete its private output after completing or aborting insertion.

--timeout is a total request budget, from 4 to 45 seconds. Work is cancelled
three seconds before that deadline; the supervisor can terminate/kill a stuck
worker. Normal exit/cancellation closes DNS-SD, RSD and tunnel context managers.
SIGTERM cleans up the worker within the native app's one-second grace period
in the synthetic cancellation test. A parent-death watchdog also stops a worker
if its supervisor is forcibly killed. The native app should clean its own
private request directory if it had to SIGKILL the backend.
Every request starts a fresh worker and calls takeScreenshot once. There is no
prior-image cache, retry of an old PNG, full-time recording, or streaming save.
The response is rejected if its RPC takes more than 5 seconds, if it predates
this request, or if cleanup delays publication more than 5 seconds after capture.
Portrait 1668x2388 and landscape 2388x1668 PNGs are accepted without image edits.
Malformed, transparent, unexpectedly sized and near-uniform-black PNGs fail.

Limits still requiring honest user/device validation:
- Device-side frame timestamp is unavailable; a new RPC cannot independently
  prove the exact keypress instant or exclude every device-internal stale frame.
- Reliable lock-state API is unavailable on this tested iPadOS. Unlock before
  use. A nonblack lock screen cannot be reliably distinguished from app content.
- Protected content can appear partly black: a global black-frame test cannot
  identify all protected subregions. It is not a protected-content detector.
- Device restart/DDI remount, prolonged idle, Wi-Fi loss, and every failure mode
  have not been tested end to end in the new app. No OS upgrade was done.
- Force-killing any process can prevent its third-party cleanup routines from
  running, though all sockets close with the worker. Parent-owned image scratch
  directories are removed after normal/cancelled/timeout requests.

Verification (no network, device, clipboard or application UI used):
  python -m unittest discover -s tests -v
Tests use synthetic white/black PNGs and placeholder pairing files. These are
not a substitute for end-to-end testing with the native companion app.
The pre-service33-test suite passed on 2026-10-15, including synthetic SIGTERM, parent SIGKILL,
no-overwrite, timestamps, portrait/landscape, black frames, exception redaction,
private permissions, cryptographic proofs and mocked DNS-SD cancellation.

Source-only performance update (not yet device-timed): when the SAME matching
service supplies both LAN IPv4 and IPv6 and the DNS-SD batch is complete,
discovery settles for50ms instead of350ms. Single-family discovery keeps350ms;
unfiltered discovery keeps the full timeout. Equivalent candidate endpoints are
tried only once per request, retaining IPv4-first order and all peer/route proofs.
A synthetic completed-dual-stack benchmark measured median351.154ms before and
51.143ms after (three trials each). This demonstrates that wait reduction only;
it does not establish the new end-to-end speed on the user's hotspot/device.

Dependencies and attribution are in THIRD_PARTY_NOTICES.txt, the license folder
and requirements-tested.txt. No private pairing record or user screenshot is
included in this source folder.
