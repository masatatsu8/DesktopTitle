//
//  OverlayView.swift
//  DesktopTitle
//
//  SwiftUI view for the Space name overlay
//

import SwiftUI

/// The overlay view that displays the Space name with animation
struct OverlayView: View {
    let spaceName: String
    let spaceIndex: Int

    @State private var opacity: Double = 0
    @State private var scale: Double = 0.8

    private let settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 8) {
            // Space name
            Text(spaceName)
                .font(.system(size: settings.fontSize, weight: .medium, design: .rounded))
                .foregroundStyle(.white)

            // Space index indicator
            Text("Desktop \(spaceIndex)")
                .font(.system(size: settings.fontSize * 0.4, weight: .regular))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        }
        .scaleEffect(scale)
        .opacity(opacity)
        .onAppear {
            // Fade in animation
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                opacity = 1
                scale = 1
            }

            // Schedule fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.displayDuration) {
                withAnimation(.easeOut(duration: 0.3)) {
                    opacity = 0
                    scale = 0.9
                }
            }
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.5)
        OverlayView(spaceName: "Development", spaceIndex: 1)
    }
    .frame(width: 600, height: 400)
}
