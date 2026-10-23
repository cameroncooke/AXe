//
//  SwipeTestView.swift
//  AxePlayground
//
//  Created by Cameron on 23/05/2025.
//

import SwiftUI

struct SwipeTestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var swipePaths: [SwipePath] = []
    @State private var currentPath: [CGPoint] = []
    @State private var swipeCount = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Full screen background
                Color.black.opacity(0.05)
                    .ignoresSafeArea(.all)
                
                // Interactive swipe area - covers entire screen
                Color.clear
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("swipe-test-area")
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                // On first point, use startLocation
                                if currentPath.isEmpty {
                                    // Using global coordinate space, no need to convert
                                    currentPath.append(value.startLocation)
                                }
                                
                                // Using global coordinate space, location is already in screen coordinates
                                currentPath.append(value.location)
                            }
                            .onEnded { value in
                                if currentPath.count > 1 {
                                    // Use the actual first point (which is startLocation)
                                    let startPoint = currentPath.first!
                                    let endPoint = currentPath.last!
                                    
                                    let path = SwipePath(
                                        startPoint: startPoint,
                                        endPoint: endPoint,
                                        pathPoints: currentPath,
                                        duration: 0.5,
                                        direction: calculateDirection(from: startPoint, to: endPoint)
                                    )
                                    swipePaths.append(path)
                                    swipeCount += 1
                                }
                                currentPath.removeAll()
                            }
                    )
                
                // Close button - positioned in top-left safe area
                VStack {
                    HStack {
                        Button("✕") {
                            dismiss()
                        }
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .padding()
                        .background(Color.white.opacity(0.9))
                        .clipShape(Circle())
                        .shadow(radius: 4)
                        .accessibilityIdentifier("close-button")
                        
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    
                    Spacer()
                }
                
                // Swipe paths with coordinate pills - drawn on top
                ForEach(swipePaths) { path in
                    SwipePathView(path: path, screenSize: geometry.size)
                        .accessibilityIdentifier("swipe-path-\(path.id.uuidString)")
                        .accessibilityValue("start:x\(Int(path.startPoint.x)),y\(Int(path.startPoint.y));end:x\(Int(path.endPoint.x)),y\(Int(path.endPoint.y))")
                }
                
                // Current swipe path - drawn on top
                if !currentPath.isEmpty {
                    SwipePathShape(points: currentPath)
                        .stroke(Color.blue, lineWidth: 2)
                        .opacity(0.7)
                }
                
                // Info box - positioned at bottom
                VStack {
                    Spacer()
                    
                    VStack(spacing: 12) {
                        Text("Swipe Playground")
                            .font(.title2)
                            .fontWeight(.bold)
                            .accessibilityIdentifier("swipe-test-title")
                        
                        Text("Count: \(swipeCount)")
                            .font(.headline)
                            .foregroundColor(.blue)
                            .accessibilityIdentifier("swipe-count")
                            .accessibilityValue("\(swipeCount)")
                        
                        if let lastSwipe = swipePaths.last {
                            VStack(spacing: 4) {
                                Text("Last Swipe:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text("Start: (\(Int(lastSwipe.startPoint.x)), \(Int(lastSwipe.startPoint.y)))")
                                    .font(.subheadline)
                                    .foregroundColor(.blue)
                                    .accessibilityIdentifier("last-swipe-start")
                                
                                Text("End: (\(Int(lastSwipe.endPoint.x)), \(Int(lastSwipe.endPoint.y)))")
                                    .font(.subheadline)
                                    .foregroundColor(.purple)
                                    .accessibilityIdentifier("last-swipe-end")
                                
                                Text("Direction: \(lastSwipe.direction)")
                                    .font(.subheadline)
                                    .foregroundColor(.green)
                                    .accessibilityIdentifier("last-swipe-direction")
                            }
                        } else {
                            Text("No swipes yet - draw with your finger")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.95))
                            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: -2)
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 34) // Account for home indicator
                }
                
                // Hidden accessibility elements
                if let lastSwipe = swipePaths.last {
                    Text("")
                        .accessibilityIdentifier("last-swipe-path")
                        .accessibilityValue("start:x\(Int(lastSwipe.startPoint.x)),y\(Int(lastSwipe.startPoint.y));end:x\(Int(lastSwipe.endPoint.x)),y\(Int(lastSwipe.endPoint.y))")
                        .accessibilityHidden(true)
                }
                
                Text("")
                    .accessibilityIdentifier("swipe-history")
                    .accessibilityValue(generateSwipeHistoryString())
                    .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea(.all) // Full screen coverage
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("swipe-test-screen")
    }
    
    private func calculateDirection(from start: CGPoint, to end: CGPoint) -> String {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        
        // Determine primary direction based on larger delta
        if abs(deltaX) > abs(deltaY) {
            return deltaX > 0 ? "Right" : "Left"
        } else {
            return deltaY > 0 ? "Down" : "Up"
        }
    }
    
    private func generateSwipeHistoryString() -> String {
        if swipeCount == 0 {
            return "no-swipes"
        }
        
        let recentSwipes = swipePaths.suffix(3)
        let swipeStrings = recentSwipes.map { 
            "start:x\(Int($0.startPoint.x)),y\(Int($0.startPoint.y));end:x\(Int($0.endPoint.x)),y\(Int($0.endPoint.y))"
        }
        return "count:\(swipeCount);recent:[\(swipeStrings.joined(separator: "|"))]"
    }
}

struct SwipePath: Identifiable {
    let id = UUID()
    let startPoint: CGPoint
    let endPoint: CGPoint
    let pathPoints: [CGPoint]
    let duration: Double
    let direction: String
    let timestamp = Date()
}

struct SwipePathView: View {
    let path: SwipePath
    let screenSize: CGSize
    
    private var centerPoint: CGPoint {
        CGPoint(
            x: (path.startPoint.x + path.endPoint.x) / 2,
            y: (path.startPoint.y + path.endPoint.y) / 2
        )
    }
    
    private var directionIcon: String {
        switch path.direction {
        case "Right": return "arrow.right"
        case "Left": return "arrow.left"
        case "Up": return "arrow.up"
        case "Down": return "arrow.down"
        default: return "arrow.right"
        }
    }
    
    var body: some View {
        ZStack {
            // Path line
            SwipePathShape(points: path.pathPoints)
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [.blue, .cyan, .purple]),
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 3
                )
                .opacity(0.8)
            
            // Start point
            Circle()
                .fill(Color.blue)
                .frame(width: 12, height: 12)
                .position(path.startPoint)
                .accessibilityIdentifier("swipe-start-point")
                .accessibilityValue("x:\(Int(path.startPoint.x)),y:\(Int(path.startPoint.y))")
            
            // End point
            Circle()
                .fill(Color.purple)
                .frame(width: 12, height: 12)
                .position(path.endPoint)
                .accessibilityIdentifier("swipe-end-point")
                .accessibilityValue("x:\(Int(path.endPoint.x)),y:\(Int(path.endPoint.y))")
            
            // Direction arrow at center of path
            Image(systemName: directionIcon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.orange)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 28, height: 28)
                )
                .position(centerPoint)
                .accessibilityIdentifier("swipe-direction-arrow")
                .accessibilityValue("direction:\(path.direction)")
            
            // Start coordinate pill
            CoordinatePill(
                text: "(\(Int(path.startPoint.x)), \(Int(path.startPoint.y)))",
                backgroundColor: .blue
            )
            .position(
                x: path.startPoint.x,
                y: max(25, path.startPoint.y - 25) // Prevent going off top
            )
            .accessibilityIdentifier("swipe-start-coordinate")
            
            // End coordinate pill
            CoordinatePill(
                text: "(\(Int(path.endPoint.x)), \(Int(path.endPoint.y)))",
                backgroundColor: .purple
            )
            .position(
                x: path.endPoint.x,
                y: min(screenSize.height - 25, path.endPoint.y + 25) // Prevent going off bottom
            )
            .accessibilityIdentifier("swipe-end-coordinate")
        }
    }
}

struct CoordinatePill: View {
    let text: String
    let backgroundColor: Color
    
    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor.opacity(0.9))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
    }
}

struct SwipePathShape: Shape {
    let points: [CGPoint]
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        guard points.count > 1 else { return path }
        
        path.move(to: points[0])
        
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        
        return path
    }
}

#Preview {
    SwipeTestView()
}
