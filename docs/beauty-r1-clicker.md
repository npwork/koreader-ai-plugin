# Beauty-R1 page-turn remote

Page-turn mappings verified on the physical Kindle on 2026-10-24; lookup-closing
patch installed on 2026-10-25, pending a physical-button test. This setup is separate from
`aidict.koplugin`; the AI dictionary plugin did not need changes.

## Working configuration

| Item | Verified value |
| --- | --- |
| Kindle | Paperwhite 6 (2024 / 12th generation) |
| Firmware | 5.19.5 |
| Kernel | 5.15.41-lab126, ARMv7 userspace |
| KOReader | v2026.07.1 |
| Remote's Bluetooth name | Beauty-R1 |
| Connection | BLE HID, paired directly with the Kindle |
| HID transport | kindle-hid-passthrough v3.18.0 |
| Bundled Button Mapper | 1.7.5; generic mapping replaced by the adapter below |

| Physical button | Action |
| --- | --- |
| Large center button | Next page in the book; dismiss the top menu or dictionary/AI lookup without turning the page (patches below) |
| Separate small button | Previous page |
| Four arrows | No action |
| Other keyboard/media events from this remote | Discarded |

Both page buttons were verified on a real book. All four arrows were captured
and rejected by the final filter. The final process exclusively holds all three
remote input interfaces. Automatic recovery after a full Kindle reboot was
confirmed by the user on 2026-10-25. Sleep/wake and battery life remain untested.

## Closing a word lookup

The user patch `koreader/patches/2-beauty-r1-close-lookup.lua`
handles the center button's `GotoViewRel(1)` event while a normal dictionary
or AI definition popup is open. Both use `DictQuickLookup`. The patch calls
`onHoldClose()` to close the lookup stack and consumes the event, so the book
stays on the same page. The next center-button press turns the page normally.
Wikipedia popups and the previous-page event retain their existing behavior.

Restart **KOReader only** after installing the patch; no Kindle reboot is
needed. The patch loads automatically on subsequent KOReader starts. It is
separate from the AI plugin package and the remote's input adapter.
To undo it, remove the patch file and restart KOReader.

Checks passed using the Kindle's LuaJIT for event consumption, unchanged
previous-page and Wikipedia behavior, repeat loading, and preservation of an
existing handler. Activation after restart and the physical-button popup test
have not yet been confirmed by the user.

The patch is not included in this repository's package.

**Deferred:** reopening the last vocabulary word with the small button was
discussed but not implemented. The small button remains Previous Page; no
double-click action was added.

## Closing the top menu

The additional user patch
`koreader/patches/2-beauty-r1-close-menu.lua` handles `GotoViewRel(1)`
in `TouchMenu`, including the reader's top menu and its Network submenu.
It calls `closeMenu()` and consumes the event to avoid a page turn underneath.
Separate dialogs opened from a menu are not covered by this patch.
The small button retains its previous behavior.

Installed on 2026-10-25; restart KOReader to activate. Kindle LuaJIT checks
passed for close/event consumption, previous-event passthrough, preserving
existing handler arguments, and repeat loading. A physical-button test remains
pending. Remove the installed patch and
restart KOReader to undo it.

## Why a normal key mapping was insufficient

This unit presents three Linux input devices: `Beauty-R1` (touch/tablet),
`Beauty-R1 Keyboard`, and `Beauty-R1 Consumer Control`. Their event numbers
can change after reconnecting.

The center and small buttons both send `BTN_TOUCH` (330) and
`BTN_TOOL_PEN` (320). They differ by absolute touch position on a 0–1000
coordinate range:

- Center: approximately **(500, 450)**.
- Small: approximately **(501, 880)**.
- Arrows: moving strokes. Recorded starts were up (500, 208), right
  (768, 200), down (500, 768), left (112, 200), with travel exceeding 550 units.

Mapping code 320 directly to Next Page also catches other controls. Matching
only the Bluetooth address in the generic mapper selects the keyboard interface
with the most keys, rather than the touch interface needed here.

The custom `beauty-r1.lua` adapter matches this remote's Bluetooth identity,
grabs **all** its interfaces, and permits only stationary taps at the two known
positions. It allows x=490–510 and y=440–460 for Next, or y=870–890 for Previous.
Movement over 15 units, contact over 1.5 seconds, and duplicate taps within
250 ms are rejected. Keyboard and consumer-control events are drained without
forwarding them.

It acts on release, using coordinates observed while the contact was down:
the center button can reset Y to 180 in its release report. Repeated taps can
omit unchanged coordinates, so the adapter initializes axes with EVIOCGABS and
retains their state. It polls for input instead of continuously reading.

These observations describe this unit, not every remote sold as Beauty-R1.
Capture a different unit before copying the coordinate assumptions.

## Files on the Kindle

Storage paths below are relative to the Kindle USB storage root. Log and PID
filenames refer to the runtime temporary directory unless noted otherwise.

| Path | Purpose |
| --- | --- |
| `kindle_hid_passthrough/` | BLE transport runtime and saved pairing |
| `koreader/plugins/hidpassthrough.koplugin/` | BT Manager menu and KOReader event endpoint |
| `kindle-button-mapper/beauty-r1.lua` | Active custom adapter |
| `kindle-button-mapper/start-beauty-r1.sh` | Idempotent Bluetooth and adapter launcher |
| `koreader/patches/2-beauty-r1-startup.lua` | Start services with KOReader and reserve remote input for the adapter |
| `koreader/patches/2-beauty-r1-close-lookup.lua` | Close dictionary/AI lookup on the next-page event; loads on KOReader restart |
| `kindle-button-mapper/config.ini` | No generic device mappings; contains the endpoint-enabling marker |
| `kindle-button-mapper/config.before-small-button.ini` | Old center-only mapping, not the current configuration |
| `beauty-r1-adapter.log` | Adapter connection and NEXT/PREVIOUS delivery log |
| `beauty-r1-adapter.pid` | Current adapter PID |
| `beauty-r1-startup.log` | Startup launcher results |
| `hid_passthrough.log (system log directory)` | Bluetooth pairing/reconnection log |

The adapter source currently lives on the Kindle; it is **not shipped by this
repository's package**. Back it up from the device before replacing this setup.
Its `--self-test` checks next/previous taps, repeated coordinates, debounce,
swipe rejection, unknown positions, and the ARM input-event layout.
`--capture` logs classifications without turning pages.

The adapter sends requests only to the loopback endpoint
`http://127.0.0.1:8323/koreader/event/GotoViewRel/1` (next) or `/-1` (previous).
HTTP Inspector is not needed. The HID plugin starts this endpoint when the
mapper config contains `koreader.sh`; the current config retains that text in
an explanatory comment even though the generic mapper has no active mappings.
Preserve this marker or verify the plugin's endpoint lifecycle when updating.

## Automatic startup and recovery

The startup user patch starts the Bluetooth transport and custom adapter when
KOReader opens, including after a Kindle reboot. It does not start KOReader
itself or add a system boot service. Restart KOReader once after installation
to activate the patch.

Before plugins initialize, it excludes this remote from the external keyboard
and HID plugin input scans. Otherwise KOReader can claim the keyboard interface
before the adapter, allowing unused buttons through. Other keyboards retain
their normal handling. The filter also covers remote reconnections.

The launcher uses a process lock and existing-process checks to avoid duplicate
services. It starts the adapter first, then ensures the Bluetooth daemon is
running, including when its API is already available but Bluetooth is stopped.
Checks on the Kindle covered pre-initialization filtering, hotplug filtering,
unrelated keyboards, descriptor cleanup, repeat loading, duplicate prevention,
and recovery of a stopped adapter. A KOReader restart verified that the patch
loads, the launcher runs, and the adapter exclusively owns all three remote
interfaces. On 2026-10-25, the user confirmed both page buttons worked after a
full Kindle reboot and reopening KOReader, without manually starting services.

For manual recovery, run `sh kindle-button-mapper/start-beauty-r1.sh` from the
USB storage root. Inspect `beauty-r1-startup.log` and `beauty-r1-adapter.log`
in the runtime temporary directory. To disable automatic startup, remove
`koreader/patches/2-beauty-r1-startup.lua` and restart KOReader; already running
services must be stopped separately.

An empty mappings page is expected: the custom adapter handles the two buttons,
not the generic Button Mapper configuration.

Open a book in KOReader with HID Passthrough enabled. Its menu is
**Settings → Network → BT Manager – HID Passthrough**. The menu can manage
Bluetooth; this limited installation does not provide the generic mapper's
upstart service. Do not replace the custom adapter by starting the old
center-only mapper.

Check the adapter log for exclusive ownership of all three Beauty-R1
interfaces. After reconnection it scans for the new input nodes. An
`Input unavailable` / `Could not grab` message that persists indicates another
process owns an interface. Do not run another mapper against it simultaneously.

The runtime files, mapper files, KOReader plugin and lookup-closing user patch were installed.
No Bluetooth/mapper boot jobs, WAF home-screen apps or new udev rules were
installed; the root filesystem was verified read-only afterwards.
Recovery over USB was not verified during this setup.

The upstream project documents a PW6/5.19.5 full-install boot-loop incident.
The maintainer attributed it to leaving root writable after installer failure
and reported a fix. This is why the initial setup used a limited manual install.
See [issue 226](https://github.com/zampierilucas/kindle-hid-passthrough/issues/226)
before considering a full installation or boot services.
The replacement Bluetooth stack also occupies the radio while active, so
normal Kindle Bluetooth audio is unavailable then.

## Upstream references

- [HID Passthrough v3.18.0](https://github.com/zampierilucas/kindle-hid-passthrough/releases/tag/v3.18.0)
- [KOReader integration](https://github.com/zampierilucas/kindle-hid-passthrough/blob/v3.18.0/koreader-plugin/README.md)
- [Button Mapper](https://github.com/zampierilucas/kindle-button-mapper-rs)
