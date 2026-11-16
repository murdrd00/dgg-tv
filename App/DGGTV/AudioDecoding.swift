import AVFoundation

// Copied from dgg-ios's AutoVolumePlayer.swift, where it plays audio itself for
// Auto volume. Here it feeds live captions. AVPlayer won't hand over a live
// stream's audio, so the app reads the segments itself.

// MARK: - MPEG-TS

/// Pulls the audio elementary stream out of a TS segment: every 188-byte packet
/// carrying the PID whose PES headers mark it as audio, headers removed.
enum TransportStream {
    static func audio(in data: Data) -> Data {
        var out = Data()
        var audioPID: Int?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 188 <= b.count {
                defer { i += 188 }
                guard b[i] == 0x47 else { continue }
                let start = b[i + 1] & 0x40 != 0
                let pid = Int(b[i + 1] & 0x1F) << 8 | Int(b[i + 2])
                let control = (b[i + 3] >> 4) & 0x3
                guard control & 0x1 != 0 else { continue }
                var p = i + 4
                if control & 0x2 != 0 { p += 1 + Int(b[i + 4]) }
                guard p < i + 188 else { continue }
                if start, p + 9 <= i + 188, b[p] == 0, b[p + 1] == 0, b[p + 2] == 1 {
                    let streamID = b[p + 3]
                    if (0xC0...0xDF).contains(streamID), audioPID == nil { audioPID = pid }
                    guard pid == audioPID else { continue }
                    p += 9 + Int(b[p + 8])
                    guard p <= i + 188 else { continue }
                } else if pid != audioPID {
                    continue
                }
                out.append(contentsOf: UnsafeBufferPointer(rebasing: b[p..<(i + 188)]))
            }
        }
        return out
    }
}

// MARK: - AAC

enum ADTS {
    struct Config: Equatable {
        let objectType: UInt8
        let frequencyIndex: UInt8
        let channels: UInt8
        var sampleRate: Double {
            let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000,
                                   22050, 16000, 12000, 11025, 8000, 7350]
            return Int(frequencyIndex) < rates.count ? rates[Int(frequencyIndex)] : 48000
        }
    }

    struct Frame {
        let config: Config
        let payload: Data
    }

    static func frames(in data: Data) -> [Frame] {
        var out: [Frame] = []
        let b = [UInt8](data)
        var i = 0
        while i + 7 <= b.count {
            guard b[i] == 0xFF, b[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
            let protectionAbsent = b[i + 1] & 0x01 == 1
            let header = protectionAbsent ? 7 : 9
            let length = (Int(b[i + 3] & 0x03) << 11) | (Int(b[i + 4]) << 3) | Int(b[i + 5] >> 5)
            guard length > header, i + length <= b.count else { break }
            let config = Config(objectType: (b[i + 2] >> 6) + 1,
                                frequencyIndex: (b[i + 2] >> 2) & 0x0F,
                                channels: ((b[i + 2] & 0x01) << 2) | (b[i + 3] >> 6))
            out.append(Frame(config: config, payload: Data(b[(i + header)..<(i + length)])))
            i += length
        }
        return out
    }
}

/// Raw AAC frames to float PCM. One decoder for the whole stream, so frames
/// carry on smoothly from one segment to the next.
final class AACDecoder {
    let output: AVAudioFormat
    private let input: AVAudioFormat
    private let converter: AVAudioConverter
    private let config: ADTS.Config

    init(config: ADTS.Config) throws {
        self.config = config
        var description = AudioStreamBasicDescription(
            mSampleRate: config.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(config.channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate,
                                         channels: AVAudioChannelCount(config.channels)),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw URLError(.cannotDecodeContentData)
        }
        // AudioSpecificConfig, which an ADTS header carries and raw frames don't.
        let asc = UInt16(config.objectType) << 11 | UInt16(config.frequencyIndex) << 7
            | UInt16(config.channels) << 3
        converter.magicCookie = Data([UInt8(asc >> 8), UInt8(asc & 0xFF)])
        self.input = input
        self.output = output
        self.converter = converter
    }

    func matches(_ other: ADTS.Config) -> Bool { other == config }

    func decode(_ frames: [ADTS.Frame]) throws -> AVAudioPCMBuffer? {
        guard !frames.isEmpty else { return nil }
        let total = frames.reduce(0) { $0 + $1.payload.count }
        let packets = AVAudioCompressedBuffer(format: input, packetCapacity: AVAudioPacketCount(frames.count),
                                              maximumPacketSize: max(total, 1))
        var offset = 0
        for (n, frame) in frames.enumerated() {
            frame.payload.withUnsafeBytes { src in
                packets.data.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: frame.payload.count)
            }
            packets.packetDescriptions![n] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(frame.payload.count))
            offset += frame.payload.count
        }
        packets.packetCount = AVAudioPacketCount(frames.count)
        packets.byteLength = UInt32(total)

        guard let pcm = AVAudioPCMBuffer(pcmFormat: output,
                                         frameCapacity: AVAudioFrameCount(frames.count * 1024)) else { return nil }
        var handed = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, state in
            if handed {
                state.pointee = .noDataNow
                return nil
            }
            handed = true
            state.pointee = .haveData
            return packets
        }
        if status == .error { throw error ?? URLError(.cannotDecodeContentData) }
        return pcm.frameLength > 0 ? pcm : nil
    }
}
