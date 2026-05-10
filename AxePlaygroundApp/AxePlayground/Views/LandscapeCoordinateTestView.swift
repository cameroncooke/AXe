import SwiftUI

struct LandscapeCoordinateTestView: View {
    @State private var tapHitCount = 0
    @State private var tapMissCount = 0
    @State private var swipeHitCount = 0
    @State private var swipeMissCount = 0
    @State private var lastTapHit = "none"
    @State private var lastTapMiss = "none"
    @State private var lastSwipeStart = "none"
    @State private var lastSwipeEnd = "none"
    @State private var dragStart: CGPoint?

    private let tapTargetSize = CGSize(width: 120, height: 80)
    private let swipeTargetSize = CGSize(width: 90, height: 70)

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let tapTargetCenter = CGPoint(
                x: isLandscape ? geometry.size.width * 0.78 : geometry.size.width * 0.22,
                y: isLandscape ? geometry.size.height * 0.32 : geometry.size.height * 0.72
            )
            let swipeStartCenter = CGPoint(
                x: isLandscape ? geometry.size.width * 0.20 : geometry.size.width * 0.24,
                y: isLandscape ? geometry.size.height * 0.76 : geometry.size.height * 0.34
            )
            let swipeEndCenter = CGPoint(
                x: isLandscape ? geometry.size.width * 0.84 : geometry.size.width * 0.76,
                y: isLandscape ? geometry.size.height * 0.76 : geometry.size.height * 0.34
            )
            let tapTargetRect = CGRect(center: tapTargetCenter, size: tapTargetSize)
            let swipeStartRect = CGRect(center: swipeStartCenter, size: swipeTargetSize)
            let swipeEndRect = CGRect(center: swipeEndCenter, size: swipeTargetSize)
            let globalFrame = geometry.frame(in: .global)

            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 8) {
                    Text("Landscape Coordinate Test")
                        .font(.title2)
                        .fontWeight(.bold)
                        .accessibilityIdentifier("landscape-coordinate-title")

                    Text(isLandscape ? "Layout: landscape" : "Layout: portrait")
                        .font(.headline)
                        .accessibilityIdentifier("landscape-coordinate-layout")
                        .accessibilityValue(isLandscape ? "landscape" : "portrait")

                    Text("Landscape Hit Count: \(tapHitCount)")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .accessibilityIdentifier("landscape-coordinate-hit-count")
                        .accessibilityValue("\(tapHitCount)")

                    Text("Landscape Miss Count: \(tapMissCount)")
                        .font(.headline)
                        .foregroundColor(.red)
                        .accessibilityIdentifier("landscape-coordinate-miss-count")
                        .accessibilityValue("\(tapMissCount)")

                    Text("Landscape Swipe Hit Count: \(swipeHitCount)")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .accessibilityIdentifier("landscape-coordinate-swipe-hit-count")
                        .accessibilityValue("\(swipeHitCount)")

                    Text("Landscape Swipe Miss Count: \(swipeMissCount)")
                        .font(.headline)
                        .foregroundColor(.red)
                        .accessibilityIdentifier("landscape-coordinate-swipe-miss-count")
                        .accessibilityValue("\(swipeMissCount)")

                    Text("Last Tap Hit: \(lastTapHit)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("landscape-coordinate-last-tap-hit")
                        .accessibilityValue(lastTapHit)

                    Text("Last Tap Miss: \(lastTapMiss)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("landscape-coordinate-last-tap-miss")
                        .accessibilityValue(lastTapMiss)

                    Text("Last Swipe Start: \(lastSwipeStart)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("landscape-coordinate-last-swipe-start")
                        .accessibilityValue(lastSwipeStart)

                    Text("Last Swipe End: \(lastSwipeEnd)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("landscape-coordinate-last-swipe-end")
                        .accessibilityValue(lastSwipeEnd)
                }
                .padding()
                .background(Color.white.opacity(0.92))
                .cornerRadius(12)
                .shadow(radius: 4)
                .position(x: geometry.size.width * 0.5, y: 130)
                .allowsHitTesting(false)

                targetLabel(
                    isLandscape ? "Landscape Target" : "Portrait Target",
                    color: isLandscape ? .green : .orange,
                    size: tapTargetSize
                )
                .position(tapTargetCenter)
                .accessibilityIdentifier("landscape-coordinate-target")
                .accessibilityLabel(isLandscape ? "Landscape Target" : "Portrait Target")
                .accessibilityValue(isLandscape ? "landscape-target" : "portrait-target")
                .allowsHitTesting(false)

                targetLabel(
                    isLandscape ? "Landscape Swipe Start" : "Portrait Swipe Start",
                    color: .purple,
                    size: swipeTargetSize
                )
                .position(swipeStartCenter)
                .accessibilityIdentifier("landscape-coordinate-swipe-start")
                .accessibilityLabel(isLandscape ? "Landscape Swipe Start" : "Portrait Swipe Start")
                .accessibilityValue(isLandscape ? "landscape-swipe-start" : "portrait-swipe-start")
                .allowsHitTesting(false)

                targetLabel(
                    isLandscape ? "Landscape Swipe End" : "Portrait Swipe End",
                    color: .indigo,
                    size: swipeTargetSize
                )
                .position(swipeEndCenter)
                .accessibilityIdentifier("landscape-coordinate-swipe-end")
                .accessibilityLabel(isLandscape ? "Landscape Swipe End" : "Portrait Swipe End")
                .accessibilityValue(isLandscape ? "landscape-swipe-end" : "portrait-swipe-end")
                .allowsHitTesting(false)

                Circle()
                    .stroke(Color.red, lineWidth: 3)
                    .frame(width: 44, height: 44)
                    .position(x: geometry.size.width * 0.22, y: geometry.size.height * 0.72)
                    .opacity(isLandscape ? 0.25 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = value.startLocation
                        }
                    }
                    .onEnded { value in
                        let start = dragStart ?? value.startLocation
                        let end = value.location
                        dragStart = nil

                        let distance = hypot(end.x - start.x, end.y - start.y)
                        if distance < 20 {
                            recordTap(at: end, globalFrame: globalFrame, targetRect: tapTargetRect)
                        } else {
                            recordSwipe(
                                start: start,
                                end: end,
                                globalFrame: globalFrame,
                                startRect: swipeStartRect,
                                endRect: swipeEndRect
                            )
                        }
                    }
            )
        }
        .navigationTitle("Landscape Coordinates")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("landscape-coordinate-screen")
    }

    private func targetLabel(_ title: String, color: Color, size: CGSize) -> some View {
        Text(title)
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(width: size.width, height: size.height)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(12)
    }

    private func recordTap(at location: CGPoint, globalFrame: CGRect, targetRect: CGRect) {
        let globalLocation = location.offsetBy(dx: globalFrame.minX, dy: globalFrame.minY)
        if targetRect.contains(location) {
            tapHitCount += 1
            lastTapHit = formatted(globalLocation)
        } else {
            tapMissCount += 1
            lastTapMiss = formatted(globalLocation)
        }
    }

    private func recordSwipe(
        start: CGPoint,
        end: CGPoint,
        globalFrame: CGRect,
        startRect: CGRect,
        endRect: CGRect
    ) {
        let globalStart = start.offsetBy(dx: globalFrame.minX, dy: globalFrame.minY)
        let globalEnd = end.offsetBy(dx: globalFrame.minX, dy: globalFrame.minY)
        lastSwipeStart = formatted(globalStart)
        lastSwipeEnd = formatted(globalEnd)

        if startRect.contains(start) && endRect.contains(end) {
            swipeHitCount += 1
        } else {
            swipeMissCount += 1
        }
    }

    private func formatted(_ point: CGPoint) -> String {
        "x:\(Int(point.x.rounded())),y:\(Int(point.y.rounded()))"
    }
}

private extension CGRect {
    init(center: CGPoint, size: CGSize) {
        self.init(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}

#Preview {
    NavigationStack {
        LandscapeCoordinateTestView()
    }
}
