# DGGTV

destiny.gg bigscreen as a native tvOS app: chat on the right, the current
embed playing full-screen, left/right on the remote to switch embeds.

## Why it isn't a web wrapper

tvOS has no web view. Apple's own docs list `WKWebView` for iOS, iPadOS,
Mac Catalyst, macOS and visionOS — tvOS is absent, and always has been.
JavaScriptCore *is* present, but the rendering engine is not, so the site
can't be loaded. Everything here is rebuilt natively.

## Layout

- `Sources/DGGKit/` — platform-agnostic core, shared by the app and the CLI
- `Sources/dggprobe/` — terminal harness, runs the core without Xcode
- `App/DGGTV/` — tvOS SwiftUI layer
- `project.yml` — xcodegen input for the tvOS target

## Verified facts (probed live, not assumed)

| Thing | Value |
|---|---|
| Chat socket | `wss://chat.destiny.gg/ws`, needs an `Origin` header |
| Frame format | `VERB {json}` — `MSG`, `NAMES`, `BROADCAST`, `JOIN`, `QUIT`, `ERR` |
| Verbs seen live | MSG, NAMES, HISTORY, UPDATEUSER, PIN, SPOTLIGHT, SPOTLIGHTS, PAIDEVENTS, ME |
| **Embed source** | every user object carries `watching: {platform, id}` |
| HISTORY | array of raw `MSG {...}` strings, replayed on connect |
| Read-only auth | none required; sending needs an `authtoken` cookie |
| Emotes | `https://cdn.destiny.gg/emotes/emotes.json` (75 KB) |
| Flairs | `https://cdn.destiny.gg/flairs/flairs.json` (13 KB) |
| Embed tokens | `#twitch/x`, `#kick/x`, `#youtube/<id>`, `#kick-vod/<chan>/<uuid>` |
| Chat volume | ~416 messages/minute |
| Embed mentions | rare — 0 typed in a 60s window, so don't rely on them |
| flairs.json | entry [34] ships `"url": null` — decode leniently or lose all 46 |

## How the embed list really works

Chatters typing `#kick/x` is **not** the mechanism — that happens only every few
minutes. Every user object instead carries what they are currently watching:

```json
"watching": {"platform": "kick", "id": "dariusirl"}
```

`NAMES` delivers this for every connected user the moment the socket opens, and
`UPDATEUSER` + every `MSG` keep it fresh. So the embed list is ranked by actual
viewer count, exactly like the site, and is populated instantly on launch.
`EmbedTracker` keeps one vote per nick, so switching moves a vote instead of
double-counting.

## Playback

Resolved to real HLS and checked the playlist parses, from Swift, no server:

- **Twitch** — GQL `PlaybackAccessToken` then `usher.ttvnw.net`.
  Returns a master playlist: 1920x1080 / 1280x720 / 852x480 / 640x360 / 284x160,
  so AVPlayer does its own bitrate adaptation.
- **Kick** — `kick.com/api/v2/channels/<slug>` → `playback_url`.
  Cloudflare did **not** block it with a Safari User-Agent. Treat as fragile.
- **YouTube** — not played in this app. Not DRM, but signature/`n`-param JS
  plus attestation. `yt-dlp` resolves it fine. Home opens these in the YouTube
  app instead, after asking.

### Opening YouTube

`youtube://www.youtube.com/watch?v=<id>` opens the exact video in the tvOS
YouTube app, including live streams (tested on hardware). No
`LSApplicationQueriesSchemes` entry is needed because the app just attempts the
open and handles failure.

Opening YouTube only happens from the embed screen. A long-press menu on Home for
native apps was removed: Kick's app takes `kicktv://` but no path reaches a channel,
and Twitch's tvOS app answered none of 22 scheme guesses, nor `https://twitch.tv/...`
links, so nothing can open it from here. In the player, YouTube embeds stay in the bar and left/right
stepping, and landing on one shows a short explanation and an "Open in YouTube"
button. That button is only drawn: focus stays on the player and Select opens
YouTube. A real `Button` would take focus and swallow left/right, trapping you
on that embed.

Embeds arrive as bare video ids. The names come from YouTube's public oEmbed
endpoint, `/oembed?url=...&format=json`, which needs no key, once per video.

The YouTube screen sits on the video's thumbnail, `maxresdefault_live.jpg` with
`hqdefault_live.jpg` as the fallback. It's downloaded before it's shown and stays
up until something replaces it. Treat it as cover art, not a fresh frame.

Every backdrop gets the same `LightBlur`: a `UIVisualEffectView` whose blur is
animated in and paused at 10%, because a blur effect has no strength setting and
SwiftUI's `.blur` left video layers black.

Panels use the same blur through `glassPanel`, not Liquid Glass. Profiled on a
2nd-generation Apple TV 4K with Animation Hitches, two Liquid Glass panels over
moving video lost about 830ms of every second (around 10fps), all of it GPU work.
The full-screen blur alone cost almost nothing, so the panels moved onto it.

If playing YouTube in-app is ever revisited: `googlevideo` URLs embed the
requesting IP (`/ip/<address>`) with a ~6 hour expiry, so a URL resolved on
a remote server won't play on the Apple TV. Resolving would have to happen on
the same network, proxying the bytes rather than handing over the URL. Twitch
and Kick URLs carry no `/ip/` binding.

## Embed coverage (tested live against all 12 in the list)

| Platform | Result |
|---|---|
| Kick, live | works — 5 variants (1080p→160p) |
| Twitch, live | works — 5 variants |
| YouTube | opens in the YouTube app |
| Kick, OFFLINE | see below |

**Kick returns a `playback_url` for offline channels too.** Fetching it 404s
with a 34-byte body, which showed up in the app as a silent black screen with
no error. `KickResolver` now checks `livestream.is_live` and throws `.offline`.
Four of twelve embeds were offline channels, so this was not an edge case.

Re-run this any time with `dggprobe embeds` — it pulls the live list off the
socket and tries to resolve every entry.

## Platform icons

Marks come from destiny.gg's own inline SVG, drawn via a small path parser —
but the **arc** conversion in `SVGShape` is unreliable. YouTube's rounded
corners are arcs and came out visibly deformed, so YouTube and Rumble are
built from SwiftUI primitives instead. Twitch and Kick are straight-line
paths and render fine through the parser.

Fills use **even-odd**: these marks carve holes out of a solid body (the
YouTube triangle, the Twitch eyes) which the non-zero rule fills in solid.

Vimeo still goes through the arc code and may be wrong; it is rarely used.

## Screens

The app opens on **Home**: the embed list on the left, chat on the right.
Picking an embed starts watching; **Menu** returns to the list and re-checks
it. Nothing is auto-selected at launch any more.

The list re-ranks continuously from chat's `watching` data and re-checks
liveness every 25s, plus a manual **Refresh** in the header. Liveness is also
checked the moment `NAMES` arrives, so the list doesn't show dead channels as
live for the first few seconds.

With hide-offline on, only CONFIRMED-live entries are listed. Showing
unverified ones made channels appear and then vanish a second later once their
check came back. Before the very first check completes everything is shown,
so the list is never empty.

Chat can sit on either side, in two styles:
- **Overlay** — floats over the video (default)
- **Pinned** — the video shrinks beside an opaque chat column

`onMoveCommand` bubbles up from whatever is focused, so a handler on the ROOT
fires on every screen. The home screen's arrow keys were reaching the player's
embed-stepping handler and starting playback for something never selected —
audio with nothing on screen. A root `onExitCommand` is worse: even guarded, it
swallows Menu, so the app can't be backed out of. Player-only handlers live on
the player view, so on Home they don't exist at all.

Leaving the player stops the stream (`stopPlayback`). It used to keep running,
with its audio playing behind the list.

Home has a gradient backdrop because Liquid Glass only exists as a response to
what is behind it. On flat black the chat panel reads as a grey box.

Home and the player are one continuous screen (`stage`, `chatLayer`, then the
list or the player controls), not two. Highlighting a row plays that stream
muted at low bitrate behind two glass panels, half a second after focus settles so
sweeping past rows loads none of them. Select only turns the sound and quality
up, so entering never reloads, and Menu does the reverse. There are two players
taking turns: the next stream loads underneath while the current keeps playing,
and the current one fades out once the next has a frame to show. Both stay fully
opaque throughout, as a hidden player may not decode. So nothing shows through
between streams, and the gradient only appears if a stream can't load. Chat is one view that
changes shape between panel and pinned column. A preview left alone stops after
5 minutes, and "Preview on Home" in Settings turns the whole thing off.

The gradient drifts slowly behind all this: its colours stay put and the mesh
points wander, at 20fps at most. It rests whenever there's a picture.

The screensaver is held off only while a stream is playing and open, not on Home.

Each Home row shows the stream title beside the name. Kick's comes from the
channel request the liveness check already makes, Twitch's from a small GQL
query in the same check, so both update every 25s. YouTube's comes with the
one-off oEmbed lookup.

A screen whose content arrives asynchronously must CLAIM focus when it
arrives. Until the list loads there is nothing focusable, so tvOS has nowhere
to put focus and the screen appears dead — the same trap as the settings
panel. Once the header has buttons, tvOS parks focus on those instead, so the
list takes focus once when it arrives. Returning from the player puts focus
back on the embed you left.

## Remote controls

| Button | Action |
|---|---|
| Left / Right | previous / next embed (video cuts immediately) |
| Swipe left / right | switch embeds — the bubble tracks your thumb, then snaps |
| Swipe up / down | scroll chat, paused while your thumb stays down; returns to live 0.5s after you let go |
| Click up / down | scroll chat 6 lines; returns to live after 5s |
| Select | show or hide the embed bar; on a YouTube embed, open it in YouTube |
| Hold Select (Home) | watch in the native app |
| Play-Pause | open Settings (also the gear on Home) |
| Menu | close Settings, or leave the player; on Home, quit to tvOS |

Chat visibility moved into Settings, so Up/Down no longer toggles it.

Play-Pause is the settings button because a live stream has nothing to pause —
the same reason the scrubber was removed.

The embed bar auto-hides after a configurable delay (default 4s) and returns on
left/right or Select. It shows a window of 5 that follows the selection, so stepping past
the end slides the list instead of stranding the highlight off-screen; the
highlight itself is a single `matchedGeometryEffect` capsule that glides
between pills.

## App icon

Built from the square D mark (the wordmark is unreadable at tvOS's 5:3 icon
proportions). The glyph is keyed off its near-black tile, keeping the white
letterform and both blue wedges.

tvOS icons are **layered image stacks**, not flat images — the layers
parallax when the icon is focused. `App Icon.imagestack` has:

- `Back.imagestacklayer` — gradient, diagonal sheen, vignette, lit top rim
- `Front.imagestacklayer` — the glyph with its brand halo and drop shadow

Artwork is sized to FIT A BOX, not scaled by width. The D is square and the
icon is 400x240, so taking a fraction of the width made it taller than the
tile and it filled the whole icon. `mark_layer(art, W, H, wFrac, hFrac)` takes
`min` of both constraints, which suits the square mark and the wide wordmark
alike.

No lit top rim. It looked like a glass edge on a small tile but became a hard
white hairline once tvOS enlarged the icon or stretched the top shelf across
the screen — heavier than anything Apple ships.

The top shelf uses the full WORDMARK at ~26% width, not the square mark. Its
source already has an alpha channel: converting to RGB first turns the
transparent background black, and keying that out then destroys the artwork's
own black outline.

Alternatives are kept in `icon-options/`; the palette lives in `STOPS`.

## Settings

Laid out like the tvOS Settings app: an explanatory panel on the LEFT that
follows focus, compact grouped rows on the RIGHT.

**Chat**
- Show chat
- Darken other embeds' chat — every line carries `watching`, so lines about
  something else can be dimmed, as on destiny.gg
- Width

**Account**
- DGG account — a Login Key from the site's Developer page, kept in the Keychain
  and sent to chat as the `authtoken` cookie. Chat answers with `ME`: your user
  when it accepts the key, `null` when it doesn't, in which case you stay a guest.
  `ChatClient` can't post a message on purpose. Its only send is `vote(option:)`.

The pinned message (`PIN`, sent on connecting) sits at the top of chat. In the
player, up highlights it and Select hides it, leaving a small pin button at the top
right that brings it back the same way. Hiding is remembered by `uuid`, so a new
pin always shows, as on the site. Clicks never scroll chat, only swipes do, and the
highlight lets go after 5 seconds.

Polls appear at the top of chat (`POLLSTART`, `VOTECAST`, `VOTECOUNTED`,
`POLLSTOP`). In the player, up and down click through the pin and options, and Select sends
`CASTVOTE`; swipes still scroll chat. Nothing is highlighted to begin with, so a
Select meant for something else can't vote. `DGGTV_TEST_POLL=1` (or `hidden`) plays
a made-up poll through the real parser in debug builds, and its votes go nowhere.

**Embeds**
- Hide offline channels
- Bar auto-hide delay

Everything here is saved in `UserDefaults` as it changes and restored at launch
(`Saved` in `BigscreenViewModel.swift`; Show chat uses `@AppStorage`, same
store). A missing or unreadable value falls back to its default. Reading the
store with `simctl spawn defaults read` finds nothing because the app is
sandboxed, so check persistence by killing and relaunching the app.

**Focused rows need room INSIDE the `List`.**

tvOS enlarges a focused row, and a `List` clips to its own bounds, so rows that
span its full width get their sides sliced off. That was the real cause of rows
"bursting out of their box". Removing the rounded panel didn't fix it, and
neither did padding around the `List`, because padding moves the clip edge along
with it. `focusRoom()` adds the margin with `safeAreaPadding`, on all four sides:
the first row grows into the top edge the same way. `contentMargins` looks like
the right tool but on tvOS only shifts rows without narrowing them, which pushes
them off the far side.

**Every row is a `Button` with the same layout.** That gives one height and the
native focus highlight everywhere. A `Toggle` row is taller than a `Button` row,
and a `.focusable()` row gets no highlight at all.

`Slider` does not exist on tvOS, so `SliderRow` is a `Button` too. A `Button`
never receives `onMoveCommand`, so `RemoteTouchSurface` puts recognisers for
left/right clicks and the horizontal pan on the WINDOW while the row is focused.
Select does nothing on these rows. A swipe moves in whole steps, `swipePerStep` points
each, the same for every row. That constant is the one to tune for feel, and
only on hardware: the simulator rejects touch input on Apple TV.

The pan claims only HORIZONTAL gestures: claiming both axes swallows what the
focus engine needs.

The panel sits on `.ultraThinMaterial` rather than a flat scrim — dimming
alone leaves high-contrast video motion fighting the text.

**Settings must be a modal.** As an overlay inside the main focusable `ZStack`
it never received focus — nothing highlighted and Select did nothing.
`.fullScreenCover` gives it its own focus environment.

## Remote input

`onMoveCommand` only reports a discrete step AFTER a swipe finishes, which made
switching feel like a jump cut with the animation trailing behind. The Siri
Remote delivers indirect touches, so `RemoteTouchSurface` uses a
`UIPanGestureRecognizer` (`allowedTouchTypes = [.indirect]`) to report live
translation. Its recognisers go on the window while it is mounted, because
remote input follows focus rather than screen position. So it must be unmounted
when it shouldn't apply: the player's surface is removed while Settings is open,
or its vertical pan would take the swipes that move between rows.

While chat is scrolled back, new lines wait in `pending` rather than being
added, so the text you're reading holds still and trimming can't move it. The
rail shows "Paused · N new". Position is tracked by line, not index, because
trimming shifts every index. Chat scrolling by swipe can't be exercised in the
simulator; up/down clicks run the same code apart from the pan itself.

## Latency counter

Optional, set in Settings, in any corner of the picture. `AVPlayerItem.currentDate()`
gives the wall-clock time of the frame on screen from the stream's
`EXT-X-PROGRAM-DATE-TIME` tags, so `now - currentDate()` is real delay. Kick
streams carry the tags (checked on live playlists). A stream without them shows
a dash, as does anything buffering.

The number sitting perfectly still is correct: the playhead advances in real
time, so the gap only moves when playback stalls or the player jumps. A
wall-clock readout beside it confirmed this. Expect about three segments of delay,
so a 6s-segment Kick channel reads around 16s and a 2s-segment one much less.

## No playback controls

Live streams have nothing to seek to, so `VideoPlayer` (which always brings
AVKit's scrubber and Now Playing UI) is not used. `LivePlayerView` wraps an
`AVPlayerLayer` directly — picture only.

## AVPlayer pitfalls hit here

Three separate things each caused "video never plays", and they look identical
on screen (a spinner and a frozen frame):

1. **Never build an `AVPlayer` inside `body`.**
   `VideoPlayer(player: AVPlayer(url: url))` makes a NEW player on every
   redraw. Chat redraws many times a second, so the stream restarted buffering
   forever. Hold one player for the app's lifetime and call
   `replaceCurrentItem(with:)`.

2. **Leave `automaticallyWaitsToMinimizeStalling` alone (true).**
   Setting it false looks right for live — start sooner — but it begins
   playback before enough is buffered. On a slow decoder it stalls instantly
   and never recovers: the playhead freezes a few seconds in while AVKit keeps
   logging the same `currentTimeInterval` every 50ms.

3. **The tvOS simulator decodes in software** and cannot sustain 1080p60.
   `preferredPeakBitRate` is capped under `#if targetEnvironment(simulator)`
   only — real hardware stays uncapped so AVPlayer picks the best rendition.

To tell a stall from a slow stream, take screenshots ~0.5s apart and diff the
video region; a frozen player reads exactly 0.00% every time. The log line
`[AVKit] currentTimeInterval:` repeating one value is the same signal.

## Testing in the simulator

The Apple TV 4K (4th gen) simulator on tvOS 27.2 DOES render video, though
software decoding can leave it black for a while after picking a stream. Older
runtimes showed a black frame with working audio, even for Apple's reference
stream, so that was not a bug in this app. To check with a known-good stream:

```sh
xcrun simctl launch <udid> com.murdrd.DGGTV \
  --env DGGTV_TEST_STREAM=https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8
```

Arrow keys and Select can be injected, but Menu, Play-Pause and swipes can't.
Set `DGGTV_SILENT` in the launch environment (`SIMCTL_CHILD_DGGTV_SILENT=1`) to
test with no sound. `DGGTV_TEST_LINES="nick#flair:message|..."` injects chat
lines, and `DGGTV_TEST_REPEAT=n` repeats them.

Debug builds stand in for the two buttons with `DebugRemote`, which runs the
same actions as the real ones:

```sh
xcrun simctl spawn <udid> notifyutil -p com.murdrd.dggtv.debug.menu
xcrun simctl spawn <udid> notifyutil -p com.murdrd.dggtv.debug.playpause
```

Wait a second or so after a key press before taking a screenshot, or it catches
focus before it has moved.

## OPEN BUG (simulator?): stray emote images

Emote images draw a second time, far to the LEFT of the chat rail, at the same
y as their line. Ruled out by testing each:

- not the video layer — persists with `DGGTV_NO_VIDEO=1` and no `VideoPlayer`
- not rail clipping — persists after `.clipShape` on the rail
- not `.baselineOffset` — persists without it
- not row width — persists with an explicit `maxWidth` cap
- not SwiftUI `Text(Image(uiImage:))` — persists after moving the whole row to
  UIKit `NSTextAttachment` layout

Disabling emote images is the ONLY thing that removes them, so it tracks with
the images existing rather than with how they are rendered. Every observation
so far is from the tvOS simulator, which is independently proven unable to
render video at all — so this may be a simulator compositing artifact and not
a real defect. **Confirm on hardware before investigating further.**

## Chat reconnection

DGG drops connections often, so `connect()` returns ONE long-lived stream that
survives reconnects and keeps yielding events; callers never re-subscribe.

Three things this had to get right:

1. **Never trust the open delegate for status.** `didOpenWithProtocol` is not
   always delivered — the UI sat on "connecting…" while messages were visibly
   arriving. Incoming traffic is the proof of being connected, so the state
   flips on the first frame received.
2. **A socket can die silently.** URLSession reports it as fine while nothing
   arrives. A watchdog reconnects after `silenceTimeout` (45s) of no traffic;
   at ~400 msg/min, silence means death, not a quiet room.
3. **Guard against the dead socket's last callback.** A cancelled task still
   delivers one failure afterwards. Without a generation counter that
   re-triggers the backoff, turning a ~2s recovery into ~16s.

Backoff is exponential with jitter, capped at 30s. Verify with
`dggprobe reconnect`, which forces a drop mid-stream and asserts recovery.

## Moderation

`MUTE` / `BAN` / `IPBAN` arrive with the MODERATOR in `nick` and the TARGET in
`data` (confirmed from the web client's own `cmdMUTE`, which sends
`{data: <nick>}`). The web client calls `removeMessageByNick`, so this app does
the same: a muted or banned user's messages are purged from the buffer. Before
this they fell into `unhandled` and stayed on screen forever.

## How emotes work

The site's `emotes.css` is effectively a program: about 2,600 rules and 290
keyframe animations, written against the page's DOM. Animation, secret variants
(`[data-username]`, `[...] + .msg-chat`), fusions (`:has()`), adjacency (`+`),
combo tiers (`[data-combo-group]`) and `::before` art all live there. tvOS has
no web engine, so `EmoteCSS.swift` is a small one: it parses the real sheet,
builds a model of each chat line, matches selectors the way a browser would, and
returns what to draw. New and changed emotes need no code.

`:hover` rules are dropped, since a TV can't hover.

**Rendering.** Each emote is a Core Animation layer laid over a blank gap in the
text (`EmoteLayer`). It plays on the GPU by itself: no timer, no redraws, and
offscreen rows just stop existing. Doing this through the text system is what
made emotes flash and vanish. Layout comes from the stylesheet, so art dropping
in later never rebuilds a line or restarts an animation.

- Sprite strips animate `contentsRect` across one image.
- GIF/APNG/AVIF sequences are unpacked into an atlas and played with each
  frame's own delay and the file's loop count.
- `transform`, `opacity`, `left` and `top` keyframes map to Core Animation.

**Looping.** On the site, finite animations just stop (catJAM plays twice).
Here anything repeating that doesn't hold its last frame loops for as long as
it's visible, and `forwards` animations play once and hold.

**Not reproduced:** `filter` (brightness, hue-rotate, drop-shadow),
`mask-image`, `clip-path`, blend modes and text in `content`. Core Animation has
no public equivalent on tvOS, so a few emotes lose an effect but still draw.

**Checking it:** `dggprobe css <emotes.css>` prints what the engine decides for
key cases, with no app or simulator needed.

Two things that look like bugs but match the live stylesheet: the "WWWWaiting
after jaydrvernanda" rule sits inside an unclosed comment, so browsers ignore it
too, and `TF` has no animation, just a crop of a three-part image.

## Emotes update themselves

Nothing emote-related is bundled. `emotes.json`, `emotes.css` and
`flairs.json` are fetched from the CDN at launch, and the stylesheet URL is
derived from the image URLs, so DGG's version bumps (`4.68.0/…`) are followed
automatically. New emotes appear without rebuilding the app — only a change to
the CSS *format* would need code.

They animate. The sheet is scaled ONCE to chat height and kept as a CGImage;
`AnimatedEmoteAttachment` crops the current frame while TextKit draws, which
is cheap because cropping a CGImage is a view onto existing pixels and the
frame size never changes — so redrawing never triggers re-layout.

**Chat lines must be cached** (`LineCache`). Chat redraws ~8x a second, and
rebuilding an `NSAttributedString` each time hands the text view a new object,
which makes TextKit tear down and rebuild its attachment views — animated
emotes appeared for a split second and vanished, over and over. The cache
returns the SAME instance, keyed by line id plus a generation counter that the
image store bumps when new artwork lands, so lines rebuild exactly once when
their emotes finish downloading.

This is why chat rows are a `UITextView` and not a `UILabel`: TextKit asks
each attachment for its image at draw time, while UILabel caches it.

## Combo pop

Each time the count ticks up the emote pops: grows over 70ms, settles back
over 170ms — the return is deliberately slower than the growth. Counts climb
faster than that completes, so the shrink is cancellable and every increment
restarts the grow mid-flight.

The row reserves the POPPED size at all times. `scaleEffect` doesn't affect
layout, but without the reserve the grown emote is clipped by its own row —
and reserving it guarantees chat never reflows while a combo is running.

## Emote combos

Combos span **messages**, not words within one. Consecutive messages that are
EXACTLY one emote — from any users — collapse into a single counter row with
no usernames:

```
Destiny: OMEGALUL
murdrd:  OMEGALUL      ->   [OMEGALUL]  x2
```

The counter escalates in colour (grey -> yellow -> orange -> red -> purple) and
picks up a bolt at x20.

A message like `OMEGALUL OMEGALUL OMEGALUL` is NOT a combo — it renders as a
normal message with three emotes, which is what the site does.

Not implemented: emote pairs that fuse into a third emote.

## Chat rendering

- Lines arrive ~400/min in bursts, so they are buffered and flushed to SwiftUI
  ~8x/second rather than per message.
- Line height is pinned via `NSParagraphStyle`. An emote attachment is taller
  than the text, so without it rows containing emotes sat further apart.
- `.defaultScrollAnchor(.bottom)` keeps the view pinned as content grows;
  `scrollTo` alone fires before layout settles, so a new line could render
  half-clipped until the next message arrived.
- `scrollTo` is NOT animated: an animated scroll restarting several times a
  second is what makes the text jump up and fall back.
- Trimming happens in chunks, not per append — removing a line changes content
  height and yanks the scroll position.
- `glassEffect` does **not** clip its children. Inline emote images escaped
  the chat rail and drew over the video at the same y as their line; the rail
  needs an explicit `.clipShape`.
- Emotes must live inside the same `Text` as the words so the line still wraps
  as one paragraph, and `Text` only accepts a concrete `Image` — not
  `AsyncImage` — so bitmaps are prefetched into `EmoteImageStore` first.

## Status

**Confirmed working on real hardware** — Apple TV 4K (2nd gen), tvOS 27.2.
Video renders and plays there; it never did in the simulator (see below).

Running:
- live chat with flair colours and badge icons
- embed list ranked by viewer count, populated on connect
- Kick and Twitch streams playing in AVPlayer, resolved on-device
- left/right switches embeds, up/down hides chat

Not done yet:
- **emote rendering** — emote text is not yet replaced with images
- **audio auto-levelling** — port the approach from `../compresstiny`
- **delay minimisation** — low-latency HLS tuning on AVPlayer
- **filter chat to the current embed** — easy now: every line carries
  `watching`, so hide lines whose `watching` != the selected embed
- **offline embeds** still appear in the list (they are ranked by viewers);
  selecting one now says "channel is offline" instead of going black. Could
  grey them out, or skip them when stepping with left/right.
- sending messages (needs a device-login flow for the session cookie)
- the stray-emote artifact has not been re-checked on hardware yet

Quality needs no work: `usher` returns a master playlist, so AVPlayer picks
the best rendition by itself.

## Build

```sh
sudo xcodebuild -license accept     # one time
xcodebuild -downloadPlatform tvOS   # ~8 GB, one time
swift build                         # core + CLI
./.build/debug/dggprobe chat 45     # watch live chat
./.build/debug/dggprobe resolve '#twitch/zackrawrr'
./.build/debug/dggprobe verbs 60    # dump every protocol verb
brew install xcodegen && xcodegen   # generate DGGTV.xcodeproj
```

## Kick latency

Measured on a 2nd-generation Apple TV 4K with `now - currentDate()`. AVPlayer alone
sat at about 15s on the TV (19s in the simulator). The same stream now runs at
about 1.5-3.7s for a streamer on a stable connection, and 5.6-8s on an IRL stream.

Kick is Amazon IVS. Its playlists have a 6s target, roughly 4s segments, and the next
segments as `EXT-X-PREFETCH`, which AVPlayer ignores. `LiveLoader` rewrites them.

- One prefetched segment listed as a normal segment. Two stalled constantly, because
  the second hasn't started and AVPlayer sits waiting on it.
- Target duration corrected to the real segment length.
- `BANDWIDTH` divided by 4. A segment still being produced arrives at real-time speed,
  which AVPlayer reads as a slow connection: 1080p fell to 360p. Bitrate caps have to
  be divided to match, which is what `peak()` does.

`LiveEdge` then keeps the buffer small, skipping forward at most every 15s, going by the
lowest point of the buffer because it saws up and down as segments land. How much
buffer to keep is the Low delay setting, and at Off the stream isn't rewritten at all.

What didn't work:
- `configuredTimeOffsetFromLive`: no effect on these streams.
- `player.rate` above 1: fine in the simulator, but it froze live streams on a real TV.
  Always test playback changes on hardware.

Darius-style IRL streams are poor test subjects: they freeze by themselves.

## The embed list

The list comes from `wss://live.destiny.gg`, the feed the site's Big Screen page uses
(`dggApi:embeds`). It has names, titles, live status and the watching count, and banned
or dead embeds are already gone. `EmbedTracker` works a list out from chat's `watching`
fields and is only the fallback now: it capped at 12 before filtering and needed its
own live checks, which dropped real embeds and made low-ranked ones flicker.
