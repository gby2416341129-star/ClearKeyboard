import Foundation

/// Persisted UI preference names, retained for user-data compatibility.
/// V49 uses the matching SDK bit contract; persisted preference names remain stable.
public enum InputPreferenceKeys {
    public static let fuzzyPairs = ["z/zh", "c/ch", "s/sh", "n/l", "f/h", "an/ang", "en/eng", "in/ing"]
}
