import Harness
import SwiftUI

@Observable
final class AppRouter {
    var route: Route = .library

    /// Navigate one level up: develop → loupe, loupe → library,
    /// library is a no-op. Bound to the Esc key and the nav bar's
    /// back button.
    func goBack() {
        switch route {
        case .develop:
            route = .loupe
        case .loupe:
            route = .library
        case .library:
            break
        }
    }
}
