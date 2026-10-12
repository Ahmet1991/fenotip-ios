import MobileVLCKit
import MediaPlayer
import UIKit

enum FinishReason: Equatable {
    /// tv: kullanıcı "TV'ye aktar" dedi; içerik kaldığı yerden TV'de açılır.
    case user, ended, next, error, retry, reconnect, sleep, tv, previousChannel, nextChannel
    /// Oynatıcıdaki "Bölümler" listesinden seçilen bölüm.
    case episode(String)
}

/// Ses/altyazı izinin dili: VLC iz adından ("Track 1 - [English]", "Türkçe") sitedeki kısa koda.
enum TrackLanguage {
    private static let words: [String: [String]] = [
        "tr": ["turkish", "türkçe", "turkce", "tur", "tr"],
        "en": ["english", "ingilizce", "eng", "en"],
        "de": ["german", "deutsch", "almanca", "ger", "deu", "de"],
        "fr": ["french", "français", "francais", "fransızca", "fre", "fra", "fr"],
        "es": ["spanish", "español", "espanol", "ispanyolca", "spa", "es"],
        "it": ["italian", "italiano", "italyanca", "ita", "it"],
        "ru": ["russian", "русский", "rusça", "rus", "ru"],
        "ar": ["arabic", "arapça", "ara", "ar"],
        "ja": ["japanese", "japonca", "jpn", "ja"],
        "ko": ["korean", "korece", "kor", "ko"],
        "hi": ["hindi", "hin", "hi"],
        "pt": ["portuguese", "português", "portekizce", "por", "pt"],
    ]

    /// İz adındaki dil kodu; bilinmiyorsa nil.
    static func code(of name: String) -> String? {
        let tokens = Set(name.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        return words.first { _, list in list.contains { tokens.contains($0) } }?.key
    }

    /// Profilde kayıtlı tercih ("en", "eng", "English") → kısa kod.
    static func normalize(_ value: String?) -> String? {
        guard let value = value?.lowercased(), !value.isEmpty else { return nil }
        if words[value] != nil { return value }
        return words.first { _, list in list.contains(value) }?.key
    }
}

/// VLC oynatıcı: sağlayıcı adresini doğrudan açar (jetonlu yönlendirmeyi kendisi izler); MKV,
/// AC-3/E-AC-3 ses ve gömülü altyazı dönüştürmeden çalışır.
final class PlayerViewController: UIViewController, VLCMediaPlayerDelegate, UIGestureRecognizerDelegate {
    var onProgress: ((Double, Double) -> Void)?
    var onFinish: ((Double, Double, FinishReason) -> Void)?
    /// Kullanıcı ses/altyazı/hız seçince profile yazılacak değişiklik (PC ile ortak tercih).
    var onPreferences: (([String: Any]) -> Void)?

    private let item: PlaybackItem
    private let url: URL
    private let preferences: PlaybackPreferences
    private let allowAutomaticReconnect: Bool
    private var audioApplied = false
    private var subtitleApplied = false
    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    /// VLC çizim alanına kendi dokunma algılayıcısını ekliyor ve dokunuşları yutuyor; video ile denetimler
    /// arasındaki bu şeffaf katman dokunuşları bize bırakır.
    private let touchLayer = UIView()
    private let overlay = UIView()
    private let seekBadge = UILabel()
    private let resumeButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let volumeView = MPVolumeView(frame: .zero)
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let tvButton = UIButton(type: .system)
    private let fillButton = UIButton(type: .system)
    private let lockButton = UIButton(type: .system)
    private let rotationButton = UIButton(type: .system)
    private let sleepButton = UIButton(type: .system)
    private let delayButton = UIButton(type: .system)
    private let episodesButton = UIButton(type: .system)
    /// Dizinin son 30 saniyesinde videonun üstünde (denetimler gizliyken de) görünen düğme.
    private let upNextButton = UIButton(type: .system)
    private enum VideoMode: Int, CaseIterable {
        case fit, fill, ratio16x9, ratio4x3
    }
    private enum TouchMode {
        case undecided, brightness, volume, seek, longPress
    }
    private var videoMode: VideoMode = .fit
    private var videoModeSize: CGSize = .zero
    private let speedButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()
    private var hideTimer: Timer?
    private var progressTimer: Timer?
    private var startTimer: Timer?
    private var sleepTimer: Timer?
    private var scrubbing = false
    private var finished = false
    private var started = false
    private var position: Double = 0
    private var duration: Double = 0
    private var showingFinishTime = false
    private var sleepAtEpisodeEnd = false
    private var screenLocked = false
    private var landscapeLocked = false
    private var restartFromBeginningRequested = false
    private var originalBrightness: CGFloat = UIScreen.main.brightness
    private var touchStartPoint: CGPoint = .zero
    private var touchStartTime: TimeInterval = 0
    private var touchStartBrightness: CGFloat = 0
    private var touchStartVolume: Float = 0
    private var touchStartPosition: Double = 0
    private var touchMode: TouchMode = .undecided
    private var seekPreviewTarget: Double?
    private var temporaryRate: Float?
    private var pendingLongPress: DispatchWorkItem?
    private var playbackFailureHandled = false
    private var wasPlayingBeforeBackground = false

    private var isLive: Bool { item.kind == .live }
    private var seekBadgeCenter: NSLayoutConstraint!
    private var lastLoggedState = -1
    /// Ses/altyazı düğmeleri (denetimlerle birlikte açılıp kapanır; ✕ hep görünür).
    private weak var topBar: UIView?
    /// Kullanıcı duraklattıysa denetimler açık kalır.
    private var userPaused = false
    /// Tek dokunuş, çift dokunuş olmadığı anlaşılınca (kısa bekleme) işlenir.
    private var pendingTap: DispatchWorkItem?
    private var doubleTapSeconds: Int { PlayerDeviceSettings.doubleTapSeekSeconds }

    init(item: PlaybackItem, url: URL, preferences: PlaybackPreferences = .empty, allowAutomaticReconnect: Bool = true) {
        self.item = item
        self.url = url
        self.preferences = preferences
        self.allowAutomaticReconnect = allowAutomaticReconnect
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) kullanılmıyor")
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { landscapeLocked ? .landscape : .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewDidLoad() {
        super.viewDidLoad()
        originalBrightness = UIScreen.main.brightness
        Diagnostics.shared.log("oynatıcı açıldı \(item.kind.rawValue) \(item.contentId) ext=\(item.ext ?? "-") başlangıç=\(Int(item.startAt))")
        view.backgroundColor = .black
        buildLayout()

        player.delegate = self
        player.drawable = videoView
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=3000")
        media.addOption(":http-reconnect")
        if item.startAt > 5 { media.addOption(":start-time=\(Int(item.startAt))") }
        // Altyazı boyutu (Ayarlar). VLCKit sürümünde varsa metin çiziciye verilir.
        media.addOption(":freetype-rel-fontsize=\(SubtitleSize.current.rawValue)")
        let fontSizeSelector = NSSelectorFromString("setTextRendererFontSize:")
        if player.responds(to: fontSizeSelector) {
            player.perform(fontSizeSelector, with: NSNumber(value: SubtitleSize.current.rawValue))
        }
        player.media = media
        player.play()
        if !isLive, let rate = preferences.playbackRate, rate >= 0.5, rate <= 2, rate != 1 {
            player.rate = Float(rate)
        }
        updateSpeedTitle()
        spinner.startAnimating()

        UIApplication.shared.isIdleTimerDisabled = true
        progressTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.reportProgress()
        }
        // Sağlayıcı yanıt vermezse sonsuza kadar beklemesin.
        startTimer = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { [weak self] _ in
            guard let self, !self.started else { return }
            self.handlePlaybackFailure("Yayın 35 saniyede başlamadı. Bağlantıyı kontrol edip tekrar dene.")
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        if item.startAt >= 10, !isLive {
            resumeButton.setTitle("Kaldığın yerden devam: \(format(item.startAt)) · Baştan başla", for: .normal)
            resumeButton.isHidden = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.resumeButton.isHidden = true }
        }
        scheduleHide()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        UIScreen.main.brightness = originalBrightness
    }

    // MARK: Yerleşim

    private func buildLayout() {
        for subview in [videoView, touchLayer, overlay, upNextButton, seekBadge, resumeButton, retryButton, closeButton, lockButton, spinner, messageLabel, volumeView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        touchLayer.backgroundColor = .clear
        touchLayer.isUserInteractionEnabled = true
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        volumeView.showsRouteButton = false
        volumeView.alpha = 0.001
        volumeView.isUserInteractionEnabled = false
        seekBadge.textColor = .white
        seekBadge.font = .systemFont(ofSize: 17, weight: .bold)
        seekBadge.textAlignment = .center
        seekBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        seekBadge.layer.cornerRadius = 22
        seekBadge.layer.masksToBounds = true
        seekBadge.alpha = 0
        spinner.color = .white
        spinner.hidesWhenStopped = true
        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.isHidden = true

        resumeButton.setTitleColor(.white, for: .normal)
        resumeButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        resumeButton.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        resumeButton.layer.cornerRadius = 18
        resumeButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        resumeButton.addTarget(self, action: #selector(restartFromBeginningTapped), for: .touchUpInside)
        resumeButton.isHidden = true

        configure(retryButton, symbol: "arrow.clockwise", size: 16, action: #selector(retryTapped))
        retryButton.setTitle(" Tekrar dene", for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        retryButton.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        retryButton.layer.cornerRadius = 18
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        retryButton.isHidden = true

        configure(subtitleButton, symbol: "captions.bubble", size: 18, action: #selector(subtitlesTapped))
        configure(audioButton, symbol: "speaker.wave.2", size: 18, action: #selector(audioTapped))
        configure(tvButton, symbol: "tv", size: 18, action: #selector(tvTapped))
        configure(speedButton, symbol: "gauge.with.dots.needle.67percent", size: 16, action: #selector(speedTapped))
        configure(fillButton, symbol: "arrow.up.left.and.arrow.down.right", size: 15, action: #selector(fillTapped))
        configure(lockButton, symbol: "lock.open", size: 15, action: #selector(lockTapped))
        configure(rotationButton, symbol: "rotate.right", size: 15, action: #selector(rotationTapped))
        configure(sleepButton, symbol: "moon.zzz", size: 15, action: #selector(sleepTapped))
        configure(delayButton, symbol: "waveform.path", size: 15, action: #selector(delayTapped))
        configure(episodesButton, symbol: "list.bullet.rectangle", size: 15, action: #selector(episodesTapped))
        episodesButton.isHidden = item.kind != .series || item.episodes.count < 2
        speedButton.isHidden = isLive
        delayButton.isHidden = isLive
        for (button, title) in [
            (subtitleButton, " Altyazı"), (audioButton, " Ses"), (tvButton, " TV"), (speedButton, ""),
            (fillButton, " Sığdır"), (episodesButton, " Bölümler"), (lockButton, " Kilit"),
            (rotationButton, " Serbest"), (sleepButton, " Uyku"), (delayButton, " Senkron"),
        ] {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.backgroundColor = UIColor.white.withAlphaComponent(0.16)
            button.layer.cornerRadius = 18
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 14)
        }
        configure(closeButton, symbol: "xmark", size: 22, action: #selector(closeTapped))
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        closeButton.layer.cornerRadius = 22
        configure(backButton, symbol: "gobackward.10", size: 30, action: #selector(backTapped))
        configure(playButton, symbol: "pause.fill", size: 42, action: #selector(playTapped))
        configure(forwardButton, symbol: "goforward.10", size: 30, action: #selector(forwardTapped))
        configure(nextButton, symbol: "forward.end.fill", size: 20, action: #selector(nextTapped))
        nextButton.setTitle(" Sonraki bölüm", for: .normal)
        nextButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        nextButton.isHidden = item.nextEpisode == nil

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateTitle()

        elapsedLabel.textColor = .white
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        elapsedLabel.text = isLive ? "● CANLI" : "0:00"
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        remainingButton.setTitleColor(.white, for: .normal)
        remainingButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        remainingButton.setTitle(isLive ? "" : "0:00", for: .normal)
        remainingButton.addTarget(self, action: #selector(remainingTapped), for: .touchUpInside)
        remainingButton.setContentHuggingPriority(.required, for: .horizontal)
        remainingButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        remainingButton.isHidden = isLive
        slider.minimumTrackTintColor = UIColor(red: 0.80, green: 0.64, blue: 0.38, alpha: 1)
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.addTarget(self, action: #selector(scrubStarted), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.isHidden = isLive
        if isLive {
            // Canlıda geri/ileri düğmeleri kanal değiştirir (açıldığı listede).
            let hasChannels = item.channels.count > 1
            backButton.isHidden = !hasChannels
            forwardButton.isHidden = !hasChannels
            let symbol = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
            backButton.setImage(UIImage(systemName: "backward.end.fill", withConfiguration: symbol), for: .normal)
            forwardButton.setImage(UIImage(systemName: "forward.end.fill", withConfiguration: symbol), for: .normal)
            backButton.accessibilityLabel = "Önceki kanal"
            forwardButton.accessibilityLabel = "Sonraki kanal"
        }
        configure(upNextButton, symbol: "forward.end.fill", size: 15, action: #selector(nextTapped))
        upNextButton.setTitle(" Sonraki bölüm", for: .normal)
        upNextButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        upNextButton.tintColor = .black
        upNextButton.backgroundColor = .white
        upNextButton.layer.cornerRadius = 22
        upNextButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)
        upNextButton.isHidden = true

        // Kritik üst denetimler oynatma katmanından bağımsızdır: VLC dokunuşları yutsa veya
        // otomatik gizleme çalışsa bile çıkış, altyazı ve ses her an erişilebilir kalsın.
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let topActions = UIStackView(arrangedSubviews: [subtitleButton, audioButton])
        topActions.axis = .horizontal
        topActions.spacing = 12
        topActions.alignment = .center
        topActions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topActions)
        topBar = topActions
        // TV'ye aktar ve hız: denetimlerle birlikte görünür (sağ üstte, ses/altyazının altında).
        let extras = UIStackView(arrangedSubviews: [episodesButton, tvButton, speedButton, fillButton])
        extras.axis = .horizontal
        extras.spacing = 12
        extras.alignment = .center
        extras.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(extras)
        let secondaryExtras = UIStackView(arrangedSubviews: [rotationButton, sleepButton, delayButton])
        secondaryExtras.axis = .horizontal
        secondaryExtras.spacing = 12
        secondaryExtras.alignment = .center
        secondaryExtras.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(secondaryExtras)
        let center = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        center.axis = .horizontal
        center.spacing = 48
        center.alignment = .center
        let bottom = UIStackView(arrangedSubviews: [elapsedLabel, slider, remainingButton, nextButton])
        bottom.axis = .horizontal
        bottom.spacing = 12
        bottom.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(titleLabel)
        for stack in [center, bottom] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(stack)
        }

        let guide = view.safeAreaLayoutGuide
        seekBadgeCenter = seekBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            touchLayer.topAnchor.constraint(equalTo: view.topAnchor),
            touchLayer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            touchLayer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            touchLayer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            seekBadge.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            seekBadge.widthAnchor.constraint(equalToConstant: 190),
            seekBadge.heightAnchor.constraint(equalToConstant: 44),
            seekBadgeCenter,
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -24),
            retryButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 18),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            resumeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 58),
            resumeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            lockButton.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 10),
            lockButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            topActions.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            topActions.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topActions.leadingAnchor, constant: -12),
            center.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            bottom.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            subtitleButton.heightAnchor.constraint(equalToConstant: 38),
            audioButton.heightAnchor.constraint(equalToConstant: 38),
            tvButton.heightAnchor.constraint(equalToConstant: 38),
            speedButton.heightAnchor.constraint(equalToConstant: 38),
            fillButton.heightAnchor.constraint(equalToConstant: 38),
            episodesButton.heightAnchor.constraint(equalToConstant: 38),
            lockButton.heightAnchor.constraint(equalToConstant: 38),
            rotationButton.heightAnchor.constraint(equalToConstant: 38),
            sleepButton.heightAnchor.constraint(equalToConstant: 38),
            delayButton.heightAnchor.constraint(equalToConstant: 38),
            upNextButton.heightAnchor.constraint(equalToConstant: 44),
            upNextButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            upNextButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -64),
            extras.topAnchor.constraint(equalTo: topActions.bottomAnchor, constant: 10),
            extras.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            secondaryExtras.topAnchor.constraint(equalTo: extras.bottomAnchor, constant: 10),
            secondaryExtras.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            volumeView.widthAnchor.constraint(equalToConstant: 1),
            volumeView.heightAnchor.constraint(equalToConstant: 1),
            volumeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            volumeView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Video üstündeki bütün hareketler touchesBegan/Moved/Ended ile işlenir; VLC çizim alanında
        // UIGestureRecognizer cihazda güvenilir çalışmıyor.
    }

    private func configure(_ button: UIButton, symbol: String, size: CGFloat, action: Selector) {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        button.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private var systemVolumeSlider: UISlider? {
        volumeView.layoutIfNeeded()
        return volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func showBadge(_ text: String, offset: CGFloat = 0) {
        seekBadge.layer.removeAllAnimations()
        seekBadgeCenter.constant = offset
        seekBadge.text = text
        seekBadge.alpha = 1
        view.layoutIfNeeded()
    }

    private func hideBadge(after delay: TimeInterval = 0.45) {
        UIView.animate(withDuration: 0.25, delay: delay, options: [.beginFromCurrentState]) {
            self.seekBadge.alpha = 0
        }
    }

    private func updateTitle() {
        switch item.kind {
        case .series:
            if let episode = item.episodes.first(where: { $0.id == item.contentId }) {
                titleLabel.text = "S\(episode.season) B\(episode.number) · \(episode.title)"
            } else {
                titleLabel.text = item.title
            }
        case .live:
            let program = item.programTitle ?? item.title
            if let end = item.programEnd, end > Date().timeIntervalSince1970 {
                let minutes = max(1, Int(ceil((end - Date().timeIntervalSince1970) / 60)))
                titleLabel.text = "\(program) · \(minutes) dk kaldı"
            } else {
                titleLabel.text = program
            }
        case .movie:
            titleLabel.text = item.title
        }
    }

    private func updateTimeLabels() {
        guard !isLive else { return }
        elapsedLabel.text = format(position)
        guard duration > 0 else {
            remainingButton.setTitle("", for: .normal)
            return
        }
        if showingFinishTime {
            let rate = max(0.1, Double(player.rate == 0 ? 1 : player.rate))
            let finish = Date().addingTimeInterval(max(0, duration - position) / rate)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            remainingButton.setTitle("Bitiş \(formatter.string(from: finish))", for: .normal)
        } else {
            remainingButton.setTitle("-" + format(max(0, duration - position)), for: .normal)
        }
        slider.value = Float(min(1, max(0, position / duration)))
    }

    private func updateTrackButtonTitles() {
        let audioNames = player.audioTrackNames as? [String] ?? []
        let audioIndexes = player.audioTrackIndexes as? [NSNumber] ?? []
        if let name = zip(audioNames, audioIndexes).first(where: { $0.1.int32Value == player.currentAudioTrackIndex })?.0,
           let code = TrackLanguage.code(of: name) {
            audioButton.setTitle(" Ses · \(code.uppercased())", for: .normal)
        } else {
            audioButton.setTitle(" Ses", for: .normal)
        }

        guard player.currentVideoSubTitleIndex >= 0 else {
            subtitleButton.setTitle(" Altyazı · Kapalı", for: .normal)
            return
        }
        let subtitleNames = player.videoSubTitlesNames as? [String] ?? []
        let subtitleIndexes = player.videoSubTitlesIndexes as? [NSNumber] ?? []
        if let name = zip(subtitleNames, subtitleIndexes).first(where: { $0.1.int32Value == player.currentVideoSubTitleIndex })?.0,
           let code = TrackLanguage.code(of: name) {
            subtitleButton.setTitle(" Altyazı · \(code.uppercased())", for: .normal)
        } else {
            subtitleButton.setTitle(" Altyazı", for: .normal)
        }
    }

    /// Çift dokunuş: sol yarı geri, sağ yarı ileri; miktar cihaz ayarından gelir.
    private func doubleTapSeek(at x: CGFloat) {
        guard !isLive else { return }
        let forward = x > view.bounds.width / 2
        let seconds = Int32(doubleTapSeconds)
        if forward { player.jumpForward(seconds) } else { player.jumpBackward(seconds) }
        showBadge(forward ? "+\(doubleTapSeconds) sn ›" : "‹ −\(doubleTapSeconds) sn", offset: (forward ? 1 : -1) * view.bounds.width / 4)
        haptic()
        hideBadge(after: 0.6)
        Diagnostics.shared.log("çift dokunuş sarma: \(forward ? "+" : "-")\(doubleTapSeconds) sn")
    }

    // MARK: Denetimler

    @objc private func closeTapped() { finish(.user) }
    @objc private func tvTapped() { finish(.tv) }

    @objc private func speedTapped() {
        let sheet = UIAlertController(title: "Oynatma hızı", message: nil, preferredStyle: .actionSheet)
        for rate in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0] {
            let mark = abs(Double(player.rate) - rate) < 0.01 ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: "\(mark)\(speedText(rate))", style: .default) { [weak self] _ in
                guard let self else { return }
                self.player.rate = Float(rate)
                self.updateSpeedTitle()
                self.onPreferences?(["playbackRate": rate])
                self.haptic()
                Diagnostics.shared.log("oynatma hızı seçildi: \(self.speedText(rate))")
            })
        }
        presentSheet(sheet, from: speedButton)
    }

    private func speedText(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : String(format: "%gx", rate)
    }

    private func updateSpeedTitle() {
        speedButton.setTitle(" " + speedText(Double(player.rate == 0 ? 1 : player.rate)), for: .normal)
    }
    @objc private func nextTapped() { finish(.next) }

    @objc private func playTapped() {
        if player.isPlaying {
            player.pause()
            userPaused = true
        } else {
            player.play()
            userPaused = false
        }
        scheduleHide()
    }

    /// Bu sezonun bölümleri; seçilen bölüm kaldığı yerden açılır.
    @objc private func episodesTapped() {
        let season = item.episodes.first { $0.id == item.contentId }?.season
        let list = item.episodes.filter { $0.season == season }
        let sheet = UIAlertController(title: season.map { "\($0). Sezon" } ?? "Bölümler", message: nil, preferredStyle: .actionSheet)
        for episode in list {
            let mark = episode.id == item.contentId ? "▶ " : ""
            sheet.addAction(UIAlertAction(title: "\(mark)\(episode.number). \(episode.title)", style: .default) { [weak self] _ in
                guard let self, episode.id != self.item.contentId else { return }
                self.finish(.episode(episode.id))
            })
        }
        presentSheet(sheet, from: episodesButton)
    }

    @objc private func fillTapped() {
        let modes = VideoMode.allCases
        videoMode = modes[(videoMode.rawValue + 1) % modes.count]
        applyVideoMode()
        updateVideoModeButton()
        haptic()
        Diagnostics.shared.log("görüntü modu: \(videoModeTitle)")
        scheduleHide()
    }

    private var videoModeTitle: String {
        switch videoMode {
        case .fit: return "Sığdır"
        case .fill: return "Doldur"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        }
    }

    private func updateVideoModeButton() {
        fillButton.setTitle(" \(videoModeTitle)", for: .normal)
    }

    /// VLC görüntüyü seçilen oran/kırpma moduna getirir; döndürmede yeniden uygulanır.
    private func applyVideoMode() {
        let size = view.bounds.size
        videoModeSize = size
        player.videoAspectRatio = nil
        player.videoCropGeometry = nil
        guard size.width > 0, size.height > 0 else { return }
        switch videoMode {
        case .fit:
            break
        case .fill:
            player.videoCropGeometry = strdup("\(Int(size.width.rounded())):\(Int(size.height.rounded()))")
        case .ratio16x9:
            player.videoAspectRatio = strdup("16:9")
        case .ratio4x3:
            player.videoAspectRatio = strdup("4:3")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.size != videoModeSize { applyVideoMode() }
    }

    @objc private func lockTapped() {
        screenLocked.toggle()
        pendingTap?.cancel()
        pendingLongPress?.cancel()
        let symbol = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        lockButton.setImage(UIImage(systemName: screenLocked ? "lock.fill" : "lock.open", withConfiguration: symbol), for: .normal)
        lockButton.setTitle(screenLocked ? " Kilitli" : " Kilit", for: .normal)
        closeButton.isHidden = screenLocked
        if screenLocked {
            hideTimer?.invalidate()
            overlay.alpha = 0
            overlay.isUserInteractionEnabled = false
            topBar?.alpha = 0
            topBar?.isUserInteractionEnabled = false
            lockButton.alpha = 1
            lockButton.isUserInteractionEnabled = true
            upNextButton.isHidden = true
        } else {
            setControls(visible: true)
        }
        haptic(.medium)
        Diagnostics.shared.log("ekran kilidi: \(screenLocked ? "açık" : "kapalı")")
    }

    @objc private func rotationTapped() {
        landscapeLocked.toggle()
        rotationButton.setTitle(landscapeLocked ? " Yatay kilit" : " Serbest", for: .normal)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        if landscapeLocked, let scene = view.window?.windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
                Diagnostics.shared.log("döndürme kilidi hatası: \(error.localizedDescription)")
            }
        }
        haptic()
        Diagnostics.shared.log("döndürme kilidi: \(landscapeLocked ? "yatay" : "serbest")")
        scheduleHide()
    }

    @objc private func sleepTapped() {
        let sheet = UIAlertController(title: "Uyku zamanlayıcısı", message: nil, preferredStyle: .actionSheet)
        for minutes in [15, 30, 45, 60] {
            sheet.addAction(UIAlertAction(title: "\(minutes) dakika", style: .default) { [weak self] _ in
                self?.setSleepTimer(minutes: minutes)
            })
        }
        if item.kind == .series {
            sheet.addAction(UIAlertAction(title: "Bölüm sonunda", style: .default) { [weak self] _ in
                guard let self else { return }
                self.sleepTimer?.invalidate()
                self.sleepTimer = nil
                self.sleepAtEpisodeEnd = true
                self.sleepButton.setTitle(" Bölüm sonu", for: .normal)
                self.haptic()
                Diagnostics.shared.log("uyku zamanlayıcısı: bölüm sonunda")
            })
        }
        if sleepTimer != nil || sleepAtEpisodeEnd {
            sheet.addAction(UIAlertAction(title: "Zamanlayıcıyı kapat", style: .destructive) { [weak self] _ in
                self?.cancelSleepTimer()
            })
        }
        presentSheet(sheet, from: sleepButton)
    }

    private func setSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        sleepAtEpisodeEnd = false
        sleepButton.setTitle(" \(minutes) dk", for: .normal)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            guard let self, !self.finished else { return }
            Diagnostics.shared.log("uyku zamanlayıcısı doldu")
            self.reportProgress()
            self.finish(.sleep)
        }
        haptic()
        Diagnostics.shared.log("uyku zamanlayıcısı: \(minutes) dk")
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepAtEpisodeEnd = false
        sleepButton.setTitle(" Uyku", for: .normal)
        haptic()
        Diagnostics.shared.log("uyku zamanlayıcısı kapatıldı")
    }

    @objc private func delayTapped() {
        let sheet = UIAlertController(title: "Ses / altyazı senkronu", message: "0,25 sn adımlarla ayarla", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Altyazı −0,25 sn", style: .default) { [weak self] _ in self?.adjustDelay(subtitle: true, delta: -250_000) })
        sheet.addAction(UIAlertAction(title: "Altyazı +0,25 sn", style: .default) { [weak self] _ in self?.adjustDelay(subtitle: true, delta: 250_000) })
        sheet.addAction(UIAlertAction(title: "Ses −0,25 sn", style: .default) { [weak self] _ in self?.adjustDelay(subtitle: false, delta: -250_000) })
        sheet.addAction(UIAlertAction(title: "Ses +0,25 sn", style: .default) { [weak self] _ in self?.adjustDelay(subtitle: false, delta: 250_000) })
        sheet.addAction(UIAlertAction(title: "Gecikmeleri sıfırla", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.player.currentVideoSubTitleDelay = 0
            self.player.currentAudioPlaybackDelay = 0
            self.showBadge("Senkron 0,00 sn")
            self.hideBadge()
            self.haptic()
            Diagnostics.shared.log("ses/altyazı gecikmesi sıfırlandı")
        })
        presentSheet(sheet, from: delayButton)
    }

    private func adjustDelay(subtitle: Bool, delta: Int) {
        let value: Int
        if subtitle {
            player.currentVideoSubTitleDelay += delta
            value = player.currentVideoSubTitleDelay
        } else {
            player.currentAudioPlaybackDelay += delta
            value = player.currentAudioPlaybackDelay
        }
        let seconds = Double(value) / 1_000_000
        showBadge("\(subtitle ? "Altyazı" : "Ses") \(String(format: "%+.2f", seconds)) sn")
        hideBadge()
        haptic()
        Diagnostics.shared.log("\(subtitle ? "altyazı" : "ses") gecikmesi: \(value) us")
    }

    @objc private func remainingTapped() {
        showingFinishTime.toggle()
        updateTimeLabels()
        haptic()
    }

    @objc private func restartFromBeginningTapped() {
        restartFromBeginningRequested = true
        resumeButton.isHidden = true
        if duration > 0 {
            restartFromBeginningRequested = false
            player.position = 0
            position = 0
            updateTimeLabels()
        }
        haptic()
        Diagnostics.shared.log("kaldığın yer bildirimi: baştan başla")
    }

    @objc private func retryTapped() {
        haptic()
        Diagnostics.shared.log("oynatma hatası: kullanıcı tekrar deniyor")
        finish(.retry)
    }

    @objc private func backTapped() {
        if isLive {
            finish(.previousChannel)
            return
        }
        player.jumpBackward(10)
        haptic()
        scheduleHide()
    }

    @objc private func forwardTapped() {
        if isLive {
            finish(.nextChannel)
            return
        }
        player.jumpForward(10)
        haptic()
        scheduleHide()
    }

    @objc private func toggleControls() {
        guard !screenLocked else { return }
        Diagnostics.shared.log("dokunuş: denetimler \(overlay.alpha < 0.5 ? "açılıyor" : "kapanıyor")")
        setControls(visible: overlay.alpha < 0.5)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first, !(touch.view is UIControl), !finished, !screenLocked else { return }
        pendingLongPress?.cancel()
        touchStartPoint = touch.location(in: view)
        touchStartTime = touch.timestamp
        touchStartBrightness = UIScreen.main.brightness
        touchStartVolume = systemVolumeSlider?.value ?? 0
        touchStartPosition = position
        touchMode = .undecided
        seekPreviewTarget = nil

        guard !isLive else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.touchMode == .undecided, !self.finished, !self.screenLocked else { return }
            self.touchMode = .longPress
            self.temporaryRate = self.player.rate == 0 ? 1 : self.player.rate
            self.player.rate = 2
            self.showBadge("2x · Basılı tut")
            self.haptic(.medium)
            Diagnostics.shared.log("uzun basma: geçici 2x")
        }
        pendingLongPress = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first, !finished, !screenLocked else { return }
        let point = touch.location(in: view)
        let dx = point.x - touchStartPoint.x
        let dy = point.y - touchStartPoint.y

        if touchMode == .undecided, hypot(dx, dy) > 14 {
            pendingLongPress?.cancel()
            if abs(dx) > abs(dy) * 1.15, !isLive {
                touchMode = .seek
            } else {
                touchMode = touchStartPoint.x < view.bounds.midX ? .brightness : .volume
            }
        }

        switch touchMode {
        case .brightness:
            let delta = -dy / max(120, view.bounds.height * 0.7)
            let value = min(1, max(0, touchStartBrightness + delta))
            UIScreen.main.brightness = value
            showBadge("Parlaklık %\(Int((value * 100).rounded()))")
        case .volume:
            guard let volume = systemVolumeSlider else { return }
            let delta = Float(-dy / max(120, view.bounds.height * 0.7))
            let value = min(1, max(0, touchStartVolume + delta))
            volume.setValue(value, animated: false)
            volume.sendActions(for: .valueChanged)
            showBadge("Ses %\(Int((value * 100).rounded()))")
        case .seek:
            guard duration > 0 else {
                showBadge("Sarma hazır değil")
                return
            }
            let target = min(duration, max(0, touchStartPosition + Double(dx) * 0.5))
            seekPreviewTarget = target
            let difference = Int((target - touchStartPosition).rounded())
            let sign = difference >= 0 ? "+" : "−"
            showBadge("\(format(target)) · \(sign)\(abs(difference)) sn")
        case .undecided, .longPress:
            break
        }
    }

    /// Videoya dokunuş: tek/çift dokunma, yatay-dikey kaydırma ve uzun basma aynı touch akışındadır.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = touches.first, !(touch.view is UIControl), !finished, !screenLocked else { return }
        pendingLongPress?.cancel()
        let point = touch.location(in: view)
        let dx = point.x - touchStartPoint.x
        let dy = point.y - touchStartPoint.y
        let elapsed = max(0.001, touch.timestamp - touchStartTime)

        // Mevcut aşağı kaydırıp kapatma korunur; güçlü ve kısa aşağı hareket çıkış sayılır.
        if dy > 150, abs(dy) > abs(dx) * 1.2, elapsed < 0.9 {
            restoreTemporaryRate()
            Diagnostics.shared.log("aşağı kaydırma: oynatıcı kapanıyor")
            finish(.user)
            return
        }

        switch touchMode {
        case .longPress:
            restoreTemporaryRate()
            hideBadge(after: 0.15)
            scheduleHide()
            return
        case .seek:
            if let target = seekPreviewTarget, duration > 0 {
                player.position = Float(target / duration)
                position = target
                updateTimeLabels()
                haptic()
                Diagnostics.shared.log("yatay sarma: \(Int(target)) sn")
            }
            hideBadge(after: 0.15)
            scheduleHide()
            return
        case .brightness, .volume:
            hideBadge(after: 0.15)
            scheduleHide()
            return
        case .undecided:
            break
        }

        pendingTap?.cancel()
        if touch.tapCount >= 2 {
            doubleTapSeek(at: point.x)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.toggleControls() }
        pendingTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        pendingLongPress?.cancel()
        restoreTemporaryRate()
        hideBadge(after: 0.1)
        touchMode = .undecided
    }

    private func restoreTemporaryRate() {
        guard let rate = temporaryRate else { return }
        player.rate = rate
        temporaryRate = nil
        updateSpeedTitle()
        Diagnostics.shared.log("uzun basma bitti: hız geri alındı")
    }

    private func setControls(visible: Bool) {
        if screenLocked {
            overlay.alpha = 0
            topBar?.alpha = 0
            lockButton.alpha = 1
            overlay.isUserInteractionEnabled = false
            topBar?.isUserInteractionEnabled = false
            lockButton.isUserInteractionEnabled = true
            return
        }
        UIView.animate(withDuration: 0.2) {
            self.overlay.alpha = visible ? 1 : 0
            self.topBar?.alpha = visible ? 1 : 0
            self.lockButton.alpha = visible ? 1 : 0
        }
        overlay.isUserInteractionEnabled = visible
        topBar?.isUserInteractionEnabled = visible
        lockButton.isUserInteractionEnabled = visible
        if visible { scheduleHide() } else { hideTimer?.invalidate() }
    }

    /// 4 sn dokunulmazsa denetimler gizlenir; duraklatılmışken, sararken ya da seçim penceresi açıkken açık kalır.
    private func scheduleHide() {
        hideTimer?.invalidate()
        guard !screenLocked else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, !self.finished, !self.userPaused, !self.screenLocked else { return }
            if self.scrubbing || self.presentedViewController != nil {
                self.scheduleHide()
                return
            }
            self.setControls(visible: false)
        }
    }

    @objc private func scrubStarted() {
        scrubbing = true
        hideTimer?.invalidate()
    }

    @objc private func scrubMoved() {
        if duration > 0 { elapsedLabel.text = format(Double(slider.value) * duration) }
    }

    @objc private func scrubEnded() {
        player.position = slider.value
        position = Double(slider.value) * duration
        scrubbing = false
        haptic()
        updateTimeLabels()
        scheduleHide()
    }

    @objc private func audioTapped() {
        Diagnostics.shared.log("ses seçici açıldı")
        let sheet = UIAlertController(title: "Ses dili", message: nil, preferredStyle: .actionSheet)
        let names = player.audioTrackNames as? [String] ?? []
        let indexes = player.audioTrackIndexes as? [NSNumber] ?? []
        for (name, index) in zip(names, indexes) where index.int32Value >= 0 {
            let mark = index.int32Value == player.currentAudioTrackIndex ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: "\(mark)\(name)", style: .default) { [weak self] _ in
                self?.player.currentAudioTrackIndex = index.int32Value
                if let code = TrackLanguage.code(of: name) { self?.onPreferences?(["audioLanguage": code]) }
                self?.updateTrackButtonTitles()
            })
        }
        if sheet.actions.isEmpty { sheet.message = "Bu yayında tek ses var." }
        presentSheet(sheet, from: audioButton)
    }

    @objc private func subtitlesTapped() {
        Diagnostics.shared.log("altyazı seçici açıldı")
        let sheet = UIAlertController(title: "Altyazı", message: nil, preferredStyle: .actionSheet)
        let names = player.videoSubTitlesNames as? [String] ?? []
        let indexes = player.videoSubTitlesIndexes as? [NSNumber] ?? []
        for (name, index) in zip(names, indexes) {
            let mark = index.int32Value == player.currentVideoSubTitleIndex ? "✓ " : ""
            let label = index.int32Value < 0 ? "Kapalı" : name
            sheet.addAction(UIAlertAction(title: "\(mark)\(label)", style: .default) { [weak self] _ in
                self?.player.currentVideoSubTitleIndex = index.int32Value
                if index.int32Value < 0 {
                    self?.onPreferences?(["subtitlesEnabled": false])
                } else {
                    var changes: [String: Any] = ["subtitlesEnabled": true]
                    if let code = TrackLanguage.code(of: name) { changes["subtitleLanguage"] = code }
                    self?.onPreferences?(changes)
                }
                self?.updateTrackButtonTitles()
            })
        }
        if sheet.actions.isEmpty { sheet.message = "Bu yayında altyazı yok." }
        presentSheet(sheet, from: subtitleButton)
    }

    private func presentSheet(_ sheet: UIAlertController, from button: UIButton) {
        sheet.addAction(UIAlertAction(title: "Kapat", style: .cancel))
        sheet.popoverPresentationController?.sourceView = button
        sheet.popoverPresentationController?.sourceRect = button.bounds
        hideTimer?.invalidate()
        present(sheet, animated: true)
    }

    // MARK: VLC olayları

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let names = ["durdu", "açılıyor", "tamponluyor", "bitti", "HATA", "oynuyor", "duraklatıldı", "iz eklendi"]
        let raw = player.state.rawValue
        // VLC "tamponluyor" bildirimini saniyede onlarca kez yolluyor; yalnız değişince yazılır.
        if raw != lastLoggedState {
            lastLoggedState = raw
            Diagnostics.shared.log("VLC durum: \(raw >= 0 && raw < names.count ? names[raw] : String(raw))")
        }
        switch player.state {
        case .playing:
            spinner.stopAnimating()
            applyPreferredTracks()
            updateTrackButtonTitles()
        case .buffering, .opening:
            if !player.isPlaying { spinner.startAnimating() }
        case .ended:
            finish(sleepAtEpisodeEnd ? .sleep : .ended)
        case .error:
            handlePlaybackFailure("Yayın açılamadı. Bağlantıyı kontrol edip tekrar dene.")
        case .stopped:
            if !finished, !isLive, duration > 0, position >= duration - 5 { finish(.ended) }
        default:
            break
        }
        updatePlayButton()
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        started = true
        spinner.stopAnimating()
        position = Double(player.time.intValue) / 1000
        if let length = player.media?.length.intValue, length > 0 { duration = Double(length) / 1000 }
        if restartFromBeginningRequested, duration > 0 {
            restartFromBeginningRequested = false
            player.position = 0
            position = 0
            Diagnostics.shared.log("kaldığın yer bildirimi: başa sarma uygulandı")
        }
        updatePlayButton()
        if position < 30 { applyPreferredTracks() }
        let nearEnd = item.nextEpisode != nil && duration > 60 && duration - position <= 30
        if upNextButton.isHidden == nearEnd { upNextButton.isHidden = !nearEnd }
        if isLive {
            updateTitle()
            return
        }
        guard !scrubbing else { return }
        updateTimeLabels()
    }

    /// Sitede seçilen ses dili ve altyazı tercihi oynatmanın ilk saniyelerinde uygulanır. VLC izleri
    /// parça parça bildiriyor (ses önce, altyazı sonra); her biri listesi dolunca bir kez seçilir.
    private func applyPreferredTracks() {
        guard !isLive, !(audioApplied && subtitleApplied) else { return }
        if !audioApplied {
            let names = player.audioTrackNames as? [String] ?? []
            let indexes = player.audioTrackIndexes as? [NSNumber] ?? []
            if indexes.contains(where: { $0.int32Value >= 0 }) {
                audioApplied = true
                if let wanted = TrackLanguage.normalize(preferences.audioLanguage),
                   let match = zip(names, indexes).first(where: { $0.1.int32Value >= 0 && TrackLanguage.code(of: $0.0) == wanted }),
                   match.1.int32Value != player.currentAudioTrackIndex {
                    player.currentAudioTrackIndex = match.1.int32Value
                    Diagnostics.shared.log("tercih edilen ses seçildi: \(match.0)")
                }
            }
        }
        if !subtitleApplied {
            if preferences.subtitlesEnabled == false {
                subtitleApplied = true
                if player.currentVideoSubTitleIndex >= 0 { player.currentVideoSubTitleIndex = -1 }
                updateTrackButtonTitles()
                return
            }
            let names = player.videoSubTitlesNames as? [String] ?? []
            let indexes = player.videoSubTitlesIndexes as? [NSNumber] ?? []
            guard indexes.contains(where: { $0.int32Value >= 0 }) else {
                // Altyazısız yayında boşuna beklenmez.
                if position > 20 { subtitleApplied = true }
                return
            }
            subtitleApplied = true
            // "Forced" iz yalnız yabancı dildeki kısa bölümleri çevirir; tam altyazı varsa o seçilir.
            let candidates = zip(names, indexes).filter { $0.1.int32Value >= 0 && TrackLanguage.code(of: $0.0) == TrackLanguage.normalize(preferences.subtitleLanguage) }
            if TrackLanguage.normalize(preferences.subtitleLanguage) != nil,
               let match = candidates.first(where: { !$0.0.lowercased().contains("forced") }) ?? candidates.first {
                player.currentVideoSubTitleIndex = match.1.int32Value
                Diagnostics.shared.log("tercih edilen altyazı seçildi: \(match.0)")
            }
        }
        updateTrackButtonTitles()
    }

    private func updatePlayButton() {
        let configuration = UIImage.SymbolConfiguration(pointSize: 42, weight: .semibold)
        playButton.setImage(UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill", withConfiguration: configuration), for: .normal)
    }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    private func reportProgress() {
        guard !isLive, position > 0 else { return }
        onProgress?(position, duration)
    }

    @objc private func appWillResignActive() {
        wasPlayingBeforeBackground = player.isPlaying
        if wasPlayingBeforeBackground { player.pause() }
        reportProgress()
        UIApplication.shared.isIdleTimerDisabled = false
        Diagnostics.shared.log("oynatıcı arka planda: ilerleme kaydedildi")
    }

    @objc private func appDidBecomeActive() {
        guard !finished else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        if wasPlayingBeforeBackground, !userPaused { player.play() }
        wasPlayingBeforeBackground = false
        Diagnostics.shared.log("oynatıcı öne geldi")
    }

    private func handlePlaybackFailure(_ message: String) {
        guard !finished, !playbackFailureHandled else { return }
        playbackFailureHandled = true
        if allowAutomaticReconnect {
            Diagnostics.shared.log("oynatma hatası: bir kez otomatik yeniden bağlanılıyor")
            reportProgress()
            finish(.reconnect)
            return
        }
        fail(message)
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        Diagnostics.shared.log("oynatma hatası: \(message)")
        stopPlayerInBackground()
        spinner.stopAnimating()
        messageLabel.text = message + "\n\nTekrar deneyebilir veya ✕ ile kapatabilirsin."
        messageLabel.isHidden = false
        retryButton.isHidden = false
        setControls(visible: true)
        hideTimer?.invalidate()
        startTimer?.invalidate()
    }

    /// VLCKit stop() ana iş parçacığında, görüntü katmanını sökmek için ana iş parçacığını bekleyen VLC
    /// iş parçacığıyla kilitlenebiliyor (uygulama donar). Durdurma arka planda yapılır.
    private func stopPlayerInBackground() {
        let player = self.player
        DispatchQueue.global(qos: .userInitiated).async { player.stop() }
    }

    private func finish(_ reason: FinishReason) {
        guard !finished else { return }
        finished = true
        hideTimer?.invalidate()
        progressTimer?.invalidate()
        startTimer?.invalidate()
        sleepTimer?.invalidate()
        pendingTap?.cancel()
        pendingLongPress?.cancel()
        NotificationCenter.default.removeObserver(self)
        player.delegate = nil
        Diagnostics.shared.log("oynatıcı kapanıyor: \(reason) konum=\(Int(position))/\(Int(duration))")
        stopPlayerInBackground()
        UIApplication.shared.isIdleTimerDisabled = false
        UIScreen.main.brightness = originalBrightness
        let completedAtEnd = reason == .ended || (reason == .sleep && sleepAtEpisodeEnd)
        let finalPosition = completedAtEnd && duration > 0 ? duration : position
        let finalDuration = duration
        let callback = onFinish
        dismiss(animated: true) {
            callback?(finalPosition, finalDuration, reason)
        }
    }
}
