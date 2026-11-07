# DGGTV: Destiny.gg on Apple TV

An unofficial fan project, not affiliated with destiny.gg. Still in development, with no builds to install yet. For iPhone, see [DGG](https://github.com/murdrd00/dgg-ios).

![The embed list and chat](docs/home.png)

![Watching a stream with chat over the video](docs/stream.png)

The screenshots are staged with sample chat and viewer counts.

## Signing In

Create a Login Key on destiny.gg under Profile, then Developer, and paste it in Settings. It stays in your Apple TV's Keychain and is only sent to destiny.gg chat. Treat it like a password.

DGGTV can't post in chat. The only thing it ever sends is a poll vote you choose.

## Development

Shared code is in the `DGGKit` package under `Sources`, and the app is in `App/DGGTV`. Run `xcodegen` after adding app files. [NOTES.md](NOTES.md) has the longer story.
