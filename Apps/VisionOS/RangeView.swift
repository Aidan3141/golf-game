import RealityKit
import SwiftUI

// placeholder range: green ground + a ball at your feet. real scene in M2
struct RangeView: View {
    var body: some View {
        RealityView { content in
            let ground = ModelEntity(
                mesh: .generatePlane(width: 40, depth: 200),
                materials: [SimpleMaterial(color: .init(red: 0.25, green: 0.55, blue: 0.2, alpha: 1), isMetallic: false)]
            )
            ground.position = [0, 0, -95]
            content.add(ground)

            let ball = ModelEntity(
                mesh: .generateSphere(radius: 0.0214),  // real golf ball radius in m
                materials: [SimpleMaterial(color: .white, isMetallic: false)]
            )
            ball.position = [0, 0.0214, -0.5]
            content.add(ball)
        }
    }
}
