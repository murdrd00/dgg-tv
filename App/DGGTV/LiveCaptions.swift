import AVFoundation
import Observation
import OSLog
import Speech

/// Captions for live streams, transcribed on the Apple TV itself.
///
/// tvOS has no system captions for streams that don't carry their own, and
/// AVPlayer won't share a live stream's audio. So this fetches the stream's
/// smallest rendition alongside AVPlayer, takes the AAC out of the segments,
/// and runs it through Apple's on-device `SpeechTranscriber`. Each segment's
/// `EXT-X-PROGRAM-DATE-TIME` puts every word on the wall clock, so a word
/// shows when the picture reaches the moment it was said. The fetch runs ahead
/// of playback, which gives the transcriber time to catch up.
@MainActor
@Observable
final class LiveCaptions {
    private static let log = Logger(subsystem: "DGGTV", category: "captions")

    enum Status: Equatable {
        case off
        /// This Apple TV, or the language, isn't supported.
        case unsupported
        /// Fetching the language model, the first time.
        case downloading
        case running
        case failed
    }

    struct Word: Equatable {
        let text: String
        let at: Date
    }

    private(set) var status: Status = .off
    private(set) var words: [Word] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// `playhead` gives the wall-clock time of the frame on screen, so the fetch
    /// can start where playback is.
    func start(master: URL, playhead: @escaping @MainActor () -> Date?) {
        stop()
        generation += 1
        let gen = generation
        status = .downloading
        task = Task { [weak self] in
            await self?.run(master: master, playhead: playhead, gen: gen)
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        words = []
        if status != .unsupported { status = .off }
    }

    /// What to show at this moment: the words said in the last few seconds, as
    /// much as fits in two lines. Nothing after a pause, like broadcast captions.
    func text(at now: Date) -> String? {
        let said = words.filter { $0.at <= now }
        guard let last = said.last, now.timeIntervalSince(last.at) < 3.5 else { return nil }
        var out: [String] = []
        var length = 0
        for word in said.reversed() {
            guard last.at.timeIntervalSince(word.at) < 8, length + word.text.count < 84 else { break }
            out.append(word.text)
            length += word.text.count + 1
        }
        return out.reversed().joined(separator: " ")
    }

    // MARK: - Pipeline

    private func run(master: URL, playhead: @escaping @MainActor () -> Date?, gen: Int) async {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            Self.log.notice("transcription isn't available here")
            if gen == generation { status = .unsupported }
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.audioTimeRange])
        do {
            if await AssetInventory.status(forModules: [transcriber]) < .installed,
               let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Self.log.notice("downloading the speech model")
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw URLError(.cannotDecodeContentData)
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            guard gen == generation, !Task.isCancelled else { return }

            let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let origin = OriginBox()
            try await analyzer.start(inputSequence: input)
            status = .running
            Self.log.notice("captions running, \(format.sampleRate) Hz")

            let fetch = Task.detached(priority: .utility) {
                await Self.fetch(master: master, playhead: playhead, format: format,
                                 origin: origin, feed: feed)
            }
            defer {
                fetch.cancel()
                feed.finish()
            }
            for try await result in transcriber.results {
                guard gen == generation, !Task.isCancelled else { break }
                take(result, origin: origin.date)
            }
            await analyzer.cancelAndFinishNow()
        } catch {
            Self.log.error("captions stopped: \(error.localizedDescription)")
            if gen == generation, !Task.isCancelled { status = .failed }
        }
    }

    /// A newer result covers the words of anything it overlaps, volatile or not.
    private func take(_ result: SpeechTranscriber.Result, origin: Date?) {
        guard let origin else { return }
        let from = origin.addingTimeInterval(result.range.start.seconds)
        var fresh: [Word] = []
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = run.audioTimeRange?.start.seconds ?? result.range.start.seconds
            for piece in text.split(separator: " ") {
                fresh.append(Word(text: String(piece), at: origin.addingTimeInterval(start)))
            }
        }
        let keepAfter = Date().addingTimeInterval(-60)
        words = words.filter { $0.at < from && $0.at > keepAfter } + fresh
    }

    /// Wall-clock time of the first audio fed in, which is zero on the
    /// analyzer's timeline.
    private final class OriginBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date?
        var date: Date? { lock.withLock { value } }
        func setIfEmpty(_ d: Date) -> Date { lock.withLock { value = value ?? d; return value! } }
    }

    // MARK: - Fetching

    private struct Segment {
        let url: URL
        let duration: Double
        let date: Date?
        let sequence: Int
    }

    private nonisolated static let dates: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime]
        return [a, b]
    }()

    private nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private nonisolated static func text(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return String(decoding: data, as: UTF8.self)
    }

    /// The smallest rendition: an audio-only one where there is one (Twitch),
    /// otherwise the lowest. Speech needs little.
    private nonisolated static func smallest(_ master: URL) async throws -> URL {
        let body = try await text(master)
        guard body.contains("#EXT-X-STREAM-INF") else { return master }
        var best: (url: URL, bandwidth: Double, audio: Bool)?
        var info: String?
        for line in body.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                info = line
            } else if let i = info, !line.isEmpty, !line.hasPrefix("#"),
                      let url = URL(string: line, relativeTo: master)?.absoluteURL {
                let bw = i.range(of: "BANDWIDTH=").map { Double(i[$0.upperBound...].prefix { $0.isNumber }) ?? 0 } ?? 0
                let audio = i.contains("audio_only") || line.contains("audio_only")
                if best == nil || (audio && !best!.audio) || (audio == best!.audio && bw < best!.bandwidth) {
                    best = (url, bw, audio)
                }
                info = nil
            }
        }
        return best?.url ?? master
    }

    private nonisolated static func playlist(_ url: URL) async throws -> (segments: [Segment], target: Double) {
        let body = try await text(url)
        var sequence = 0
        var target = 2.0
        var duration: Double?
        var date: Date?
        var segments: [Segment] = []
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst(22)) ?? 0
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                target = Double(line.dropFirst(22)) ?? target
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                let s = String(line.dropFirst(25))
                date = dates.lazy.compactMap { $0.date(from: s) }.first
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).prefix { $0 != "," })
            } else if !line.isEmpty, !line.hasPrefix("#"), let d = duration,
                      let u = URL(string: line, relativeTo: url)?.absoluteURL {
                segments.append(Segment(url: u, duration: d, date: date,
                                        sequence: sequence + segments.count))
                // Dates carry on from the last tag where a segment has none.
                date = date?.addingTimeInterval(d)
                duration = nil
            }
        }
        return (segments, target)
    }

    private nonisolated static func fetch(master: URL, playhead: @escaping @MainActor () -> Date?,
                                          format: AVAudioFormat, origin: OriginBox,
                                          feed: AsyncStream<AnalyzerInput>.Continuation) async {
        var media: URL?
        var next: Int?
        var decoder: AACDecoder?
        var converter: AVAudioConverter?
        var failures = 0
        while !Task.isCancelled {
            do {
                if media == nil { media = try await smallest(master) }
                let list = try await playlist(media!)
                failures = 0
                guard let first = list.segments.first, let last = list.segments.last else {
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                if next == nil || next! < first.sequence || next! > last.sequence + 1 {
                    // Start at what's on screen, a moment before, so the first
                    // words are ready when it gets there.
                    let now = await playhead()?.addingTimeInterval(-1)
                    let at = now.flatMap { n in list.segments.last { ($0.date ?? .distantFuture) <= n } }
                    next = at?.sequence ?? list.segments[max(0, list.segments.count - 2)].sequence
                }
                var fetched = false
                for segment in list.segments where segment.sequence >= next! {
                    guard !Task.isCancelled else { return }
                    let (data, _) = try await session.data(from: segment.url)
                    next = segment.sequence + 1
                    fetched = true
                    let frames = ADTS.frames(in: TransportStream.audio(in: data))
                    guard let config = frames.first?.config, let date = segment.date else { continue }
                    if decoder == nil || decoder?.matches(config) == false {
                        decoder = try AACDecoder(config: config)
                        converter = AVAudioConverter(from: decoder!.output, to: format)
                    }
                    guard let pcm = try decoder?.decode(frames), let converter,
                          let speech = convert(pcm, with: converter, to: format) else { continue }
                    let zero = origin.setIfEmpty(date)
                    let start = CMTime(seconds: date.timeIntervalSince(zero), preferredTimescale: 1000)
                    feed.yield(AnalyzerInput(buffer: speech, bufferStartTime: start))
                }
                if !fetched { try await Task.sleep(for: .seconds(max(0.5, list.target / 2))) }
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                if failures % 5 == 0 { media = nil }
                try? await Task.sleep(for: .seconds(min(Double(failures), 5)))
            }
        }
    }

    /// Stereo 48 kHz float to whatever the transcriber wants, usually mono 16 kHz.
    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var handed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if handed {
                state.pointee = .noDataNow
                return nil
            }
            handed = true
            state.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}
