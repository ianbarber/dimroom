import Harness
import SwiftUI

struct ContentView: View {
    let router: AppRouter

    var body: some View {
        Text("Hello Dimroom — \(router.route.rawValue)")
            .font(.largeTitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
