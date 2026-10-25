import AppKit
import Foundation
import Security
import UserNotifications

// Automatic updates from the GitHub releases of the project.
// The app looks for a newer release at launch and every 6 hours, downloads it in the background, checks that it is
// signed by the same developer as the running app, then installs it when the app quits (or right away with
// "Redémarrer"). Nothing is interrupted while working. A copy built from the source code (signed locally, without a
// developer team) is never replaced: it is only told that a new version exists.

struct Release: Sendable {
    let version: String
    let zip: URL
    let page: URL
    let notes: String
}

enum UpdateError: LocalizedError {
    case network(String), noAsset, invalid(String)
    var errorDescription: String? {
        switch self {
        case .network(let m): "Connexion à GitHub impossible (\(m))."
        case .noAsset: "La nouvelle version ne contient pas d'app à télécharger."
        case .invalid(let m): "Mise à jour refusée : \(m)"
        }
    }
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "KillianPalin/hyperlapse-matchcut"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)
        case ready(String)          // downloaded and checked, installed at quit
        case available(String, URL) // newer version, but this copy cannot update itself
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdate") }
    }
    /// Saves the open sessions before the app is replaced.
    var beforeRestart: (() -> Void)?

    private var readyApp: URL?
    private var timer: Timer?
    private var installed = false

    private init() {
        automatic = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    func start() {
        guard timer == nil, !Bundle.main.bundlePath.contains("/.build/") else { return }  // not the development copy
        Task { await check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        if case .downloading = state { return }
        if case .ready = state { return }
        guard automatic || userInitiated else { return }
        state = .checking
        do {
            let release = try await Self.latestRelease()
            guard Self.isNewer(release.version, than: Self.currentVersion) else {
                state = userInitiated ? .upToDate : .idle
                return
            }
            guard Self.teamIdentifier(of: Bundle.main.bundleURL) != nil else {
                state = .available(release.version, release.page)
                return
            }
            state = .downloading(release.version)
            let app = try await Self.prepare(release)
            readyApp = app
            state = .ready(release.version)
            notify(release.version)
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Installs the downloaded version now and opens it again.
    func restartNow() {
        guard let app = readyApp else { return }
        beforeRestart?()
        do {
            try Self.install(app, over: Bundle.main.bundleURL)
            installed = true
            let path = Bundle.main.bundlePath
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Called when the app quits: a version waiting is put in place for the next launch.
    func installIfReady() {
        guard !installed, let app = readyApp else { return }
        installed = (try? Self.install(app, over: Bundle.main.bundleURL)) != nil
    }

    private func notify(_ version: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Hyperlapse/Match cut \(version) est prête"
            content.body = "Elle s'installera à la fermeture de l'app. « Redémarrer » dans la barre du haut pour l'avoir tout de suite."
            center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
        }
    }

    // MARK: - Steps (also used by the tests)

    static func latestRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw UpdateError.network(error.localizedDescription) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError.network("réponse inattendue") }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.compactMap({ a -> URL? in
            guard let name = a["name"] as? String, name.hasSuffix(".zip") else { return nil }
            return (a["browser_download_url"] as? String).flatMap(URL.init(string:))
        }).first else { throw UpdateError.noAsset }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, zip: zip, page: page, notes: json["body"] as? String ?? "")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Downloads and unpacks the release, then checks it: same app, same developer as the one running, newer version.
    static func prepare(_ release: Release, runningApp: URL = Bundle.main.bundleURL) async throws -> URL {
        let (tmp, _) = try await URLSession.shared.download(from: release.zip)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hyperlapse-update-\(release.version)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.invalid("aucune app dans l'archive") }
        try verify(app, against: runningApp, version: release.version)
        return app
    }

    static func verify(_ app: URL, against running: URL, version: String) throws {
        guard let team = teamIdentifier(of: running) else { throw UpdateError.invalid("cette copie n'est pas signée par un développeur") }
        let id = Bundle(url: running)?.bundleIdentifier ?? ""
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == id else { throw UpdateError.invalid("ce n'est pas la même app") }
        guard (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) == version else {
            throw UpdateError.invalid("numéro de version incohérent")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.invalid("signature illisible")
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
        else { throw UpdateError.invalid("elle n'est pas signée par le même développeur") }
    }

    /// Team of the developer who signed the app (nil for a copy signed locally, "ad hoc").
    static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Puts `app` in place of `dest`; the old version goes to the Trash.
    static func install(_ app: URL, over dest: URL) throws {
        let fm = FileManager.default
        let old = fm.temporaryDirectory.appendingPathComponent("hyperlapse-old-\(UUID().uuidString).app")
        try fm.moveItem(at: dest, to: old)
        do {
            try fm.moveItem(at: app, to: dest)
        } catch {
            try? fm.moveItem(at: old, to: dest)
            throw error
        }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        _ = try? fm.trashItem(at: old, resultingItemURL: nil)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.invalid("\(URL(fileURLWithPath: tool).lastPathComponent) a échoué") }
    }
}
