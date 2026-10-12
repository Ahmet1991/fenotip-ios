import AVFoundation
import SwiftUI
import UIKit

@main
struct FenotipApp: App {
    @StateObject private var app = AppModel()

    init() {
        // Afişler tekrar tekrar inmesin: görsel önbelleği büyütülür.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        // Sessiz anahtarı açıkken de film sesi çalsın.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        Diagnostics.shared.start(systemVersion: UIDevice.current.systemVersion)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.tv)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let background = Color(red: 0.031, green: 0.031, blue: 0.031)
    static let card = Color(white: 0.12)
    static let accent = Color(red: 0.80, green: 0.64, blue: 0.38)
    static let muted = Color(white: 0.62)
}
