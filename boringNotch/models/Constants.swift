//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults

// MARK: - File System Paths
private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let bundleIdentifier = Bundle.main.bundleIdentifier!
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let spacing: CGFloat = 16

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

struct AppLanguage: RawRepresentable, Hashable, Identifiable, Defaults.Serializable {
    static let system = AppLanguage(rawValue: "system")

    var id: String { rawValue }
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static var allCases: [AppLanguage] {
        let languages = Bundle.main.localizations
            .filter(isSelectableLocalization)
            .map(AppLanguage.init(rawValue:))
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        return [.system] + languages
    }

    var displayName: String {
        if self == .system {
            return NSLocalizedString(
                "System default",
                comment: "Language picker option: follow the system app language"
            )
        }

        let displayName = nativeLocale.localizedString(forIdentifier: rawValue) ?? rawValue
        return displayName.capitalized(with: nativeLocale)
    }

    private var nativeLocale: Locale {
        Locale(identifier: rawValue)
    }

    private static func isSelectableLocalization(_ identifier: String) -> Bool {
        guard identifier != "Base" else { return false }
        guard let url = Bundle.main.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: identifier
        ) else {
            return false
        }

        guard
            let data = try? Data(contentsOf: url),
            let strings = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: String]
        else {
            return false
        }

        return strings.values.contains { !$0.isEmpty }
    }

    func applyAppleLanguagesOverride() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}

// Define notification names at file scope
extension Notification.Name {
    // MARK: - Media
    static let mediaControllerChanged = Notification.Name("mediaControllerChanged")
    
    // MARK: - Display
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    
    // MARK: - Shelf
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
    
    // MARK: - System
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
    
    // MARK: - Sharing
    static let sharingDidFinish = Notification.Name("com.boringNotch.sharingDidFinish")
    
    // MARK: - UI
    static let accentColorChanged = Notification.Name("AccentColorChanged")
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying
    case appleMusic
    case spotify
    case youtubeMusic
    
    var id: String { self.rawValue }

    var localizedString: String {
        switch self {
        case .nowPlaying:
            return NSLocalizedString("Now Playing", comment: "")
        case .appleMusic:
            return "Apple Music"
        case .spotify:
            return "Spotify"
        case .youtubeMusic:
            return "YouTube Music"
        }
    }
}
// User-selectable face mood for the idle face animation shown when music is idle
enum Mood: String, CaseIterable, Identifiable, Defaults.Serializable {
    case happy
    case neutral
    case sad
    case wink
    case surprised

    var id: String { rawValue }

    var localizedString: String {
        switch self {
        // English text as the key, not a symbolic one: a localization that lacks
        // the key renders the key itself, so a symbolic key shows as "mood_happy"
        // under partial translations (en-GB is 169 of 224 keys).
        case .happy:
            return NSLocalizedString("Happy", comment: "Face mood option: happy")
        case .neutral:
            return NSLocalizedString("Neutral", comment: "Face mood option: neutral")
        case .sad:
            return NSLocalizedString("Sad", comment: "Face mood option: sad")
        case .wink:
            return NSLocalizedString("Wink", comment: "Face mood option: winking")
        case .surprised:
            return NSLocalizedString("Surprised", comment: "Face mood option: surprised")
        }
    }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard
    case inline
    
    var id: String { self.rawValue }
    
    var localizedString: String {
        switch self {
        case .standard:
            return NSLocalizedString("sneak_peek_standard", comment: "Sneak Peek style: Default")
        case .inline:
            return NSLocalizedString("sneak_peek_inline", comment: "Sneak Peek style: Inline")
        }
    }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings
    case showOSD
    case none

    var id: String { self.rawValue }
    
    var localizedString: String {
        switch self {
        case .openSettings:
            return NSLocalizedString("option_key_open_system_settings", comment: "Option (⌥) key behavior: Open System Settings")
        case .showOSD:
            return NSLocalizedString("option_key_show_osd", comment: "Option (⌥) key behavior: Show OSD")
        case .none:
            return NSLocalizedString("option_key_no_action", comment: "Option (⌥) key behavior: No action")
        }
    }
}

// Source/provider for OSD control (user-facing: "Source")
enum OSDControlSource: String, CaseIterable, Identifiable, Defaults.Serializable {
    case builtin
    case betterDisplay = "BetterDisplay"
    case lunar = "Lunar"

    var id: String { self.rawValue }
    
    var localizedString: String {
        switch self {
        case .builtin:
            return NSLocalizedString("osd_sources_built_in", comment: "OSD Sources: Built-in")
        case .betterDisplay:
            return "BetterDisplay"
        case .lunar:
            return "Lunar"
        }
    }
}

extension Defaults.Keys {
    // MARK: General
    static let appLanguage = Key<AppLanguage>("appLanguage", default: .system)
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let releaseName = Key<String>("releaseName", default: "Flying Rabbit 🐇🪽")
    
    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableOpeningAnimation = Key<Bool>("enableOpeningAnimation", default: true)
    static let animationSpeedMultiplier = Key<Double>("animationSpeedMultiplier", default: 1.0)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let extendHoverArea = Key<Bool>("extendHoverArea", default: false)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    //static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
    
    // MARK: Appearance
    //static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: false)
    static let isMirrored = Key<Bool>("isMirrored", default: true)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle)
    static let mirrorCameraID = Key<String?>("mirrorCameraID", default: nil)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)
    
    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let enableHorizontalMediaGestures = Key<Bool>("enableHorizontalMediaGestures", default: false)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)
    
    // MARK: Media playback
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)
    static let realtimeAudioWaveform = Key<Bool>("realtimeAudioWaveform", default: false)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: false)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let showShuffleAndRepeat = Key<Bool>("showShuffleAndRepeat", default: false)
    static let enableLyrics = Key<Bool>("enableLyrics", default: false)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )
    
    // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)
    static let showChargingWattage = Key<Bool>("showChargingWattage", default: true)
    
    // MARK: Downloads
    static let enableDownloadListener = Key<Bool>("enableDownloadListener", default: true)
    static let enableSafariDownloads = Key<Bool>("enableSafariDownloads", default: true)
    static let selectedDownloadIndicatorStyle = Key<DownloadIndicatorStyle>("selectedDownloadIndicatorStyle", default: DownloadIndicatorStyle.progress)
    static let selectedDownloadIconStyle = Key<DownloadIconStyle>("selectedDownloadIconStyle", default: DownloadIconStyle.onlyAppIcon)
    
    // MARK: OSD
    static let osdReplacement = Key<Bool>("osdReplacement", default: false)
    static let inlineOSD = Key<Bool>("inlineOSD", default: false)
    static let enableGradient = Key<Bool>("enableGradient", default: false)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchOSD = Key<Bool>("showOpenNotchOSD", default: true)
    static let showOpenNotchOSDPercentage = Key<Bool>("showOpenNotchOSDPercentage", default: true)
    static let showClosedNotchOSDPercentage = Key<Bool>("showClosedNotchOSDPercentage", default: false)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    // Brightness/volume/keyboard source selection
    static let osdBrightnessSource = Key<OSDControlSource>("osdBrightnessSource", default: .builtin)
    static let osdVolumeSource = Key<OSDControlSource>("osdVolumeSource", default: .builtin)
    
    // MARK: System Monitor
    static let showSystemMonitor = Key<Bool>("showSystemMonitor", default: false)
    
    // MARK: Shelf
    static let boringShelf = Key<Bool>("boringShelf", default: true)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: true)
    static let shelfTapToOpen = Key<Bool>("shelfTapToOpen", default: true)
    static let quickShareProvider = Key<String>("quickShareProvider", default: QuickShareProvider.defaultProvider.id)
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: false)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)
    static let reverseShelfOrdering = Key<Bool>("reverseShelfOrdering", default: false)
    
    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    static let calendarWeekView = Key<Bool>("calendarWeekView", default: false)
    static let weekStartDay = Key<WeekStartDay>("weekStartDay", default: .system)
    
    // MARK: Face Mood
    static let selectedMood = Key<Mood>("selectedMood", default: .happy)

    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)
    
    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    
    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    static let hideNonNotchedFromMissionControl = Key<Bool>("hideNonNotchedFromMissionControl", default: true)
    // Normalize scroll/gesture direction so when macOS "Natural scrolling" is disabled, it doesn't invert gestures
    static let normalizeGestureDirection = Key<Bool>("normalizeGestureDirection", default: true)
    
    // Helper to determine the default media controller based on NowPlaying deprecation status
    static var defaultMediaController: MediaControllerType {
        if MusicManager.shared.isNowPlayingDeprecated {
            return .appleMusic
        } else {
            return .nowPlaying
        }
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)

    // MARK: Voice
    // Off by default: this opens the microphone, so it must be opted into.
    static let voiceAgentEnabled = Key<Bool>("voiceAgentEnabled", default: false)
    // User-defined voice commands (Settings > Commands).
    static let customCommands = Key<[CustomCommand]>("customCommands", default: [])

    // MARK: Agent (BYOK)
    // AgentBackend is declared below, beside the other settings types, so
    // ModelProvider.swift keeps depending on nothing but Foundation -- that is
    // what lets the agent be tested standalone and moved to the brow-agent
    // package in roadmap item 5 without dragging the app's dependencies along.
    // Which back end answers what the local matcher could not. The Claude Code
    // CLI stays available for people who already have it, but it authenticates
    // as whoever installed it, so it cannot be the default for anyone else.
    static let agentBackend = Key<AgentBackend>("agentBackend", default: .claudeCLI)
    // Haiku by default: this answers someone standing in front of their Mac
    // waiting, and a voice command is a short, concrete task. A bigger model is
    // one picker away for anyone who would rather have the judgement.
    static let agentModel = Key<String>("agentModel", default: "claude-haiku-4-5")
    // Only used by the "Other (OpenAI-compatible)" back end -- the presets
    // carry their own URL. A local Ollama goes here: http://localhost:11434/v1
    static let agentBaseURL = Key<String>("agentBaseURL", default: "")
    // Only sent to models that accept it -- see AnthropicProvider.supportsEffort.
    static let agentEffort = Key<String>("agentEffort", default: "low")
    // The API key itself lives in the Keychain, never here. See APIKeyStore.
}

/// Which back end answers a question the local matcher declined.
///
/// Everything except the CLI and Anthropic speaks the OpenAI chat-completions
/// shape, so they are one provider with different base URLs. Presets exist
/// because asking someone to remember
/// `https://generativelanguage.googleapis.com/v1beta/openai` is not a feature.
///
/// The CLI stays because it costs nothing to keep and some people have it
/// working. It cannot be the default: it authenticates as whoever installed it,
/// which is the entire reason nobody else could run Brow.
enum AgentBackend: String, Codable, CaseIterable, Defaults.Serializable {
    case claudeCLI
    case anthropic
    case openRouter
    case gemini
    case custom

    var displayName: String {
        switch self {
        case .claudeCLI: return "Claude Code CLI"
        case .anthropic: return "Anthropic"
        case .openRouter: return "OpenRouter — any model"
        case .gemini: return "Google Gemini"
        case .custom: return "Other (OpenAI-compatible)"
        }
    }

    /// Nil for the two that are not OpenAI-compatible: the CLI is a
    /// subprocess, and Anthropic has its own provider.
    var baseURL: URL? {
        switch self {
        case .claudeCLI, .anthropic, .custom: return nil
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1")
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")
        }
    }

    /// Which keychain entry holds this back end's key. One per back end, so
    /// switching does not overwrite a key you may want back.
    var keyProvider: APIKeyStore.Provider? {
        switch self {
        case .claudeCLI: return nil
        case .anthropic: return .anthropic
        case .openRouter: return .openRouter
        case .gemini: return .gemini
        case .custom: return .custom
        }
    }

    /// Where to get a key, shown in Settings. A dead end is worse than a link.
    var signupURL: URL? {
        switch self {
        case .claudeCLI: return nil
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .custom: return nil
        }
    }

    /// A sensible model to start on, used when the live list has not loaded.
    var defaultModel: String {
        switch self {
        case .claudeCLI: return ""
        case .anthropic: return "claude-haiku-4-5"
        case .openRouter: return "anthropic/claude-haiku-4.5"
        case .gemini: return "gemini-flash-latest"
        case .custom: return ""
        }
    }
}
