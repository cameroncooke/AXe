import SwiftUI

extension View {
    /// Lays a screen's content out as a column no wider than reads well, centred on the screen
    /// itself.
    ///
    /// On an iPhone Duo unfolded and held sideways, iOS stands the status bar and the navigation
    /// bar's buttons in a column down one side of the screen. Content laid out in what is left
    /// sits off centre, and a list as wide as that screen is stretched thin: a name at one edge,
    /// its button at the other. So the column is kept to `maxWidth` and balanced against that side
    /// column, which puts it in the middle of the screen. On an iPhone held upright it changes
    /// nothing: the screen is narrower than the column and its sides are alike.
    func screenColumn(maxWidth: CGFloat = 520) -> some View {
        modifier(ScreenColumn(maxWidth: maxWidth))
    }
}

private struct ScreenColumn: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let balance = ScreenBalance(proxy)
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, balance.leading)
                .padding(.trailing, balance.trailing)
        }
    }
}

/// What a screen has room for: the padding that makes a view's two sides alike when the safe
/// area's are not, and whether there is width for a layout of its own.
struct ScreenBalance {
    let leading: CGFloat
    let trailing: CGFloat
    /// True when there is about as much width to use as an unfolded iPhone Duo held sideways, an
    /// iPhone on its side, or an iPad has.
    let wide: Bool
    /// True when there is little height: an iPhone on its side.
    let short: Bool

    init(_ proxy: GeometryProxy) {
        let insets = proxy.safeAreaInsets
        let lead = max(0, insets.trailing - insets.leading), trail = max(0, insets.leading - insets.trailing)
        // Balancing gives width away. A screen with little of it, such as the Duo's outer screen
        // with the status bar down its side, keeps all it has and sits a little off centre.
        let affordable = proxy.size.width - lead - trail >= 520
        leading = affordable ? lead : 0
        trailing = affordable ? trail : 0
        wide = proxy.size.width >= 700
        short = proxy.size.height < 520
    }
}

/// A list beside what is chosen from it, where the screen has the width for both, and `narrow`
/// where it has not: an unfolded iPhone Duo or an iPad held sideways gets the pair, a phone held
/// upright the one. SwiftUI chooses (`ViewThatFits`): the pair is offered first, says how much
/// width it needs, and is taken only when it fits. Nothing here measures the screen.
struct SideBySide<Side: View, Main: View, Narrow: View>: View {
    private let side: Side
    private let main: Main
    private let narrow: Narrow

    init(@ViewBuilder side: () -> Side, @ViewBuilder main: () -> Main, @ViewBuilder narrow: () -> Narrow) {
        self.side = side()
        self.main = main()
        self.narrow = narrow()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                // A sidebar's width, as a split view gives its first column.
                side.frame(width: 320)
                // What it needs to be worth having beside the list; it takes all there is.
                main.frame(minWidth: 380, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            narrow
        }
    }
}
