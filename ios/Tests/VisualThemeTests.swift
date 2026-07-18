import UIKit
import XCTest

@testable import Pedals

@MainActor
final class VisualThemeTests: XCTestCase {
    func testMonochromeUIKitPaletteUsesOnlyWhiteWithAlphaOnBlack() {
        assertWhite(PedalsTheme.uiCanvas, component: 0, alpha: 1)
        assertWhite(PedalsTheme.uiContent, component: 1, alpha: 1)
        assertWhite(PedalsTheme.uiSecondaryContent, component: 1, alpha: 0.64)
        assertWhite(PedalsTheme.uiTertiaryContent, component: 1, alpha: 0.38)
        assertWhite(PedalsTheme.uiSurface, component: 1, alpha: 0.08)
        assertWhite(PedalsTheme.uiSeparator, component: 1, alpha: 0.16)
        assertWhite(PedalsTheme.uiSelection, component: 1, alpha: 0.18)
    }

    func testColoredRolesAreLimitedToWarningAndCritical() {
        XCTAssertEqual(PedalsTheme.uiWarning, UIColor.systemOrange)
        XCTAssertEqual(PedalsTheme.uiCritical, UIColor.systemRed)
    }

    func testBrandMarkIsPackagedForOnboarding() {
        XCTAssertNotNil(UIImage(named: "AppMark"))
    }

    private func assertWhite(
        _ color: UIColor,
        component expectedComponent: CGFloat,
        alpha expectedAlpha: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var component: CGFloat = -1
        var alpha: CGFloat = -1
        XCTAssertTrue(
            color.getWhite(&component, alpha: &alpha),
            "Expected a monochrome color",
            file: file,
            line: line
        )
        XCTAssertEqual(component, expectedComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(alpha, expectedAlpha, accuracy: 0.001, file: file, line: line)
    }
}
