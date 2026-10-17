import Foundation
import Combine

// Bounded reproduction of the 0.1.4 @Published observer path; never part of the app.
struct BaselineSettings {
    var height = 50.0
    mutating func sanitize() { height = min(58, max(44, height)) }
}
final class ObserverBaseline: ObservableObject {
    var calls = 0
    @Published var settings = BaselineSettings() {
        didSet { calls += 1; if calls < 8 { settings.sanitize() } }
    }
}
let baseline = ObserverBaseline()
baseline.settings.height = 51
print("legacy_observer_calls=\(baseline.calls); bounded_at=8")
