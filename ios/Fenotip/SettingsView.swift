import SwiftUI

/// Altyazı yazı boyutu (bu cihaza özel). Değer VLC'nin göreli boyutu: küçük sayı = büyük yazı.
enum SubtitleSize: Int, CaseIterable, Identifiable {
    case small = 20
    case normal = 16
    case large = 12
    case huge = 8

    static let storageKey = "fenotip.subtitleSize"
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .small: return "Küçük"
        case .normal: return "Normal"
        case .large: return "Büyük"
        case .huge: return "Çok büyük"
        }
    }

    static var current: SubtitleSize {
        SubtitleSize(rawValue: UserDefaults.standard.object(forKey: storageKey) as? Int ?? SubtitleSize.normal.rawValue) ?? .normal
    }
}

/// Oynatıcıda yalnız bu cihazı etkileyen ayarlar.
enum PlayerDeviceSettings {
    static let doubleTapSeekSecondsKey = "fenotip.doubleTapSeekSeconds"
    static let movieOrientationKey = "fenotip.movieOrientation"
    static let backgroundAudioKey = "fenotip.backgroundAudio"
    static let doubleTapSeekOptions = [5, 10, 15, 30]

    static var doubleTapSeekSeconds: Int {
        let value = UserDefaults.standard.object(forKey: doubleTapSeekSecondsKey) as? Int ?? 10
        return doubleTapSeekOptions.contains(value) ? value : 10
    }

    static var movieOrientation: String {
        UserDefaults.standard.string(forKey: movieOrientationKey) ?? "automatic"
    }

    static var backgroundAudio: Bool {
        UserDefaults.standard.bool(forKey: backgroundAudioKey)
    }
}

/// Ayarlar: oynatma tercihleri (PC ve TV ile ortak profil ayarı), TV bağlantısı, önbellek, sürüm.
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tv: TvRemote
    @Environment(\.dismiss) private var dismiss
    @State private var cacheCleared = false
    @AppStorage(SubtitleSize.storageKey) private var subtitleSize = SubtitleSize.normal.rawValue
    @AppStorage(PlayerDeviceSettings.doubleTapSeekSecondsKey) private var doubleTapSeekSeconds = 10
    @AppStorage(PlayerDeviceSettings.movieOrientationKey) private var movieOrientation = "automatic"
    @AppStorage(PlayerDeviceSettings.backgroundAudioKey) private var backgroundAudio = false

    static let languages: [(code: String, name: String)] = [
        ("tr", "Türkçe"), ("en", "İngilizce"), ("de", "Almanca"), ("fr", "Fransızca"), ("es", "İspanyolca"),
        ("it", "İtalyanca"), ("ru", "Rusça"), ("ar", "Arapça"), ("ja", "Japonca"), ("ko", "Korece"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if let profile = app.profile {
                    Section("Profil") {
                        HStack(spacing: 12) {
                            Text(profile.emoji).font(.largeTitle)
                            Text(profile.name).font(.headline)
                        }
                        Button("Profil değiştir") {
                            dismiss()
                            app.switchProfile()
                        }
                    }
                }
                Section {
                    Picker("Ses dili", selection: audioLanguage) {
                        Text("Yayının varsayılanı").tag("")
                        ForEach(SettingsView.languages, id: \.code) { language in Text(language.name).tag(language.code) }
                    }
                    Picker("Altyazı", selection: subtitleChoice) {
                        Text("Kapalı").tag("off")
                        Text("Yayının varsayılanı").tag("")
                        ForEach(SettingsView.languages, id: \.code) { language in Text(language.name).tag(language.code) }
                    }
                    Toggle("Sonraki bölümü otomatik oynat", isOn: Binding(get: { app.state.autoNextEpisode }, set: { app.setAutoNextEpisode($0) }))
                } header: {
                    Text("Oynatma")
                } footer: {
                    Text("Bu tercihler profiline kaydedilir; PC'de ve TV'de de aynı dil seçilir.")
                }
                Section {
                    Picker("Altyazı boyutu", selection: $subtitleSize) {
                        ForEach(SubtitleSize.allCases) { size in Text(size.label).tag(size.rawValue) }
                    }
                    Picker("Çift dokunuşla sarma", selection: $doubleTapSeekSeconds) {
                        ForEach(PlayerDeviceSettings.doubleTapSeekOptions, id: \.self) { seconds in
                            Text("\(seconds) saniye").tag(seconds)
                        }
                    }
                    Picker("Filmler açılırken", selection: $movieOrientation) {
                        Text("Otomatik yön").tag("automatic")
                        Text("Yatay").tag("landscape")
                    }
                    Toggle("Arka planda sesi sürdür", isOn: $backgroundAudio)
                } header: {
                    Text("Bu cihaz")
                } footer: {
                    Text("Bu ayarlar yalnız bu iPhone/iPad'de saklanır. Arka plan sesi varsayılan olarak kapalıdır.")
                }
                Section("TV") {
                    if let link = tv.link {
                        LabeledContent("Bağlı TV", value: link.deviceName)
                        Button("Kumandayı aç") {
                            dismiss()
                            tv.showRemote = true
                        }
                        Button("Bağlantıyı kes", role: .destructive) { tv.disconnect() }
                    } else {
                        Button("TV'ye bağlan") {
                            dismiss()
                            tv.showPairing = true
                        }
                    }
                }
                Section {
                    Button(cacheCleared ? "Görsel önbelleği temizlendi ✓" : "Görsel önbelleğini temizle") {
                        ImageLoader.shared.clear()
                        URLCache.shared.removeAllCachedResponses()
                        cacheCleared = true
                    }
                    .disabled(cacheCleared)
                    Button("Kataloğu sağlayıcıdan yenile") {
                        Task { await app.loadLibrary(force: true) }
                        dismiss()
                    }
                } header: {
                    Text("Depolama")
                } footer: {
                    Text("Katalog 6 saatte bir kendiliğinden yenilenir.")
                }
                Section("Hakkında") {
                    LabeledContent("Sürüm", value: version)
                }
                Section {
                    Button("Çıkış yap", role: .destructive) {
                        dismiss()
                        Task { await app.logout() }
                    }
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var audioLanguage: Binding<String> {
        Binding(
            get: { TrackLanguage.normalize(app.state.playbackPreferences.audioLanguage) ?? "" },
            set: { app.savePlaybackPreferences(["audioLanguage": $0]) }
        )
    }

    private var subtitleChoice: Binding<String> {
        Binding(
            get: {
                let preferences = app.state.playbackPreferences
                if preferences.subtitlesEnabled == false { return "off" }
                return TrackLanguage.normalize(preferences.subtitleLanguage) ?? ""
            },
            set: { value in
                if value == "off" {
                    app.savePlaybackPreferences(["subtitlesEnabled": false])
                } else {
                    app.savePlaybackPreferences(["subtitlesEnabled": true, "subtitleLanguage": value])
                }
            }
        )
    }
}
