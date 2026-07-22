import SwiftUI

/// The signature surface (§3.3): a softly rounded, softly elevated card floating
/// on the canvas. Continuous (squircle) corner curvature, always.
public struct ZyquoCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let elevation: Zyquo.Elevation
    private let padding: CGFloat
    private let content: Content

    public init(
        cornerRadius: CGFloat = Zyquo.radius.m,
        elevation: Zyquo.Elevation = Zyquo.elevation.level1,
        padding: CGFloat = Zyquo.spacing.m,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.elevation = elevation
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Zyquo.color.surface)
            )
            .zyquoShadow(elevation)
    }
}
