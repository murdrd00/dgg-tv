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
        case preview, barDelay, latency, minimizeLatency, followHosts, about
        case done
    }

    @FocusState private var focus: Field?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    @State private var enteringKey = false
    @State private var showingProfile = false
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
        .fullScreenCover(isPresented: $showingProfile) {
            ProfileScreen(vm: vm, onChangeKey: {
                showingProfile = false
                keyDraft = ""
                enteringKey = true
            }, onClose: { showingProfile = false })
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
        case .account:     return vm.hasLoginKey ? "Profile" : "DGG account"
        case .showChat:    return "Show chat"
        case .darkenChat:  return "Darken other embeds' chat"
        case .chatSide:    return "Chat side"
        case .chatMode:    return "Chat style"
        case .chatWidth:   return "Chat width"
        case .fontSize:    return "Font size"
        case .preview:     return "Preview on Home"
        case .barDelay:    return "Hide embed bar after"
        case .latency:     return "Latency counter"
        case .minimizeLatency:    return "Minimize latency"
        case .followHosts: return "Follow hosts"
        case .about:       return "About DGGTV"
        case .done, nil:   return "Done"
        }
    }

    private var detail: String {
        switch focus {
        case .account where vm.hasLoginKey:
            return "Your destiny.gg Membership Card, and the account. Change the "
                 + "Login Key or sign out from there."
        case .account:
            return "Sign in with a Login Key from destiny.gg, under Profile then "
                 + "Developer. Used for poll votes only."
        case .showChat:        return "Polls still show with chat hidden."
        case .darkenChat:      return "Dims messages from people watching another embed."
        case .chatSide:        return "Left or right."
        case .chatMode:        return "Overlay sits over the video. Pinned sits beside it."
        case .chatWidth:       return "Width of the chat column."
        case .fontSize:        return "Chat text and emote size."
        case .preview:         return "Plays the highlighted embed, muted, behind the list."
        case .barDelay:        return "How long the embed bar stays up. All the way up is never."
        case .latency:         return "Seconds behind live, top right. Auto-hide follows the embed bar."
        case .minimizeLatency: return "Kick only. Off runs about 15 seconds behind."
        case .followHosts:
            return "Switches when the mods host something or Destiny goes live. "
                 + "Ask offers it first."
        case .about:
            return "Unofficial fan app by murdrd. Version \(version). Scan for the source."
        case .done, nil:       return "Or press Menu."
        }
    }

    // MARK: - Right: the controls

    private var controls: some View {
        List {
            Section("Account") {
                if vm.hasLoginKey {
                    // One row: the card, changing the key and signing out are inside.
                    ValueRow(label: "Profile", value: vm.accountLabel) {
                        showingProfile = true
                    }
                        .focused($focus, equals: .account)
                } else {
                    ValueRow(label: "DGG account", value: vm.accountLabel) {
                        keyDraft = ""
                        enteringKey = true
                    }
                        .focused($focus, equals: .account)
                }
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

