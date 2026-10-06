import SwiftUI

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor var delegate: Delegate

    var body: some Scene {
        WindowGroup("Mac Cleaner") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}

// Closing the window quits, so every open starts with a fresh scan.
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@MainActor
final class Cleaner: ObservableObject {
    @Published var rows: [Row] = []
    @Published var scanning = 0          // scanners still running
    @Published var cleaning: String?     // title of the row being cleaned
    @Published var free: Int64 = 0

    var busy: Bool { scanning > 0 || cleaning != nil }
    var selected: Int64 { rows.filter(\.on).reduce(0) { $0 + $1.bytes } }

    func scan() async {
        rows = []
        refreshFree()
        scanning = scanners.count
        await withTaskGroup(of: [Row].self) { group in
            for (i, scanner) in scanners.enumerated() {
                group.addTask {
                    scanner().enumerated().map { j, row in
                        var row = row
                        row.order = i * 100 + j
                        return row
                    }
                }
            }
            for await found in group {
                rows = (rows + found).sorted { $0.order < $1.order }
                scanning -= 1
            }
        }
    }

    func clean() async {
        for row in rows where row.on {
            cleaning = row.title
            await Task.detached { row.clean() }.value
        }
        cleaning = nil
        await scan()
    }

    func refreshFree() {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        free = values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

struct ContentView: View {
    @StateObject private var cleaner = Cleaner()
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Free space").font(.caption).foregroundStyle(.secondary)
                    Text(gb(cleaner.free)).font(.title2.bold())
                }
                Spacer()
                if cleaner.scanning > 0 {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").foregroundStyle(.secondary)
                }
                Button("Rescan") { Task { await cleaner.scan() } }.disabled(cleaner.busy)
            }
            .padding()

            Divider()

            List($cleaner.rows) { $row in
                HStack {
                    Toggle("", isOn: $row.on).labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                        Text(row.note).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(gb(row.bytes)).monospacedDigit()
                }
                .padding(.vertical, 2)
            }
            .disabled(cleaner.cleaning != nil)

            Divider()

            HStack {
                if let title = cleaner.cleaning {
                    ProgressView().controlSize(.small)
                    Text("Cleaning \(title)…")
                } else {
                    Text("Selected: \(gb(cleaner.selected))")
                }
                Spacer()
                Button("Clean") { confirm = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaner.busy || cleaner.selected == 0)
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 560)
        .task { await cleaner.scan() }
        .confirmationDialog("Delete \(gb(cleaner.selected))?", isPresented: $confirm) {
            Button("Delete", role: .destructive) { Task { await cleaner.clean() } }
        } message: {
            Text("This can't be undone. Everything here is rebuilt or downloaded again when needed.")
        }
    }

    func gb(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
