import SwiftUI

@main
struct ShiduoApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup("拾掇") {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.ocr)
                .environmentObject(store.duplicates)
                .environmentObject(store.similar)
                .environmentObject(store.cleanup)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            SidebarCommands()
            InspectorCommands()
            CommandGroup(after: .newItem) {
                Button("固定文件夹…") { store.choosePinnedFolder() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("刷新") { store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(store.ocr)
        }
    }
}
