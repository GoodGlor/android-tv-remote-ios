import RemoteCore
import UIKit

enum Haptics {
    static func tap() {
        guard Preferences().hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
