import IslandKit

/// Creates every section and module once, when the island's environment is built. Initialisers must
/// be cheap: nothing may sample, observe or start hardware until `islandDidStart()` or `pageDidAppear()`.
@MainActor
enum IslandRegistry {
    static func install(in environment: IslandEnvironment) {
        let sections: [any IslandSection] = [
            ControlsSection(environment: environment),
            MixerSection(environment: environment),
            MusicSection(environment: environment),
            ClipboardSection(environment: environment),
            CapturesSection(environment: environment),
            FilesSection(environment: environment),
            SystemSection(environment: environment),
            ToolsSection(environment: environment),
            CalendarSection(environment: environment),
            NotificationsSection(environment: environment),
            TimerSection(environment: environment),
            CameraSection(environment: environment),
            DownloadsSection(environment: environment),
            ScratchpadSection(environment: environment),
            AgentsSection(environment: environment),
        ]
        for section in sections { environment.register(section) }
        let modules: [any IslandFeature] = [
            KeepAwakeModule(environment: environment),
            AppPanelModule(environment: environment),
            BatteryModule(environment: environment),
            AudioModule(environment: environment),
            DisplayModule(environment: environment),
            AccessoryModule(environment: environment),
        ]
        for module in modules { environment.register(module: module) }
    }
}
