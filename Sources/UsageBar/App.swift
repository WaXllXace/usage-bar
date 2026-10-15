import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when launched as a bare executable (swift run).
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct UsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: Store

    init() {
        let args = CommandLine.arguments
        let demo = args.contains("--demo") || args.contains("--render-preview")
        let s = Store(demo: demo)
        _store = StateObject(wrappedValue: s)

        // `--render-preview out.png` renders the popover with demo data and exits.
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            s.start()
            Self.renderPreview(store: s, to: args[i + 1])
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
                .onAppear { store.start() }
        } label: {
            Image(nsImage: store.statusImage)
                .onAppear { store.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Profiles", id: "profiles") {
            ProfilesWindow()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 460)
    }

    @MainActor
    private static func renderPreview(store: Store, to path: String) {
        let view = PopoverView().environmentObject(store).frame(width: PopoverView.width)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { fputs("render failed\n", stderr); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
