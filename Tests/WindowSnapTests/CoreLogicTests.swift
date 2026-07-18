import Testing
import Foundation
import CoreGraphics
import Carbon.HIToolbox
@testable import WindowSnap

// Unit tests for the pure logic that would regress silently: snap geometry,
// the calculator, key-name mapping, and the unit/time-zone catalogs.
// Swift Testing (not XCTest) because the Command Line Tools toolchain ships
// Testing but not XCTest.framework.

@Suite struct SnapRegionTests {
    let screen = CGRect(x: 100, y: 50, width: 1200, height: 900)

    @Test func halvesTileTheScreen() {
        let left = SnapRegion.leftHalf.frame(in: screen)
        let right = SnapRegion.rightHalf.frame(in: screen)
        #expect(left.union(right) == screen)
        #expect(left.intersection(right).width == 0)
        let top = SnapRegion.topHalf.frame(in: screen)
        let bottom = SnapRegion.bottomHalf.frame(in: screen)
        #expect(top.union(bottom) == screen)
    }

    @Test func quartersTileTheScreen() {
        let q: [SnapRegion] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let union = q.map { $0.frame(in: screen) }.reduce(CGRect.null) { $0.union($1) }
        #expect(union == screen)
        #expect(SnapRegion.topLeft.frame(in: screen).size == CGSize(width: 600, height: 450))
    }

    @Test func thirdsSpanTheWidth() {
        let frames = [SnapRegion.leftThird, .centerThird, .rightThird].map { $0.frame(in: screen) }
        #expect(abs(frames.map(\.width).reduce(0, +) - screen.width) < 0.001)
        for f in frames { #expect(f.height == screen.height) }
        #expect(abs(frames[1].minX - (screen.minX + screen.width / 3)) < 0.001)
    }

    @Test func maximizeAndCenter() {
        #expect(SnapRegion.maximize.frame(in: screen) == screen)
        let c = SnapRegion.center.frame(in: screen)
        #expect(abs(c.midX - screen.midX) < 0.001)
        #expect(abs(c.midY - screen.midY) < 0.001)
        #expect(c.size == CGSize(width: 600, height: 450))
    }

    @Test func everyRegionStaysInsideTheScreen() {
        for region in SnapRegion.allCases {
            #expect(screen.contains(region.frame(in: screen)),
                    "\(region.rawValue) escapes the visible frame")
        }
    }
}

@Suite struct CalculatorTests {
    @Test func arithmetic() {
        #expect(Calculator.evaluate("2+2") == "4")
        #expect(Calculator.evaluate("2+3*4") == "14")           // precedence
        #expect(Calculator.evaluate("(2+3)*4") == "20")
        #expect(Calculator.evaluate("2^10") == "1,024")   // grouping separator
    }

    @Test func invalidInputReturnsNil() {
        #expect(Calculator.evaluate("") == nil)
        #expect(Calculator.evaluate("hello world") == nil)
    }

    @Test func unitConversionProducesAValue() throws {
        // Don't pin the exact formatting — just require a numeric result.
        let out = try #require(Calculator.evaluate("1 km in m"))
        #expect(out.contains("1000") || out.contains("1,000"),
                "unexpected conversion output: \(out)")
    }
}

@Suite struct KeyNamesTests {
    @Test func arrowAndFunctionKeys() {
        #expect(KeyNames.string(for: UInt32(kVK_LeftArrow)) == "←")
        #expect(KeyNames.string(for: UInt32(kVK_Space)) == "Space")
        #expect(KeyNames.string(for: UInt32(kVK_F16)) == "F16")
    }

    @Test func regionLabels() {
        // Every SnapRegion raw value must have a human label (guards against a
        // new case being added without wiring its label).
        for region in SnapRegion.allCases {
            #expect(!KeyNames.regionLabel(region.rawValue).isEmpty)
        }
        #expect(KeyNames.regionLabel("leftHalf") == "Left Half")
    }
}

@Suite struct CatalogTests {
    @Test func unitCategoriesAreWellFormed() {
        #expect(!UnitCatalog.categories.isEmpty)
        let names = UnitCatalog.categories.map(\.name)
        #expect(names.count == Set(names).count, "duplicate category names")
        for cat in UnitCatalog.categories {
            #expect(cat.entries.count > 1, "\(cat.name) needs ≥2 units to convert between")
        }
    }

    @Test func everyZoneIDIsAValidTimeZone() {
        for group in UnitCatalog.zoneGroups {
            for zone in group.zones {
                #expect(TimeZone(identifier: zone.id) != nil,
                        "bad zone id \(zone.id) (\(zone.label))")
            }
        }
    }

    @Test func defaultWorldClockZonesAreValid() {
        for id in Settings.defaultWorldClockZones where !id.isEmpty {
            #expect(TimeZone(identifier: id) != nil, "bad default zone \(id)")
        }
    }
}
