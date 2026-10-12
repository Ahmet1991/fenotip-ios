import SwiftUI
import UIKit

/// TV'nin telefona bildirdiği "şimdi oynuyor".
struct RemoteNowPlaying: Decodable, Equatable {
    let kind: String
    let id: String
    let title: String
    let artworkUrl: String?
    let position: Double
    let duration: Double
    let paused: Bool
    let hasNextEpisode: Bool?
}

struct RemoteStatus: Decodable, Equatable {
    let online: Bool
    let lastSeenAt: Double
    let deviceName: String
    let nowPlaying: RemoteNowPlaying?
    let statusUpdatedAt: Double
}

/// TV'ye gönder ve kumanda: sitedeki bulut kumandasıyla aynı posta kutusu (/api/remote/*).
/// TV'de Fenotip açıkken Kumanda → "Bu cihaz TV" → kod üretilir; telefon o kodla bir kez eşleşir.
@MainActor
final class TvRemote: ObservableObject {
    struct Link: Codable, Equatable {
        let receiverId: String
        let deviceName: String
    }

    @Published private(set) var link: Link?
    @Published var status: RemoteStatus?
    @Published var showPairing = false
    @Published var showRemote = false
    @Published var toast: String?
    /// TV kapalıyken gönderilen içerik: TV'de Fenotip açılınca kendiliğinden gönderilir.
    @Published var waiting: String?
    private var waitTask: Task<Void, Never>?

    private let server: ServerAPI
    private static let storageKey = "fenotip.tv-link.v1"
    private static let extensions: Set<String> = ["mp4", "mkv", "m4v", "webm", "avi", "ts", "m3u8"]
    /// Eşleşme yokken basılan "TV'de oynat": eşleşince gönderilir.
    private var pending: [String: Any]?
    private var polling: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(server: ServerAPI) {
        self.server = server
        if let data = UserDefaults.standard.data(forKey: TvRemote.storageKey) {
            link = try? JSONDecoder().decode(Link.self, from: data)
        }
    }

    var deviceName: String { status?.deviceName ?? link?.deviceName ?? "TV" }

    /// Üstteki TV düğmesi: eşleşme varsa kumanda, yoksa eşleştirme.
    func open() {
        if link == nil { showPairing = true } else { showRemote = true }
    }

    func connect(code: String) async throws {
        let root = try await server.object("/api/remote/connect", method: "POST", body: ["code": code])
        guard let receiverId = root["receiverId"] as? String else { throw AppError.message("Eşleştirme başarısız.") }
        let next = Link(receiverId: receiverId, deviceName: root["deviceName"] as? String ?? "TV")
        save(next)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let command = pending {
            pending = nil
            await send(command)
        } else {
            showRemote = true
        }
    }

    func disconnect() {
        save(nil)
        status = nil
        stopPolling()
    }

    private func save(_ value: Link?) {
        link = value
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: TvRemote.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: TvRemote.storageKey)
        }
    }

    func say(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    @discardableResult
    func send(_ command: [String: Any], haptic: Bool = true) async -> Bool {
        guard let link else {
            pending = command
            showPairing = true
            return false
        }
        if haptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        do {
            let result = try await server.object("/api/remote/command", method: "POST", body: ["receiverId": link.receiverId, "command": command])
            if result["online"] as? Bool == false {
                say("\(deviceName)'de Fenotip açık görünmüyor; komut 30 sn bekler.")
            }
            if showRemote { Task { await self.refreshStatus(after: 0.9) } }
            return true
        } catch let error as ServerError where error.status == 404 {
            disconnect()
            pending = command
            say("TV eşleşmesi sona ermiş. TV'de yeni kod üretip tekrar bağlan.")
            showPairing = true
            return false
        } catch {
            say(error.localizedDescription)
            return false
        }
    }

    /// İçeriği TV'de açar (kaldığı yerden).
    @discardableResult
    func play(_ item: PlaybackItem, at start: Double) async -> Bool {
        var content: [String: Any] = ["kind": item.kind.rawValue, "id": item.contentId, "title": String(item.title.prefix(200))]
        if let artwork = item.artwork, artwork.lowercased().hasPrefix("http"), artwork.count <= 1000 { content["artworkUrl"] = artwork }
        if item.kind != .live {
            let ext = (item.ext ?? "mp4").lowercased()
            guard TvRemote.extensions.contains(ext) else {
                say("Bu dosya türü (\(ext)) TV'de açılamıyor.")
                return false
            }
            content["extension"] = ext
            if start >= 1 { content["start"] = Int(start) }
        }
        if item.kind == .series {
            guard let seriesId = item.seriesId else {
                say("Bölüm bilgisi eksik; TV'ye gönderilemedi.")
                return false
            }
            content["seriesId"] = seriesId
        }
        let command: [String: Any] = ["type": "open-content", "content": content]
        // Sunucu komutu 30 sn saklıyor; TV'de uygulama kapalıysa komut düşüyordu. Önce TV'nin dinleyip
        // dinlemediğine bakılır, dinlemiyorsa açılana kadar (3 dk) beklenir.
        if link != nil, let current = await fetchStatus(), !current.online {
            waitForTv(then: command, title: item.title)
            return true
        }
        let sent = await send(command)
        if sent { say("\(deviceName)'de açılıyor…") }
        return sent
    }

    private func waitForTv(then command: [String: Any], title: String) {
        waitTask?.cancel()
        let name = title.components(separatedBy: " · ").first ?? title
        waiting = "\(deviceName)'de Fenotip açık değil. TV'de uygulamayı aç; açılınca \(name) kendiliğinden başlayacak."
        waitTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(180)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if let status = await self.fetchStatus(), status.online {
                    self.waiting = nil
                    if await self.send(command) { self.say("\(self.deviceName)'de açılıyor…") }
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.waiting = nil
            self.say("TV 3 dakikada açılmadı; gönderim iptal edildi.")
        }
    }

    func cancelWaiting() {
        waitTask?.cancel()
        waitTask = nil
        waiting = nil
    }

    /// TV'nin anlık durumu (çevrimiçi mi, ne oynuyor); eşleşme silinmişse bağlantı kaldırılır.
    @discardableResult
    func fetchStatus() async -> RemoteStatus? {
        guard let link else { return nil }
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "receiverId", value: link.receiverId)]
        do {
            let current = try await server.get("/api/remote/status?" + (components.percentEncodedQuery ?? ""), as: RemoteStatus.self)
            status = current
            return current
        } catch let error as ServerError where error.status == 404 {
            disconnect()
            showRemote = false
            say("TV eşleşmesi sona ermiş. TV'de yeni kod üretip tekrar bağlan.")
            return nil
        } catch {
            return nil
        }
    }

    // MARK: Durum (kumanda açıkken 2 sn'de bir)

    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus(after: 0)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    private func refreshStatus(after delay: Double) async {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        await fetchStatus()
    }

    /// Son bildirimden bu yana geçen süre eklenmiş tahmini konum.
    func estimatedPosition(at now: Date = Date()) -> Double {
        guard let status, let playing = status.nowPlaying else { return 0 }
        if playing.paused || playing.kind == "live" { return playing.position }
        let elapsed = max(0, now.timeIntervalSince1970 * 1000 - status.statusUpdatedAt) / 1000
        return playing.duration > 0 ? min(playing.duration, playing.position + elapsed) : playing.position + elapsed
    }
}

// MARK: - Eşleştirme

struct TvPairingView: View {
    @EnvironmentObject private var tv: TvRemote
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "tv.and.mediabox")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    Text("TV'ye bağlan").font(.title2.bold()).frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        step(1, "TV'de Fenotip sitesini aç.")
                        step(2, "Kumanda → **Bu cihaz TV** → **Eşleştirme kodu üret**.")
                        step(3, "TV'de çıkan 6 haneli kodu aşağıya yaz.")
                    }
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    TextField("••••••", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .padding(.vertical, 12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                        .focused($focused)
                        .onChange(of: code) { value in
                            let digits = String(value.filter(\.isNumber).prefix(6))
                            if digits != value { code = digits }
                            if digits.count == 6 { Task { await connect() } }
                        }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    Button {
                        Task { await connect() }
                    } label: {
                        Text(busy ? "Bağlanıyor…" : "Bağlan").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || code.count != 6)
                    Text("Eşleşme kalıcıdır; TV kullanıldıkça kendiliğinden uzar.").font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
            }
            .onAppear { focused = true }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.caption.bold()).frame(width: 22, height: 22).background(Theme.accent, in: Circle()).foregroundStyle(.black)
            Text(text).font(.subheadline)
        }
    }

    private func connect() async {
        guard code.count == 6, !busy else { return }
        busy = true
        error = nil
        do {
            try await tv.connect(code: code)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            code = ""
        }
        busy = false
    }
}

// MARK: - Kumanda

struct TvRemoteView: View {
    @EnvironmentObject private var tv: TvRemote
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var scrub: Double?
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusLine
                    if let playing = tv.status?.nowPlaying { nowPlaying(playing) }
                    dpad
                    playbackRow
                    soundRow
                    if tv.status?.nowPlaying?.hasNextEpisode == true {
                        wideButton("Sonraki bölüm", systemImage: "forward.end.fill") { send(["type": "player-next-episode", "playbackId": "cloud"]) }
                    }
                    viewsRow
                    HStack {
                        TextField("TV'de ara (film, dizi)…", text: $search)
                            .submitLabel(.search)
                            .onSubmit(submitSearch)
                            .padding(12)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                        Button("Ara", action: submitSearch).buttonStyle(.borderedProminent)
                    }
                    Button("Bağlantıyı kes", role: .destructive) {
                        tv.disconnect()
                        dismiss()
                    }
                    .font(.footnote)
                    .padding(.top, 6)
                }
                .padding(18)
            }
            .navigationTitle("Kumanda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
            }
            .onAppear { tv.startPolling() }
            .onDisappear { tv.stopPolling() }
            .onReceive(clock) { now = $0 }
        }
    }

    private var statusLine: some View {
        let online = tv.status?.online
        let text: String
        switch online {
        case .none: text = "durum okunuyor…"
        case .some(true): text = "çevrimiçi"
        case .some(false):
            let minutes = tv.status.map { Int((now.timeIntervalSince1970 * 1000 - $0.lastSeenAt) / 60_000) } ?? 0
            text = minutes < 1 ? "az önce görüldü" : minutes < 60 ? "\(minutes) dk önce görüldü" : "TV'de Fenotip açık değil"
        }
        return HStack(spacing: 8) {
            Circle().fill(online == true ? Color.green : Color.gray).frame(width: 9, height: 9)
            Text("\(tv.deviceName) · \(text)").font(.subheadline).foregroundStyle(Theme.muted)
            Spacer()
        }
    }

    private func nowPlaying(_ playing: RemoteNowPlaying) -> some View {
        let live = playing.kind == "live"
        let position = scrub ?? tv.estimatedPosition(at: now)
        return HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(Theme.card)
                .frame(width: 64, height: 92)
                .overlay { RemoteImage(url: playing.artworkUrl.flatMap { URL(string: $0) }) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(live ? "CANLI · ŞİMDİ TV'DE" : playing.paused ? "DURAKLATILDI" : "ŞİMDİ TV'DE")
                    .font(.caption2.weight(.heavy)).tracking(1.5).foregroundStyle(Theme.accent)
                Text(playing.title).font(.headline).lineLimit(2)
                if !live, playing.duration > 0 {
                    Slider(value: Binding(get: { position }, set: { scrub = $0 }), in: 0...playing.duration, onEditingChanged: { editing in
                        if !editing, let target = scrub {
                            send(["type": "player-seek-to", "playbackId": "cloud", "seconds": Int(target)])
                            scrub = nil
                        }
                    })
                    .tint(Theme.accent)
                    HStack {
                        Text(clockText(position))
                        Spacer()
                        Text("-" + clockText(playing.duration - position))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(12)
        .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private var dpad: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                key("arrow.uturn.backward", label: "Geri") { navigate("back") }
                key("chevron.up", label: "Yukarı") { navigate("up") }
                key("house.fill", label: "Ana sayfa") { send(["type": "go-view", "view": "home"]) }
            }
            HStack(spacing: 10) {
                key("chevron.left", label: "Sol") { navigate("left") }
                Button { navigate("enter") } label: {
                    Text("OK").font(.title3.bold()).frame(width: 84, height: 84).background(Theme.accent, in: Circle()).foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                key("chevron.right", label: "Sağ") { navigate("right") }
            }
            HStack(spacing: 10) {
                Color.clear.frame(width: 84, height: 60)
                key("chevron.down", label: "Aşağı") { navigate("down") }
                Color.clear.frame(width: 84, height: 60)
            }
        }
    }

    private var playbackRow: some View {
        let live = tv.status?.nowPlaying?.kind == "live"
        let paused = tv.status?.nowPlaying?.paused ?? false
        return HStack(spacing: 8) {
            if live {
                chip("Kanal −") { send(["type": "live-channel-step", "direction": "previous"]) }
            } else {
                chip("−30") { seek(-30) }
                chip("−10") { seek(-10) }
            }
            chip(paused ? "▶" : "❚❚", prominent: true) { send(["type": "player-toggle-play"]) }
            if live {
                chip("Kanal +") { send(["type": "live-channel-step", "direction": "next"]) }
            } else {
                chip("+10") { seek(10) }
                chip("+30") { seek(30) }
            }
        }
    }

    private var soundRow: some View {
        HStack(spacing: 8) {
            chip("🔉") { send(["type": "player-volume", "direction": "down"]) }
            chip("🔇") { send(["type": "player-mute"]) }
            chip("🔊") { send(["type": "player-volume", "direction": "up"]) }
            chip("CC") { send(["type": "player-subtitle-cycle"]) }
            chip("⛶") { send(["type": "player-fullscreen"]) }
            if tv.status?.nowPlaying != nil { chip("■") { send(["type": "player-stop"]) } }
        }
    }

    private var viewsRow: some View {
        HStack(spacing: 8) {
            ForEach([("live", "Canlı TV"), ("movie", "Filmler"), ("series", "Diziler"), ("my-list", "Listem")], id: \.0) { view, label in
                chip(label) { send(["type": "go-view", "view": view]) }
            }
        }
    }

    private func key(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2.weight(.semibold)).frame(width: 84, height: 60).background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func chip(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(prominent ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(prominent ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }

    private func wideButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    private func send(_ command: [String: Any]) {
        Task { await tv.send(command) }
    }

    private func navigate(_ direction: String) { send(["type": "navigate", "direction": direction]) }
    private func seek(_ seconds: Int) { send(["type": "player-seek", "deltaSeconds": seconds]) }

    private func submitSearch() {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(["type": "search-text", "text": String(text.prefix(80))])
        search = ""
    }

    private func clockText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Ekranın altında kısa bilgi ("Salon TV'de açılıyor…").
struct ToastOverlay: View {
    @EnvironmentObject private var tv: TvRemote

    var body: some View {
        VStack {
            Spacer()
            if let waiting = tv.waiting {
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        ProgressView().tint(.white)
                        Text(waiting).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                    }
                    Button("Vazgeç") { tv.cancelWaiting() }
                        .font(.subheadline.weight(.bold))
                        .buttonStyle(.bordered)
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 20)
                .padding(.bottom, 70)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let message = tv.toast {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { tv.toast = nil }
            }
        }
        .animation(.spring(response: 0.35), value: tv.toast)
        .animation(.spring(response: 0.35), value: tv.waiting)
        .allowsHitTesting(tv.toast != nil || tv.waiting != nil)
    }
}
