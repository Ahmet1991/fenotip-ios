import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch app.stage {
            case .loading:
                VStack(spacing: 24) {
                    BrandLogo(height: 44)
                    ProgressView().tint(.white)
                }
            case .login:
                LoginView()
            case .profiles:
                ProfilePickerView()
            case .ready:
                MainTabView()
            case .offline(let message):
                VStack(spacing: 18) {
                    BrandLogo(height: 40)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.muted).padding(.horizontal, 32)
                    Button("Tekrar dene") { Task { await app.start() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .overlay { ToastOverlay() }
        .task { await app.start() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await app.refreshState() } }
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @State private var pin = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            BrandLogo(height: 48)
            Text("Devam etmek için PIN kodunu gir.").foregroundStyle(Theme.muted)
            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit())
                .padding(.vertical, 14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 260)
            if let error {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            Button {
                Task { await submit() }
            } label: {
                Text(busy ? "Kontrol ediliyor…" : "Giriş yap").frame(maxWidth: 260).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || pin.isEmpty)
        }
        .padding(24)
    }

    private func submit() async {
        busy = true
        error = nil
        do {
            try await app.login(pin: pin)
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}

struct ProfilePickerView: View {
    @EnvironmentObject private var app: AppModel
    @State private var error: String?
    @State private var busyId: String?
    @State private var locked: Profile?
    @State private var unlockPin = ""

    var body: some View {
        VStack(spacing: 28) {
            BrandLogo(height: 40)
            Text("Kim izliyor?").font(.title.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 20)], spacing: 20) {
                ForEach(app.profiles) { profile in
                    Button {
                        Task { await choose(profile) }
                    } label: {
                        VStack(spacing: 10) {
                            Text(profile.emoji)
                                .font(.system(size: 54))
                                .frame(width: 100, height: 100)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                                .overlay {
                                    if busyId == profile.id { ProgressView().tint(.white) }
                                }
                            Text(profile.name).font(.headline).foregroundStyle(.white)
                            if profile.policy?.mode == "child" {
                                Text("Çocuk").font(.caption2).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            if let error {
                Text(error).foregroundStyle(.red).font(.footnote).multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        }
        .alert("Profil kilidi", isPresented: Binding(get: { locked != nil }, set: { if !$0 { locked = nil } })) {
            SecureField("Profil PIN'i", text: $unlockPin).keyboardType(.numberPad)
            Button("Aç") {
                let target = locked
                locked = nil
                if let target { Task { await unlock(target) } }
            }
            Button("Vazgeç", role: .cancel) { unlockPin = "" }
        } message: {
            Text("Çocuk profilinden çıkmak için profil kilit PIN'ini gir.")
        }
    }

    private func unlock(_ profile: Profile) async {
        busyId = profile.id
        error = nil
        do {
            try await app.unlockAndChoose(profile, pin: unlockPin)
        } catch {
            self.error = error.localizedDescription
        }
        unlockPin = ""
        busyId = nil
    }

    private func choose(_ profile: Profile) async {
        busyId = profile.id
        error = nil
        do {
            try await app.choose(profile)
        } catch let failure as ServerError where failure.code == "PROFILE_UNLOCK_REQUIRED" {
            locked = profile
        } catch {
            self.error = error.localizedDescription
        }
        busyId = nil
    }
}

struct MainTabView: View {
    @EnvironmentObject private var tv: TvRemote
    @State private var selection = 0

    var body: some View {
        TabView(selection: selectionBinding) {
            NavigationStack { HomeView() }
                .tabItem { Label("Ana Sayfa", systemImage: "house.fill") }
                .tag(0)
            NavigationStack { LibraryView(kind: .movie) }
                .tabItem { Label("Filmler", systemImage: "film") }
                .tag(1)
            NavigationStack { LibraryView(kind: .series) }
                .tabItem { Label("Diziler", systemImage: "tv") }
                .tag(2)
            NavigationStack { LiveView() }
                .tabItem { Label("Canlı TV", systemImage: "dot.radiowaves.left.and.right") }
                .tag(3)
            NavigationStack { SearchView() }
                .tabItem { Label("Ara", systemImage: "magnifyingglass") }
                .tag(4)
        }
        .sheet(isPresented: $tv.showPairing) { TvPairingView().environmentObject(tv) }
        .sheet(isPresented: $tv.showRemote) { TvRemoteView().environmentObject(tv) }
    }

    private var selectionBinding: Binding<Int> {
        Binding(
            get: { selection },
            set: { next in
                if next == selection, next == 0 {
                    NotificationCenter.default.post(name: .fenotipHomeTabReselected, object: nil)
                }
                selection = next
            }
        )
    }
}

/// Uygulama logosu (Assets: Logo); yoksa yazıyla.
struct BrandLogo: View {
    var height: CGFloat = 28

    var body: some View {
        if UIImage(named: "Logo") != nil {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: height * 5.5, height: height)
        } else {
            Text("fenotip")
                .font(.system(size: height * 0.8, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
