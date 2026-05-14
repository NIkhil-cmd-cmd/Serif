import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AccountAvatarBubble: View {
    let account: GmailAccount
    let isSelected: Bool
    var size: CGFloat = 34
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var image: PlatformImage?

    private var initial: String {
        String(account.displayName.prefix(1)).uppercased()
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Base circle
                Circle().fill(isSelected ? theme.sidebarTextMuted : theme.hoverBackground)
                if !isSelected && image == nil && account.profilePictureURL == nil {
                    Circle().strokeBorder(theme.divider, lineWidth: 1)
                }

                if let image {
                    platformImage(image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                } else {
                    Text(initial)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundColor(isSelected ? .white : theme.textSecondary)
                }

                // Accent color ring when selected
                if isSelected, let hex = account.accentColor {
                    Circle().strokeBorder(Color(hex: hex), lineWidth: 2.5)
                }

                if account.provider == .outlook {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: size * 0.22, weight: .bold))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Circle().fill(Color(red: 0.0, green: 0.47, blue: 0.83)))
                        .offset(x: size * 0.28, y: size * 0.28)
                } else if account.provider == .gmail {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: size * 0.2, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Circle().fill(Color(red: 0.86, green: 0.20, blue: 0.18)))
                        .offset(x: size * 0.28, y: size * 0.28)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .drawingGroup(opaque: false)
        }
        .buttonStyle(.plain)
        .help(account.email)
        .task(id: account.profilePictureURL?.absoluteString) {
            guard let url = account.profilePictureURL else { return }
            image = await AvatarCache.shared.image(for: url.absoluteString)
        }
    }

    private func platformImage(_ img: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: img)
        #else
        Image(uiImage: img)
        #endif
    }
}
