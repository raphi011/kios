import Testing
import SwiftUI
import UIKit
@testable import Kios

@Suite("Color(light:dark:)")
struct ColorPairTests {
    @Test("resolves to the light variant under .light userInterfaceStyle")
    func resolvesLight() {
        let pair = Color(light: .white, dark: .black)
        let resolved = UIColor(pair).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
        #expect(approximatelyEqual(resolved, .white))
    }

    @Test("resolves to the dark variant under .dark userInterfaceStyle")
    func resolvesDark() {
        let pair = Color(light: .white, dark: .black)
        let resolved = UIColor(pair).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark)
        )
        #expect(approximatelyEqual(resolved, .black))
    }

    @Test("light and dark variants differ when given different inputs")
    func variantsDiffer() {
        let pair = Color(light: .red, dark: .blue)
        let l = UIColor(pair).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let d = UIColor(pair).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        #expect(!approximatelyEqual(l, d))
    }

    /// CGColor equality is component-exact; compare RGBA floats with a tiny
    /// tolerance to absorb the SwiftUI→UIColor round-trip's float noise.
    private func approximatelyEqual(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        let eps: CGFloat = 0.001
        return abs(lr - rr) < eps && abs(lg - rg) < eps && abs(lb - rb) < eps && abs(la - ra) < eps
    }
}
