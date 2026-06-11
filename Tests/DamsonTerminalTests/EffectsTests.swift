import XCTest
import simd
@testable import DamsonTerminal

/// Unit tests for the screen-effect parameter tables and the per-glyph animation
/// transforms — the pure-logic halves of the effects system. (Shader compilation is
/// covered by the Metal image tests, which build the runtime library.)
final class EffectsTests: XCTestCase {

    // MARK: - ScreenEffect parameter table

    private let size = SIMD2<Float>(1920, 1080)

    func testEveryEffectExceptNoneProducesParams() {
        for e in ScreenEffect.allCases {
            let p = e.postFXParams(screenSize: size, intensity: 0.8)
            if e == .none {
                XCTAssertNil(p)
            } else {
                XCTAssertNotNil(p, "\(e) must produce post-fx params")
                XCTAssertEqual(p?.screenSize, size)
            }
            XCTAssertEqual(e.isActive, e != .none)
        }
    }

    func testNewEffectsDriveTheirDedicatedChannels() {
        func params(_ e: ScreenEffect) -> PostFXParams { e.postFXParams(screenSize: size, intensity: 1)! }

        // VHS: chromatic aberration (coeffs2.z) + grain (coeffs2.w), no monochrome.
        let vhs = params(.vhs)
        XCTAssertGreaterThan(vhs.coeffs2.z, 0, "vhs needs aberration")
        XCTAssertGreaterThan(vhs.coeffs2.w, 0, "vhs needs grain")
        XCTAssertEqual(vhs.coeffs2.y, 0, "vhs is not monochrome")

        // Aperture grille: stripe mask (coeffs3.z) + scanlines.
        let grille = params(.apertureGrille)
        XCTAssertGreaterThan(grille.coeffs3.z, 0)
        XCTAssertGreaterThan(grille.coeffs.x, 0)

        // Sepia/blueprint: monochrome onto a non-neutral tint.
        for e in [ScreenEffect.sepia, .blueprint] {
            let p = params(e)
            XCTAssertGreaterThan(p.coeffs2.y, 0, "\(e) is monochrome")
            XCTAssertNotEqual(p.tint.x, p.tint.z, "\(e) tint must be colored")
        }

        // Pixelate: block size in device px, at least 2.
        XCTAssertGreaterThanOrEqual(params(.pixelate).coeffs3.y, 2)

        // Invert: inversion channel; full negative at max intensity.
        XCTAssertEqual(params(.invert).coeffs3.x, 1)

        // Pre-existing effects keep their new channels at zero (no accidental bleed).
        for e in [ScreenEffect.crt, .greenPhosphor, .amberPhosphor, .grayscale, .bloom] {
            let p = params(e)
            XCTAssertEqual(p.coeffs3, .zero, "\(e) must not use coeffs3")
            XCTAssertEqual(p.coeffs2.z, 0, "\(e) must not aberrate")
        }
    }

    func testIntensityScalesDown() {
        // Low intensity must not exceed high intensity on the scaled channels.
        let lo = ScreenEffect.vhs.postFXParams(screenSize: size, intensity: 0.2)!
        let hi = ScreenEffect.vhs.postFXParams(screenSize: size, intensity: 1.0)!
        XCTAssertLessThan(lo.coeffs2.z, hi.coeffs2.z)
        XCTAssertLessThan(lo.coeffs2.w, hi.coeffs2.w)
    }

    // MARK: - GlyphAnimStyle transforms

    private func makeInst() -> GlyphInstance {
        GlyphInstance(origin: SIMD2<Float>(100, 200), size: SIMD2<Float>(10, 20),
                      uvOrigin: SIMD2<Float>(0.5, 0.5), uvSize: SIMD2<Float>(0.1, 0.1),
                      color: SIMD4<Float>(1, 1, 1, 1))
    }

    func testShaderFXStylesAreMarked() {
        XCTAssertTrue(GlyphAnimStyle.dissolve.usesShaderFX)
        XCTAssertTrue(GlyphAnimStyle.burst.usesShaderFX)
        XCTAssertTrue(GlyphAnimStyle.burn.usesShaderFX)
        XCTAssertTrue(GlyphAnimStyle.glitch.usesShaderFX)
        for s in [GlyphAnimStyle.none, .fade, .pop, .slide, .typewriter, .flip, .drop] {
            XCTAssertFalse(s.usesShaderFX, "\(s) is a pure instance transform")
        }
    }

    func testEveryStyleEndsFullyVisibleOnAppear() {
        // p=1 appearing → the glyph must be at (or extremely near) its resting state.
        for s in GlyphAnimStyle.allCases where s != .none {
            let inst = makeInst()
            let out = s.apply(to: inst, appearing: true, p: 1)
            XCTAssertEqual(out.color.w, 1, accuracy: 0.01, "\(s) must end opaque")
            XCTAssertEqual(out.origin.x, inst.origin.x, accuracy: 0.6, "\(s) x at rest")
            XCTAssertEqual(out.origin.y, inst.origin.y, accuracy: 0.6, "\(s) y at rest")
            XCTAssertEqual(out.fx.x, 0, accuracy: 0.01, "\(s) erosion done")
            XCTAssertEqual(out.fx.y, 0, accuracy: 0.01, "\(s) glitch done")
        }
    }

    func testEveryStyleEndsInvisibleOnDisappear() {
        // p=1 disappearing → either alpha ≈ 0 or the shader erosion is at max.
        for s in GlyphAnimStyle.allCases where s != .none {
            let out = s.apply(to: makeInst(), appearing: false, p: 1)
            let gone = out.color.w <= 0.05 || out.fx.x >= 0.95
            XCTAssertTrue(gone, "\(s) must be gone at the end (alpha \(out.color.w), fx.x \(out.fx.x))")
        }
    }

    func testTypewriterStampsFromAboveScale() {
        let inst = makeInst()
        let early = GlyphAnimStyle.typewriter.apply(to: inst, appearing: true, p: 0.05)
        XCTAssertGreaterThan(early.size.x, inst.size.x, "stamp starts oversized")
        // Centered: the center must not move.
        XCTAssertEqual(early.origin.x + early.size.x / 2, inst.origin.x + inst.size.x / 2,
                       accuracy: 0.01)
    }

    func testFlipCollapsesWidthOnly() {
        let inst = makeInst()
        let mid = GlyphAnimStyle.flip.apply(to: inst, appearing: false, p: 0.9)
        XCTAssertLessThan(mid.size.x, inst.size.x * 0.5, "width collapses")
        XCTAssertEqual(mid.size.y, inst.size.y, "height untouched")
    }

    func testDropFallsFromAboveAndBelow() {
        let inst = makeInst()
        let inEarly = GlyphAnimStyle.drop.apply(to: inst, appearing: true, p: 0.05)
        XCTAssertLessThan(inEarly.origin.y, inst.origin.y, "appears from above")
        let outLate = GlyphAnimStyle.drop.apply(to: inst, appearing: false, p: 0.9)
        XCTAssertGreaterThan(outLate.origin.y, inst.origin.y, "falls away below")
    }

    func testBurnAndGlitchDriveFXChannels() {
        let inst = makeInst()
        let burnMid = GlyphAnimStyle.burn.apply(to: inst, appearing: false, p: 0.5)
        XCTAssertGreaterThan(burnMid.fx.x, 0, "burn erodes")
        XCTAssertEqual(burnMid.fx.z, 1, "burn flags the ember rim")
        let glitchMid = GlyphAnimStyle.glitch.apply(to: inst, appearing: false, p: 0.5)
        XCTAssertGreaterThan(glitchMid.fx.y, 0, "glitch drives slice tearing")
    }

    func testDurationsArePositiveAndBounded() {
        for s in GlyphAnimStyle.allCases where s != .none {
            for appearing in [true, false] {
                let d = s.duration(appearing: appearing)
                XCTAssertGreaterThan(d, 0.03)
                XCTAssertLessThan(d, 0.6, "\(s) anim must stay snappy")
            }
        }
    }
}
