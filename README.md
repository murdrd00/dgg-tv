# DGGTV: Destiny.gg on Apple TV

An unofficial fan project, not affiliated with destiny.gg.

A native tvOS app for [destiny.gg](https://www.destiny.gg). It shows the Big Screen embed list, plays streams, and displays live chat.

DGGTV is still in development, and there are no builds to install yet. For iPhone, see [DGG](https://github.com/murdrd00/dgg-ios).

![The DGG apps for Apple TV and iPhone](docs/showcase.jpg)

The apps at a glance. The chat, polls and viewer counts are staged, and CarPlay is a plan rather than something you can use yet.

![The embed list and chat](docs/home.png)

![Watching a stream with chat over the video](docs/stream.png)

The screenshots are staged with sample chat and viewer counts.

## Features

- The same embed list as the Big Screen page, with titles and viewer counts
- Kick and Twitch streams play in the app, previewing behind the list as you browse
- Low delay on Kick: a couple of seconds on a stable stream, adjustable in Settings
- Live chat with animated emotes, combos, flairs and greentext, as an overlay or beside the stream
- Sign in to vote in polls, and hide or show the pinned message
- YouTube embeds open in the YouTube app

DGGTV can't post in chat. The only thing it ever sends is a poll vote you choose.

## Signing In

1. On destiny.gg, go to Profile, then Developer, and click **Create Login Key**
2. In the app, open Settings, then **DGG account**
3. Paste the key using the Apple TV keyboard prompt on your iPhone

The key stays in your Apple TV's Keychain and is only sent to destiny.gg chat. Treat it like a password.

## Using the Remote

- **Swipe** left or right to switch embeds, and up or down to scroll chat
- **Click** up or down to pick a poll option or the pin, then **Select** to vote or hide it
- On Home, **click right** to reach chat
- **Play/Pause** opens Settings

## Development

The chat, emote and stream code is in the `DGGKit` package under `Sources`, and the app is in `App/DGGTV`. The Xcode project is generated from `project.yml`, so run `xcodegen` after adding app files.

[NOTES.md](NOTES.md) has the longer story of how everything works and why.
