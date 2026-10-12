import Foundation
import UIKit

/// Teşhis kaydı: oynatıcı olayları ve donmalar sunucunun cihaz raporlarına (perf_reports, "ios-diag")
/// gider. Telefonun ekranı görülemediği için sorun bu kayıttan okunur. Kullanıcı adı/şifre yazılmaz.
final class Diagnostics {
    static let shared = Diagnostics()

    private let queue = DispatchQueue(label: "fenotip.diagnostics")
    private let started = Date()
    private var events: [String] = []
    private var flushScheduled = false
    private var lastMainPong = Date()
    private var mainStalled = false
    /// Arka planda ana iş parçacığı zaten askıda; bu "donma" sayılmaz.
    private var inBackground = false
    private var watchdog: DispatchSourceTimer?
    private var systemVersion = ""
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    func start(systemVersion: String) {
        queue.async {
            self.systemVersion = systemVersion
            self.startWatchdog()
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.inBackground = true }
            self.log("arka plana geçti")
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.inBackground = false
                self.lastMainPong = Date()
                self.mainStalled = false
            }
            self.log("öne geldi")
        }
        log("uygulama açıldı")
    }

    func log(_ message: String) {
        let stamp = String(format: "%.1f", Date().timeIntervalSince(started))
        queue.async {
            self.events.append("\(stamp) \(message)")
            if self.events.count > 150 { self.events.removeFirst(self.events.count - 150) }
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 5) { self.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard !events.isEmpty else { return }
        var batch = events
        events.removeAll()
        var body: [String: Any] = ["type": "ios-diag", "app": appVersion, "ios": systemVersion, "events": batch]
        var data = try? JSONSerialization.data(withJSONObject: body)
        while let current = data, current.count > 15_000, batch.count > 1 {
            batch.removeFirst(batch.count / 2)
            body["events"] = batch
            data = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let data, let url = URL(string: "/api/perf", relativeTo: ServerAPI.base) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Ana iş parçacığı 3 sn'den uzun yanıt vermezse (donma) kaydeder ve hemen gönderir.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.inBackground {
                self.lastMainPong = Date()
                return
            }
            DispatchQueue.main.async { self.queue.async { self.lastMainPong = Date() } }
            let stall = Date().timeIntervalSince(self.lastMainPong)
            if stall > 3, !self.mainStalled {
                self.mainStalled = true
                self.events.append(String(format: "%.1f UYGULAMA DONDU (ana iş parçacığı %d sn yanıtsız)", Date().timeIntervalSince(self.started), Int(stall)))
                self.flush()
            } else if stall < 2, self.mainStalled {
                self.mainStalled = false
                self.events.append(String(format: "%.1f donma bitti", Date().timeIntervalSince(self.started)))
                self.scheduleFlush()
            }
        }
        timer.resume()
        watchdog = timer
    }
}
