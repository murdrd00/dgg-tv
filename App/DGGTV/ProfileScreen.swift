import SwiftUI
import CoreImage
import DGGKit

/// A QR code for a link, since the TV can't open one itself.
enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter?.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Settings → Profile: the Membership Card from destiny.gg/u/<name>, and the
/// account. Editing is on the site, reached by the QR code; see `ProfileCard`
/// for why it isn't done from here.
struct ProfileScreen: View {
    var vm: BigscreenViewModel
    var onChangeKey: () -> Void
    var onClose: () -> Void

    @State private var card: ProfileCard?
    @State private var loaded = false
    @State private var flipped = false

    private enum Field: Hashable { case flip, changeKey, signOut, done }
    @FocusState private var focus: Field?

    private static let editPage = "https://www.destiny.gg/profile"
    private static let editQR = QRCode.image(for: editPage)

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 30) {
                Text("Profile").font(.system(size: 62, weight: .bold))
                Group {
                    if let card {
                        TVIDCard(card: card, flipped: flipped)
                    } else if loaded {
                        Text("Couldn't load the Membership Card.")
                            .foregroundStyle(.secondary)
                            .frame(width: 1000, height: 560)
                    } else {
                        ProgressView().frame(width: 1000, height: 560)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 24) {
                Text(vm.accountLabel).font(.title3).padding(.top, 104)
                Button(flipped ? "Show the front" : "Turn the card over") {
                    withAnimation(.spring(duration: 0.6)) { flipped.toggle() }
                }
                .focused($focus, equals: .flip)
                .disabled(card == nil)
                Button("Change Login Key", action: onChangeKey)
                    .focused($focus, equals: .changeKey)
                Button("Sign Out", role: .destructive) {
                    vm.setLoginKey(nil)
                    onClose()
                }
                .focused($focus, equals: .signOut)
                Button("Done", action: onClose)
                    .focused($focus, equals: .done)

                Spacer(minLength: 20)
                if let qr = Self.editQR {
                    HStack(spacing: 24) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 170, height: 170)
                            .padding(12)
                            .background(.white, in: .rect(cornerRadius: 14))
                        Text("Scan to edit your profile on destiny.gg")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(width: 260, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 90)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Rectangle().fill(.ultraThinMaterial).overlay(.black.opacity(0.55)).ignoresSafeArea()
        }
        .onExitCommand(perform: onClose)
        .task(id: vm.accountName) {
            guard let name = vm.accountName else { return }
            card = await ProfileCard.load(name: name)
            loaded = true
        }
        .onAppear { focus = .flip }
    }
}

/// The card as the site draws it, at TV size. The front has the photo and
/// details; the back has the signature and member number.
struct TVIDCard: View {
    let card: ProfileCard
    var flipped: Bool

    private static let logo = URL(string: "https://cdn.destiny.gg/img/dgg-icon.d1d8f07375806583e6fc.png")
    private static let blue = Color(red: 0.32, green: 0.56, blue: 0.85)

    var body: some View {
        // The front sets the size and the back lies over it, so both sides
        // are the same and nothing stretches.
        front
            .fixedSize(horizontal: false, vertical: true)
            .opacity(flipped ? 0 : 1)
            .overlay {
                back.opacity(flipped ? 1 : 0)
                    .rotation3DEffect(.degrees(180), axis: (0, 1, 0))
            }
        .frame(width: 1000)
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (0, 1, 0), perspective: 0.4)
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
    }

    private func face<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Self.blue.frame(height: 14)
            content().padding(34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.11, green: 0.12, blue: 0.15))
        .clipShape(.rect(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 2))
    }

    private var front: some View {
        face {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 16) {
                    AsyncImage(url: Self.logo) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("DESTINY.GG").font(.system(size: 28, weight: .heavy))
                        Text("Membership Card").font(.system(size: 22)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let tier = card.tier { badge(tier, Self.blue) }
                }
                HStack(alignment: .top, spacing: 32) {
                    VStack(spacing: 16) {
                        AsyncImage(url: card.photo) { $0.resizable().scaledToFill() } placeholder: {
                            Color.white.opacity(0.08)
                        }
                        .frame(width: 190, height: 236)
                        .clipShape(.rect(cornerRadius: 16))
                        if let team = card.team { badge(team, .green) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        label("Name")
                        Text(card.name).font(.system(size: 46, weight: .bold))
                        if let since = card.since {
                            Text(since).font(.system(size: 22)).foregroundStyle(.secondary)
                        }
                        Rectangle().fill(.white.opacity(0.12)).frame(height: 2).padding(.vertical, 8)
                        ForEach(card.fields, id: \.self) { field in
                            HStack(alignment: .firstTextBaseline) {
                                label(field.label)
                                Spacer(minLength: 12)
                                Text(field.value).font(.system(size: 24))
                            }
                        }
                    }
                }
                if let bio = card.bio {
                    VStack(alignment: .leading, spacing: 6) {
                        label("Biography")
                        Text(bio).font(.system(size: 24)).lineLimit(3)
                    }
                }
            }
        }
    }

    private var back: some View {
        face {
            VStack(alignment: .leading, spacing: 20) {
                label("Signature")
                if let signature = card.signature {
                    SVGShape(d: signature, viewBox: 5900, viewBoxHeight: 1000)
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(height: 160)
                } else {
                    Text("Not signed").foregroundStyle(.secondary).frame(height: 160)
                }
                Rectangle().fill(.white.opacity(0.12)).frame(height: 2)
                if let number = card.memberNumber {
                    label("Member No.")
                    Text(number).font(.system(size: 40, weight: .semibold, design: .monospaced))
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 20, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(color.opacity(0.25), in: .capsule)
            .foregroundStyle(color)
    }
}
