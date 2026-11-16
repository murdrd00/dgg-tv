import SwiftUI
import CoreImage
import DGGKit

/// Laid out like the tvOS Settings app: an explanatory panel on the left that
/// follows focus, and compact grouped rows on the right.
/// Opened with play/pause; Menu closes it.
struct SettingsView: View {
    @Bindable var vm: BigscreenViewModel
    @Binding var chatVisible: Bool
    var onClose: () -> Void

    private enum Field: Hashable {
        case account, showChat, darkenChat, chatSide, chatMode, chatWidth, fontSize
        case hideOffline, preview, barDelay, latency, minimizeLatency, followHosts, captions, about
        case done
    }

    @FocusState private var focus: Field?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    @State private var enteringKey = false
    @State private var keyDraft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 70) {
            info
                .frame(width: 620, alignment: .leading)
            controls
                .frame(maxWidth: .infinity)
        }
        .padding(.leading, 80)
        .padding(.trailing, 50)
        .padding(.vertical, 60)
        // NO rounded panel and NO clip: Apple's own Settings is full-bleed.
        // See `focusRoom` for the clip the List itself applies.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(.black.opacity(0.55))
                .ignoresSafeArea()
        }
        .alert("DGG Login Key", isPresented: $enteringKey) {
            SecureField("Login Key", text: $keyDraft)
            Button("Save") {
                // Empty means nothing was typed. Signing out is its own button.
                if !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    vm.setLoginKey(keyDraft)
                }
            }
            if vm.hasLoginKey {
                Button("Sign Out", role: .destructive) { vm.setLoginKey(nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create one on destiny.gg under Profile, then Developer. "
                 + "It's kept in this Apple TV's Keychain.")
        }
    }

    // MARK: - Left: what the focused row does

    private var info: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings").font(.system(size: 62, weight: .bold))
            // One block, so moving between rows crossfades instead of the
            // text cutting over.
            VStack(alignment: .leading, spacing: 22) {
                Text(title).font(.title3).foregroundStyle(.white)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if focus == .about, let qr = Self.sourceQR {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(14)
                        .background(.white, in: .rect(cornerRadius: 16))
                        .padding(.top, 10)
                    Text(Self.source).font(.callout).foregroundStyle(.tertiary)
                }
            }
            .id(focus)
            .transition(.opacity)

            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.18), value: focus)
    }

    private static let source = "github.com/murdrd00/dgg-tv"

    /// Drawn once: a QR code for the source, since the TV can't open links.
    private static let sourceQR: UIImage? = {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(("https://" + source).utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter?.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }()

    private var title: String {
        switch focus {
        case .account:     return "DGG account"
        case .showChat:    return "Show chat"
        case .darkenChat:  return "Darken other embeds' chat"
        case .chatSide:    return "Chat side"
        case .chatMode:    return "Chat style"
        case .chatWidth:   return "Chat width"
        case .fontSize:    return "Font size"
        case .hideOffline: return "Hide offline channels"
        case .preview:     return "Preview on Home"
        case .barDelay:    return "Hide embed bar after"
        case .latency:     return "Latency counter"
        case .minimizeLatency:    return "Minimize latency"
        case .followHosts: return "Follow hosts"
        case .captions: return "Live captions"
        case .about:       return "About DGGTV"
        case .done, nil:   return "Done"
        }
    }

    private var detail: String {
        switch focus {
        case .account:
            return "Connects chat as you, using a Login Key from destiny.gg "
                 + "under Profile, then Developer. This app can't send chat "
                 + "messages. The only thing it sends is a poll vote you choose."
        case .showChat:
            return "Show or hide the chat rail over the video. Polls still "
                 + "appear with chat hidden."
        case .darkenChat:
            return "Dims messages from people watching something else, so "
                 + "the ones about your embed stand out."
        case .chatSide:
            return "Which side of the screen chat sits on."
        case .chatMode:
            return "Overlay floats chat over the video. Pinned shrinks the "
                 + "video to sit beside chat, on a solid background."
        case .chatWidth:
            return "How much of the screen the chat rail takes up."
        case .fontSize:
            return "Size of chat text. Emotes and row spacing scale with it."
        case .hideOffline:
            return "Only hides channels confirmed offline. Anything that "
                 + "can't be reached stays listed, so a network blip won't "
                 + "make embeds disappear."
        case .preview:
            return "Highlighting an embed plays it muted behind the list, so "
                 + "opening it is instant. Turn off to save bandwidth."
        case .barDelay:
            return "How long the embed bar stays on screen after you switch. "
                 + "Set it all the way up and it never hides."
        case .latency:
            return "Shows how many seconds behind live the stream is, in the "
                 + "top right of the video. Auto-hide shows it only while the "
                 + "embed bar is on screen."
        case .minimizeLatency:
            return "Keeps Kick streams as close to live as each one can "
                 + "manage, skipping ahead once when a stream opens. Off plays "
                 + "the regular stream, which runs about 15 seconds behind."
        case .followHosts:
            return "Automatic switches to whatever the mods host, and to Destiny "
                 + "when he goes live, the way the site moves everyone. Ask shows "
                 + "it for a few seconds instead, and Select takes it. Only when "
                 + "it happens, so you can switch away after. YouTube is skipped, "
                 + "since it can't play here."
        case .captions:
            if vm.captions.status == .unsupported {
                return "This Apple TV can't transcribe speech on its own, so live "
                     + "captions aren't available here."
            }
            return "Captions for Kick and Twitch streams, transcribed on this Apple "
                 + "TV as you watch. Words appear as they're said. It listens to a "
                 + "second, small copy of the stream, so it uses a little more "
                 + "data. The first time, it downloads Apple's English speech model."
        case .about:
            return "An unofficial fan app for destiny.gg, not affiliated with "
                 + "Destiny or the site. Made by murdrd. Version \(version). The "
                 + "code is open: scan to see it on GitHub."
        case .done, nil:
            return "Close settings. Menu on the remote does the same."
        }
    }

    // MARK: - Right: the controls

    private var controls: some View {
        List {
            Section("Account") {
                ValueRow(label: "DGG account", value: vm.accountLabel) {
                    keyDraft = ""
                    enteringKey = true
                }
                    .focused($focus, equals: .account)
            }
            Section("Chat") {
                SwitchRow(label: "Show chat", isOn: $chatVisible)
                    .focused($focus, equals: .showChat)
                SwitchRow(label: "Darken other embeds' chat", isOn: $vm.darkensOtherEmbeds)
                    .focused($focus, equals: .darkenChat)
                ValueRow(label: "Chat side", value: vm.chatSide.label) {
                    vm.chatSide = vm.chatSide.next
                }
                    .focused($focus, equals: .chatSide)
                ValueRow(label: "Chat style", value: vm.chatMode.label) {
                    vm.chatMode = vm.chatMode.next
                }
                    .focused($focus, equals: .chatMode)
                SliderRow(label: "Width", value: $vm.chatWidth,
                          range: 380...760, step: 20)
                    .focused($focus, equals: .chatWidth)
                SliderRow(label: "Font size", value: $vm.chatFontSize,
                          range: 15...34, step: 1)
                    .focused($focus, equals: .fontSize)
            }

            Section("Embeds") {
                SwitchRow(label: "Hide offline channels", isOn: $vm.hideOffline)
                    .focused($focus, equals: .hideOffline)
                SwitchRow(label: "Preview on Home", isOn: $vm.previewOnHome)
                    .focused($focus, equals: .preview)
                SliderRow(label: "Bar auto-hide", value: $vm.barAutoHideSeconds,
                          range: 2...BigscreenViewModel.barNeverHides, step: 1) {
                    $0 >= BigscreenViewModel.barNeverHides ? "Never" : "\(Int($0))s"
                }
                    .focused($focus, equals: .barDelay)
                ValueRow(label: "Latency counter", value: vm.latencyCounter.label) {
                    vm.latencyCounter = vm.latencyCounter.next
                }
                    .focused($focus, equals: .latency)
                SwitchRow(label: "Minimize latency", isOn: $vm.minimizesLatency)
                    .focused($focus, equals: .minimizeLatency)
                ValueRow(label: "Follow hosts", value: vm.hostFollowing.label) {
                    vm.hostFollowing = vm.hostFollowing.next
                }
                    .focused($focus, equals: .followHosts)
                SwitchRow(label: "Live captions", isOn: $vm.liveCaptions)
                    .focused($focus, equals: .captions)
            }

            Section("About") {
                ValueRow(label: "About DGGTV", value: version) {}
                    .focused($focus, equals: .about)
            }

            Section {
                Button("Done", action: onClose)
                    .focused($focus, equals: .done)
            }
        }
        .listStyle(.grouped)
        .focusRoom()
    }

}

