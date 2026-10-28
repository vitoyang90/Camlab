import Foundation

@MainActor enum PhotoWorkflowPreferences {
    static let nativeKey = "Camlab.NativePhotosWorkflow"
    private static let migrationKey = "Camlab.InAppColorDefault.v2"

    static func nativePhotosEnabled(defaults: UserDefaults = .standard) -> Bool {
        // The user chose to return to in-app adjustment. Migrate the earlier
        // native-by-default release once; respect subsequent explicit choices.
        if !defaults.bool(forKey: migrationKey) {
            defaults.set(false, forKey: nativeKey)
            defaults.set(true, forKey: migrationKey)
        }
        return defaults.bool(forKey: nativeKey)
    }
}
