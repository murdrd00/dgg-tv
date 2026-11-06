import SwiftUI
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
        case hideOffline, preview, barDelay, latency, lowDelay, about
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
            }
            .id(focus)
            .transition(.opacity)

            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.18), value: focus)
    }

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
        case .lowDelay:    return "Low delay"
        case .about:       return "DGGTV"
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
            return "Show or hide the chat rail over the video."
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
            return "Shows how many seconds behind live the stream is. Select "
                 + "moves it around the corners of the video, then turns it off."
        case .lowDelay:
            return "Keeps Kick streams close to live, skipping ahead now and "
                 + "then. If a stream buffers a lot, raise this: more seconds "
                 + "means more delay but fewer stalls. Off plays the regular "
                 + "stream, which runs about 15 seconds behind."
        case .about:
            return "A native Apple TV app for destiny.gg. Version \(version)."
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
                ValueRow(label: "Latency counter", value: vm.latencyCorner.label) {
                    vm.latencyCorner = vm.latencyCorner.next
                }
                    .focused($focus, equals: .latency)
                SliderRow(label: "Low delay", value: $vm.liveCushion,
                          range: 1...BigscreenViewModel.liveDelayOff, step: 1) {
                    $0 >= BigscreenViewModel.liveDelayOff ? "Off" : "\(Int($0))s"
                }
                    .focused($focus, equals: .lowDelay)
            }

            Section("About") {
                ValueRow(label: "Version", value: version) {}
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

