# DGGTV: Destiny.gg on Apple TV

A native tvOS app for [destiny.gg](https://www.destiny.gg). Browse the Big Screen embeds, watch streams, and follow chat from the couch, with the emotes, combos and flairs you'd see on the site.

## Features

- Every embed people are watching, with titles and live viewer counts
- Kick and Twitch streams play in the app, previewing behind the list as you browse
- YouTube embeds open in the YouTube app
- Live chat with animated emotes, combos, flairs and links, as an overlay or pinned beside the stream
- Sign in to vote in polls, and hide or show the pinned message
- A latency counter, plus settings for chat width, font size and side

DGGTV can't post in chat. The only thing it ever sends is a poll vote you choose.

## How to Install

DGGTV isn't on the App Store yet, so for now you build it yourself. You'll need a Mac with Xcode and an Apple TV running tvOS 26 or later.

1. Clone this repo and open `DGGTV.xcodeproj`
2. Under Signing & Capabilities, choose your own team
3. Pair your Apple TV in Xcode's Devices and Simulators window
4. Select your Apple TV and press Run

## Signing In

1. On destiny.gg, go to Profile, then Developer, and click **Create Login Key**
2. In the app, open Settings, then **DGG account**
3. Paste the key using the Apple TV keyboard prompt on your iPhone

The key stays in your Apple TV's Keychain and is only sent to destiny.gg chat. Treat it like a password.

## Using the Remote

| Button | Watching a stream | Home |
| --- | --- | --- |
| Left / Right | Switch embeds | Move to chat, or back to the list |
| Up / Down | Scroll chat, or pick a poll option or the pin | Move through the list, or through chat once you're there |
| Swipe up / down | Scroll chat | Move through the list |
| Select | Vote, hide the pin, or toggle the embed bar | Open an embed, or vote and hide the pin in chat |
| Hold Select | | Open in the YouTube app |
| Menu | Back to Home | Leave chat |
| Play/Pause | Settings | Settings |

## Development

The chat, emote and stream code lives in the `DGGKit` Swift package under `Sources`, and the app itself in `App/DGGTV`.

```bash
swift build
```

The Xcode project is generated from `project.yml`, so after adding files to the app, regenerate it:

```bash
xcodegen
```

[NOTES.md](NOTES.md) has the longer story of how everything works and why.
