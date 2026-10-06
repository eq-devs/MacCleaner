import Foundation

// One thing that can be cleaned: what it is, how big, and how to delete it.
struct Row: Identifiable {
    let id: String
    let title: String
    let note: String
    let bytes: Int64
    var on: Bool
    let clean: () -> Void
    var order = 0
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let dev = home + "/Library/Developer"

// Each scanner is read-only. It measures, and returns rows (empty if nothing to clean).
// Rows show in this order, and clean in this order.
let scanners: [() -> [Row]] = [
    {
        pathRow("derived", "Xcode build cache", "DerivedData. Rebuilt on the next build.",
                on: true, children(dev + "/Xcode/DerivedData"))
    },
    runtimeRows,
    unavailableSimRow,
    {
        pathRow("devicesupport", "iPhone debug files", "iOS DeviceSupport. Xcode remakes them when you plug in an iPhone (a few minutes).",
                on: false, children(dev + "/Xcode/iOS DeviceSupport"))
    },
    {
        pathRow("xctest", "Xcode test simulator copies", "XCTestDevices.",
                on: true, children(dev + "/XCTestDevices"))
    },
    {
        pathRow("gradle", "Gradle cache and old versions", "The next Android build downloads again and is slow once.",
                on: false, [home + "/.gradle/caches", home + "/.gradle/wrapper/dists"],
                before: { sh(["/usr/bin/pkill", "-f", "GradleDaemon"]) })
    },
    oldNdkRow,
    flutterBuildRow,
    {
        pathRow("dartserver", "Dart analysis cache", "~/.dartServer. Close your IDE first.",
                on: true, [home + "/.dartServer"])
    },
    {
        pathRow("pub", "Flutter package cache", "~/.pub-cache. The next pub get downloads again. Global tools are kept.",
                on: false, ["hosted", "git", "hosted-hashes"].map { home + "/.pub-cache/" + $0 })
    },
    {
        pathRow("pods", "Old CocoaPods specs and cache", "Your Podfiles use the CDN, so the old specs repo is unused.",
                on: true, [home + "/.cocoapods/repos/cocoapods", home + "/Library/Caches/CocoaPods"])
    },
    {
        pathRow("shorebird", "Shorebird Flutter copies", "Shorebird downloads only the one it needs next time.",
                on: false, [home + "/.shorebird/bin/cache/flutter", home + "/.shorebird/bin/cache/previews"])
    },
    {
        pathRow("avd", "Android emulator snapshots", "The next start is a cold boot. Emulator data is kept.",
                on: true, children(home + "/.android/avd").filter { $0.hasSuffix(".avd") }.map { $0 + "/snapshots" })
    },
    {
        pathRow("caches", "App caches", "~/Library/Caches. Apps rebuild them. Close Chrome and other apps first.",
                on: false, children(home + "/Library/Caches").filter { !$0.hasSuffix("/CocoaPods") })
    },
    brewRow,
]

// MARK: - Scanners that need more than a path list

func runtimeRows() -> [Row] {
    guard let all = json(["/usr/bin/xcrun", "simctl", "runtime", "list", "-j"]) as? [String: [String: Any]] else { return [] }
    return all.values.compactMap { r -> Row? in
        guard let id = r["identifier"] as? String, let version = r["version"] as? String,
              r["deletable"] as? Bool == true else { return nil }
        let platform = (r["runtimeIdentifier"] as? String)?
            .components(separatedBy: ".").last?.components(separatedBy: "-").first ?? "iOS"
        return Row(id: "runtime-" + id, title: "\(platform) \(version) simulator system",
                   note: "Delete only if you don't test on this version.",
                   bytes: (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0, on: false,
                   clean: { sh(["/usr/bin/xcrun", "simctl", "runtime", "delete", id]) })
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
}

func unavailableSimRow() -> [Row] {
    guard let obj = json(["/usr/bin/xcrun", "simctl", "list", "devices", "unavailable", "-j"]) as? [String: Any],
          let devices = obj["devices"] as? [String: [[String: Any]]] else { return [] }
    let ids = devices.values.joined().compactMap { $0["udid"] as? String }
    let bytes = size(ids.map { dev + "/CoreSimulator/Devices/" + $0 })
    guard bytes > 1 << 20 else { return [] }
    return [Row(id: "sims", title: "Broken iOS simulators (\(ids.count))",
                note: "Their iOS version is gone, so they can't open.", bytes: bytes, on: true,
                clean: { sh(["/usr/bin/xcrun", "simctl", "delete", "unavailable"]) })]
}

// Keeps the 2 newest NDKs.
func oldNdkRow() -> [Row] {
    let all = children(home + "/Library/Android/sdk/ndk")
        .filter { (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let old = Array(all.dropLast(2))
    let keep = all.suffix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    return pathRow("ndk", "Old Android NDK (\(old.count))", "Keeps \(keep).", on: false, old)
}

// Same as running flutter clean in every Flutter project on the Desktop.
func flutterBuildRow() -> [Row] {
    let out = sh(["/usr/bin/find", home + "/Desktop",
                  "(", "-name", "node_modules", "-o", "-name", ".dart_tool", "-o", "-name", "build",
                  "-o", "-name", "Pods", "-o", "-name", ".git", ")", "-prune",
                  "-o", "-name", "pubspec.yaml", "-print"])
    let dirs = out.split(separator: "\n").flatMap { f -> [String] in
        let project = (String(f) as NSString).deletingLastPathComponent
        return [project + "/build", project + "/.dart_tool"]
    }.filter { FileManager.default.fileExists(atPath: $0) }
    return pathRow("flutter", "Flutter build folders on Desktop (\(dirs.count))",
                   "build and .dart_tool. Rebuilt on the next run.", on: true, dirs)
}

func brewRow() -> [Row] {
    guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.fileExists) else { return [] }
    let out = sh([brew, "cleanup", "--prune=all", "-n"])
    guard let match = out.range(of: #"approximately [\d.]+[KMG]B"#, options: .regularExpression) else { return [] }
    let text = out[match].dropFirst("approximately ".count)
    let unit = Double(text.hasSuffix("GB") ? 1 << 30 : text.hasSuffix("MB") ? 1 << 20 : 1 << 10)
    let bytes = Int64((Double(text.dropLast(2)) ?? 0) * unit)
    return [Row(id: "brew", title: "Homebrew old versions and downloads", note: "brew cleanup.",
                bytes: bytes, on: true, clean: { sh([brew, "cleanup", "--prune=all"]) })]
}

// MARK: - Helpers

func pathRow(_ id: String, _ title: String, _ note: String, on: Bool, _ paths: [String],
             before: @escaping () -> Void = {}) -> [Row] {
    let bytes = size(paths)
    guard bytes > 1 << 20 else { return [] }
    return [Row(id: id, title: title, note: note, bytes: bytes, on: on, clean: { before(); remove(paths) })]
}

func children(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 }
}

// Disk usage in bytes. du with no paths would measure the current folder, so skip that.
func size(_ paths: [String]) -> Int64 {
    let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
    guard !existing.isEmpty else { return 0 }
    let total = sh(["/usr/bin/du", "-sck"] + existing).split(separator: "\n").last ?? ""
    return (Int64(total.split(separator: "\t").first ?? "") ?? 0) * 1024
}

// Only ever deletes inside the home folder.
func remove(_ paths: [String]) {
    let safe = paths.filter { $0.hasPrefix(home + "/") && !$0.contains("/../") }
    if !safe.isEmpty { sh(["/bin/rm", "-rf", "--"] + safe) }
}

func json(_ args: [String]) -> Any? {
    try? JSONSerialization.jsonObject(with: Data(sh(args).utf8))
}

@discardableResult
func sh(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    p.environment = ProcessInfo.processInfo.environment
        .merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
