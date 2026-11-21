import LumaCore
import SwiftUI

struct PrivacyPolicyLink: View {
    var body: some View {
        Link("Privacy Policy", destination: BackendConfig.privacyPolicyURL)
    }
}
