import XCTest
import UIKit
@testable import VBoardApp

final class PencilCapabilityContractTests: XCTestCase {
    func testGenerationProfilesDescribeOnlyDocumentedContractDifferences() {
        let first = PencilGenerationProfile.firstGeneration.capabilities
        XCTAssertTrue(first.pressure && first.tilt && first.azimuth)
        XCTAssertFalse(first.hover || first.doubleTap || first.squeeze || first.barrelRoll || first.pencilHaptics)

        let second = PencilGenerationProfile.secondGeneration.capabilities
        XCTAssertTrue(second.pressure && second.doubleTap && second.hover)
        XCTAssertFalse(second.squeeze || second.barrelRoll || second.pencilHaptics)

        let usbC = PencilGenerationProfile.usbC.capabilities
        XCTAssertFalse(usbC.pressure || usbC.doubleTap || usbC.squeeze || usbC.barrelRoll || usbC.pencilHaptics)
        XCTAssertTrue(usbC.tilt && usbC.azimuth && usbC.hover)

        let pro = PencilGenerationProfile.pro.capabilities
        XCTAssertTrue(pro.pressure && pro.tilt && pro.azimuth && pro.hover)
        XCTAssertTrue(pro.doubleTap && pro.squeeze && pro.barrelRoll && pro.pencilHaptics)
    }

    func testEverySystemDoubleTapActionMapsExactlyOnce() {
        let mappings: [(PencilPreferredAction, PencilLogicalAction)] = [
            (.ignore, .none), (.switchEraser, .switchEraser),
            (.switchPrevious, .switchPrevious), (.showColorPalette, .showColorPalette),
            (.showInkAttributes, .showInkAttributes),
            (.showContextualPalette, .showToolPalette),
            (.runSystemShortcut, .runSystemShortcut), (.unknown, .none)
        ]
        for (system, expected) in mappings {
            XCTAssertEqual(PencilActionResolver.doubleTap(setting: .followSystem,
                                                           system: system), expected)
        }
    }

    func testExplicitActionOverridesAndUnsupportedCapability() {
        XCTAssertEqual(PencilActionResolver.doubleTap(setting: .previousTool,
                                                       system: .ignore), .switchPrevious)
        XCTAssertEqual(PencilActionResolver.doubleTap(setting: .eraser,
                                                       system: .showColorPalette), .switchEraser)
        XCTAssertEqual(PencilActionResolver.doubleTap(setting: .palette,
                                                       system: .ignore), .showToolPalette)
        XCTAssertEqual(PencilActionResolver.doubleTap(setting: .off,
                                                       system: .switchEraser), .none)
        XCTAssertEqual(PencilActionResolver.doubleTap(setting: .eraser,
                                                       system: .switchEraser,
                                                       supported: false), .none)
        XCTAssertEqual(PencilActionResolver.squeeze(setting: .inkAttributes,
                                                     system: .ignore), .showInkAttributes)
        XCTAssertEqual(PencilActionResolver.squeeze(setting: .off,
                                                     system: .showContextualPalette), .none)
    }
}

final class PencilDeliveryPipelineTests: XCTestCase {
    private func point(_ x: Double, pressure: Double = 0.5, timestamp: Double,
                       estimate: Int? = nil, roll: Double? = nil) -> StrokePoint {
        StrokePoint(x: x, y: x, pressure: pressure, altitude: 1, azimuth: 0.4,
                    roll: roll, timestamp: timestamp, estimationUpdateIndex: estimate)
    }

    func testConfirmedSamplesStayOrderedAndPrimaryDuplicateIsReplaced() {
        var pipeline = PencilStrokeAccumulator()
        pipeline.appendConfirmed([point(1, timestamp: 1), point(2, timestamp: 2)])
        pipeline.appendConfirmed([point(2, pressure: 0.8, timestamp: 2),
                                  point(3, timestamp: 3)])
        XCTAssertEqual(pipeline.canonicalPoints.map(\.x), [1, 2, 3])
        XCTAssertEqual(pipeline.canonicalPoints[1].pressure, 0.8)
    }

    func testPredictedTailAppearsLiveButNeverCanonical() {
        var pipeline = PencilStrokeAccumulator()
        pipeline.appendConfirmed([point(1, timestamp: 1), point(2, timestamp: 2)])
        pipeline.setPredicted([point(3, timestamp: 3), point(4, timestamp: 4)])
        XCTAssertEqual(pipeline.livePoints.map(\.x), [1, 2, 3, 4])
        XCTAssertEqual(pipeline.canonicalPoints.map(\.x), [1, 2])
    }

    func testEstimatedCorrectionUpdatesSameSampleWithoutDuplicate() {
        var pipeline = PencilStrokeAccumulator()
        pipeline.appendConfirmed([point(1, pressure: 0.2, timestamp: 1, estimate: 42)])
        pipeline.replaceEstimated([point(1.1, pressure: 0.9, timestamp: 1.1,
                                         estimate: 42, roll: 1.2)])
        XCTAssertEqual(pipeline.canonicalPoints.count, 1)
        XCTAssertEqual(pipeline.canonicalPoints[0].x, 1.1)
        XCTAssertEqual(pipeline.canonicalPoints[0].pressure, 0.9)
        XCTAssertEqual(pipeline.canonicalPoints[0].roll, 1.2)
    }

    func testLateEstimatedCorrectionKeepsCommittedStrokeIdentity() {
        let stroke = UserStroke(id: "stable", points: [
            point(1, pressure: 0.2, timestamp: 1, estimate: 42)
        ], pencilTool: .pen)
        let corrected = PencilStrokeCorrection.applying([
            point(1.1, pressure: 0.9, timestamp: 1.1, estimate: 42, roll: 1.2)
        ], to: stroke)
        XCTAssertEqual(corrected?.id, "stable")
        XCTAssertEqual(corrected?.points.count, 1)
        XCTAssertEqual(corrected?.points[0].pressure, 0.9)
        XCTAssertEqual(corrected?.points[0].roll, 1.2)
    }
}

final class PencilGeometryAndPressureTests: XCTestCase {
    func testPressureNormalizationClampsAndHandlesUnavailableSensor() {
        XCTAssertNil(PencilPressureResponse.normalized(force: 1, maximum: 0))
        XCTAssertNil(PencilPressureResponse.normalized(force: .nan, maximum: 4))
        XCTAssertNil(PencilPressureResponse.normalized(force: 2, maximum: 4,
                                                        supported: false))
        XCTAssertEqual(PencilPressureResponse.normalized(force: -1, maximum: 4), 0)
        XCTAssertEqual(PencilPressureResponse.normalized(force: 9, maximum: 4), 1)
        XCTAssertEqual(PencilPressureResponse.normalized(force: 2, maximum: 4), 0.5)
    }

    func testPressureMappingIsFiniteVisibleAndMonotonic() {
        let values = stride(from: CGFloat(0), through: 1, by: 0.05)
            .map { PencilPressureResponse.widthMultiplier(forDisplayPressure: $0) }
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy(<=))
        XCTAssertTrue(values.allSatisfy(\.isFinite))
        XCTAssertEqual(values.first ?? 0, 0.55, accuracy: 0.000_01)
        XCTAssertEqual(values.last ?? 0, 1.65, accuracy: 0.000_01)
        XCTAssertLessThan(PencilPressureResponse.widthMultiplier(forDisplayPressure: 0.10),
                          PencilPressureResponse.widthMultiplier(forDisplayPressure: 0.87))
        XCTAssertEqual(PencilPressureResponse.widthMultiplier(forDisplayPressure: nil), 1)
    }

    func testPressureSmoothingRespondsWithoutOverwritingOrDoubleCurvingSamples() {
        let light = PencilPressureResponse.smoothed(previous: nil, sample: 0.10)
        let firm = PencilPressureResponse.smoothed(previous: light, sample: 0.90)
        XCTAssertEqual(light, 0.10, accuracy: 0.000_01)
        XCTAssertEqual(firm, 0.54, accuracy: 0.000_01)
        XCTAssertGreaterThan(PencilPressureResponse.widthMultiplier(forDisplayPressure: firm), 1)
    }

    func testAppleRawRollConvertsToClockwisePositiveScreenAngles() {
        let inputs: [CGFloat] = [0, .pi / 2, .pi, 3 * .pi / 2, 2 * .pi]
        let expected: [CGFloat] = [0, 3 * .pi / 2, .pi, .pi / 2, 0]
        for (raw, screen) in zip(inputs, expected) {
            XCTAssertEqual(PencilScreenAngle.roll(fromAppleRaw: raw), screen,
                           accuracy: 0.000_01)
        }
    }

    func testMeasuredPhysicalClockwiseRawDecreaseBecomesClockwiseScreenIncrease() {
        let rawStart = CGFloat(-167) * .pi / 180
        let rawClockwise = CGFloat(-257) * .pi / 180
        let screenStart = PencilScreenAngle.roll(fromAppleRaw: rawStart)
        let screenClockwise = PencilScreenAngle.roll(fromAppleRaw: rawClockwise)
        XCTAssertEqual(PencilAngleMath.shortestDelta(from: screenStart,
                                                     to: screenClockwise),
                       .pi / 2, accuracy: 0.000_01)
        XCTAssertEqual(PencilAngleMath.shortestDelta(from: screenClockwise,
                                                     to: screenStart),
                       -.pi / 2, accuracy: 0.000_01)
    }

    func testScreenRollConversionStaysContinuousAcrossBothWrapDirections() {
        let clockwise = PencilAngleMath.shortestDelta(
            from: PencilScreenAngle.roll(fromAppleRaw: CGFloat(-179) * .pi / 180),
            to: PencilScreenAngle.roll(fromAppleRaw: CGFloat(179) * .pi / 180)
        )
        let counterclockwise = PencilAngleMath.shortestDelta(
            from: PencilScreenAngle.roll(fromAppleRaw: CGFloat(179) * .pi / 180),
            to: PencilScreenAngle.roll(fromAppleRaw: CGFloat(-179) * .pi / 180)
        )
        XCTAssertEqual(clockwise, CGFloat(2) * .pi / 180, accuracy: 0.000_01)
        XCTAssertEqual(counterclockwise, CGFloat(-2) * .pi / 180, accuracy: 0.000_01)
    }

    func testRollUsesShortestPathAcrossZeroDegrees() {
        let start = CGFloat(359) * .pi / 180
        let end: CGFloat = 0
        XCTAssertEqual(PencilAngleMath.shortestDelta(from: start, to: end),
                       .pi / 180, accuracy: 0.000_01)
        let midpoint = PencilAngleMath.interpolated(from: start, to: end, fraction: 0.5)
        XCTAssertTrue(midpoint > CGFloat(359) * .pi / 180 || midpoint < CGFloat(1) * .pi / 180)
    }

    func testMarkerFootprintHonorsCardinalRollAngles() {
        for degrees in [0, 90, 180, 270] {
            let angle = CGFloat(degrees) * .pi / 180
            let nib = PencilNibGeometry.marker(baseWidth: 20, pressure: 0.5,
                                               altitude: .pi / 3, azimuth: 0,
                                               roll: angle)
            XCTAssertEqual(nib.orientation,
                           PencilScreenAngle.roll(fromAppleRaw: angle),
                           accuracy: 0.000_01)
            XCTAssertGreaterThan(nib.majorAxis, nib.minorAxis)
        }
    }

    func testMarkerOrientationCombinesAbsoluteAzimuthAndRelativeScreenRoll() {
        let nib = PencilNibGeometry.marker(baseWidth: 20, pressure: 0.5,
                                           altitude: .pi / 3,
                                           azimuth: .pi / 2,
                                           roll: .pi / 4)
        XCTAssertEqual(nib.orientation, .pi / 4, accuracy: 0.000_01)
        let fallback = PencilNibGeometry.marker(baseWidth: 20, pressure: nil,
                                                altitude: .pi / 2,
                                                azimuth: .pi / 3,
                                                roll: 0)
        XCTAssertEqual(fallback.orientation, .pi / 3, accuracy: 0.000_01)
    }

    func testMarkerPathRotatesVisibleChiselFootprint() {
        let horizontal = [StrokePoint(x: 50, y: 50, pressure: 0.5, roll: 0)]
        let vertical = [StrokePoint(x: 50, y: 50, pressure: 0.5, roll: .pi / 2)]
        let horizontalBounds = PencilStrokeGeometry.path(points: horizontal, tool: .marker,
                                                         baseWidth: 24).boundingBox
        let verticalBounds = PencilStrokeGeometry.path(points: vertical, tool: .marker,
                                                       baseWidth: 24).boundingBox
        XCTAssertGreaterThan(horizontalBounds.width, horizontalBounds.height)
        XCTAssertGreaterThan(verticalBounds.height, verticalBounds.width)
    }

    func testMarkerGeometryHasNoGapBetweenWidelySpacedSamples() {
        let points = [
            StrokePoint(x: 0, y: 0, pressure: 0.2, altitude: 0.7,
                        azimuth: 0.1, roll: 0.2),
            StrokePoint(x: 160, y: 40, pressure: 0.9, altitude: 1.2,
                        azimuth: 1.0, roll: 1.1)
        ]
        let path = PencilStrokeGeometry.path(points: points, tool: .marker, baseWidth: 24)
        for step in 0...20 {
            let fraction = CGFloat(step) / 20
            XCTAssertTrue(path.contains(CGPoint(x: 160 * fraction, y: 40 * fraction)),
                          "Marker left a gap at interpolation step \(step)")
        }
    }


    func testPenRibbonIsOneClosedOutlineAndContainsItsCenterline() {
        var points: [StrokePoint] = []
        for index in 0...20 {
            let x = Double(index * 8)
            let y = Double(40 + index % 3)
            let pressure = Double(index) / 20.0
            points.append(StrokePoint(x: x, y: y, pressure: pressure))
        }
        let path = PencilStrokeGeometry.path(points: points, tool: .pen, baseWidth: 12)
        let counts = elementCounts(path)
        XCTAssertEqual(counts.moves, 1)
        XCTAssertEqual(counts.closes, 1)
        for point in points {
            XCTAssertTrue(path.contains(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))),
                          "Pen ribbon left a centerline hole at \(point.x), \(point.y)")
        }
    }

    func testMarkerRibbonIsOneClosedOutlineRatherThanRepeatedStamps() {
        var points: [StrokePoint] = []
        for index in 0...30 {
            let roll = Double(index) * Double.pi / 180.0
            points.append(StrokePoint(x: Double(index * 6), y: Double(index),
                                      pressure: 0.5, altitude: 0.9,
                                      azimuth: 0.7, roll: roll))
        }
        let path = PencilStrokeGeometry.path(points: points, tool: .marker, baseWidth: 24)
        let counts = elementCounts(path)
        XCTAssertEqual(counts.moves, 1)
        XCTAssertEqual(counts.closes, 1)
        for step in 0...30 {
            XCTAssertTrue(path.contains(CGPoint(x: CGFloat(step * 6), y: CGFloat(step))))
        }
    }

    private func elementCounts(_ path: CGPath) -> (moves: Int, closes: Int) {
        var moves = 0
        var closes = 0
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint: moves += 1
            case .closeSubpath: closes += 1
            default: break
            }
        }
        return (moves, closes)
    }
}

final class ContinuousEraseTransactionTests: XCTestCase {
    func testMovementHidesOnlyFreshHitsAndCommitReturnsOneGestureBatch() {
        var transaction = ContinuousEraseTransaction<String>()
        transaction.begin()

        XCTAssertEqual(transaction.register(["stroke-a", "path-b"]),
                       ["stroke-a", "path-b"])
        XCTAssertEqual(transaction.register(["path-b", "note-c"]), ["note-c"])
        XCTAssertEqual(transaction.erasedIDs, ["stroke-a", "path-b", "note-c"])

        let oneUndoBatch = transaction.commit()
        XCTAssertEqual(oneUndoBatch, ["stroke-a", "path-b", "note-c"])
        XCTAssertFalse(transaction.isActive)
        XCTAssertTrue(transaction.commit().isEmpty,
                      "One physical gesture must not produce a second deletion batch")
    }

    func testCancellationReturnsEveryTransientHitForImmediateRestoration() {
        var transaction = ContinuousEraseTransaction<Int>()
        transaction.begin()
        _ = transaction.register([1, 2, 3])

        XCTAssertEqual(transaction.cancel(), [1, 2, 3])
        XCTAssertTrue(transaction.erasedIDs.isEmpty)
        XCTAssertFalse(transaction.isActive)
        XCTAssertTrue(transaction.commit().isEmpty)
        XCTAssertTrue(transaction.register([4]).isEmpty,
                      "Hits outside an active gesture have no deletion authority")
    }
}

@MainActor
final class SelectionGenerationContractTests: XCTestCase {
    func testEveryDifferentSelectionIncludingClearAdvancesGeneration() {
        let store = LectureWorkspaceStore(folderID: "selection-generation-test")
        let first = SelectionKey(boardID: "board-a", objectID: "stroke-a",
                                 kind: .editorObject, objectType: "stroke")
        let second = SelectionKey(boardID: "board-a", objectID: "path-b",
                                  kind: .professorPath, objectType: "path")

        XCTAssertEqual(store.selectionGeneration, 0)
        store.setSelection([first])
        XCTAssertEqual(store.selectionGeneration, 1)
        store.setSelection([first])
        XCTAssertEqual(store.selectionGeneration, 1,
                       "A duplicate callback must not create a fake selection generation")
        store.setSelection([first, second])
        XCTAssertEqual(store.selectionGeneration, 2)
        store.setSelection([])
        XCTAssertEqual(store.selectionGeneration, 3,
                       "Starting another tool or lasso invalidates the old toolbar epoch")
        XCTAssertTrue(store.selectedKeys.isEmpty)
    }
}

final class CanvasAppearanceContractTests: XCTestCase {
    func testCanvasTokensDoNotInvertWithSystemAppearance() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for color in [CanvasDesignTokens.canvasBackground,
                      CanvasDesignTokens.boardSurface,
                      CanvasDesignTokens.canvasPrimaryText,
                      CanvasDesignTokens.dotColor] {
            XCTAssertEqual(color.resolvedColor(with: light), color.resolvedColor(with: dark))
        }
    }

    func testCanvasTextContrastsWithWhiteboardSurface() {
        let background = relativeLuminance(CanvasDesignTokens.boardSurface)
        let foreground = relativeLuminance(CanvasDesignTokens.canvasPrimaryText)
        let lighter = max(background, foreground)
        let darker = min(background, foreground)
        XCTAssertGreaterThanOrEqual((lighter + 0.05) / (darker + 0.05), 4.5)
    }

    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: nil))
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

final class PencilPaletteAndArbitrationTests: XCTestCase {
    func testResizeHandleInvisibleTargetIsWithinPencilGuidance() {
        XCTAssertGreaterThanOrEqual(PencilHitTarget.resizeHandleRadius * 2, 28)
        XCTAssertLessThanOrEqual(PencilHitTarget.resizeHandleRadius * 2, 44)
    }

    func testOneSqueezeProducesOnePaletteLifecycle() {
        var state = PencilPaletteStateMachine()
        XCTAssertEqual(state.receive(.began, anchor: CGPoint(x: 10, y: 20)),
                       .present(CGPoint(x: 10, y: 20), highlightedIndex: 0))
        XCTAssertEqual(state.receive(.began, anchor: CGPoint(x: 11, y: 21)), .none)
        XCTAssertEqual(state.receive(.changed, anchor: CGPoint(x: 12, y: 22)),
                       .update(CGPoint(x: 12, y: 22), highlightedIndex: 0,
                               selectionChanged: false))
        XCTAssertEqual(state.receive(.ended, anchor: CGPoint(x: 13, y: 23)),
                       .commit(highlightedIndex: 0))
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.dismiss(), .none)
    }

    func testSqueezeCancellationDismissesAndClearsHitBlockingState() {
        var state = PencilPaletteStateMachine()
        _ = state.receive(.began, anchor: nil)
        XCTAssertEqual(state.receive(.cancelled, anchor: nil), .dismiss)
        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.anchor)
        XCTAssertEqual(state.receive(.cancelled, anchor: nil), .none)
    }

    func testPalettePlacementFlipsAndClampsAtScreenEdges() {
        let bounds = CGRect(x: 8, y: 8, width: 1_008, height: 752)
        let size = CGSize(width: 300, height: 60)
        let right = PencilPalettePlacement.origin(anchor: CGPoint(x: 1_000, y: 400),
                                                  paletteSize: size, safeBounds: bounds)
        XCTAssertLessThan(right.x, 1_000)
        XCTAssertTrue(bounds.contains(CGRect(origin: right, size: size)))
        let corner = PencilPalettePlacement.origin(anchor: CGPoint(x: 0, y: 0),
                                                   paletteSize: size, safeBounds: bounds)
        XCTAssertTrue(bounds.contains(CGRect(origin: corner, size: size)))
        let center = PencilPalettePlacement.center(
            anchor: CGPoint(x: 0, y: 0), radius: 112, safeBounds: bounds
        )
        XCTAssertGreaterThanOrEqual(center.x - 112, bounds.minX)
        XCTAssertGreaterThanOrEqual(center.y - 112, bounds.minY)
    }

    func testClockwiseRollAdvancesRadialSectorAcrossWraparound() {
        var state = PencilPaletteStateMachine()
        _ = state.receive(.began, anchor: .zero,
                          roll: CGFloat(350.0 * .pi / 180), initialIndex: 1)
        XCTAssertEqual(
            state.receive(.changed, anchor: .zero,
                          roll: CGFloat(50.0 * .pi / 180)),
            .update(.zero, highlightedIndex: 2, selectionChanged: true)
        )
    }

    func testCounterclockwiseRollMovesRadialSectorCounterclockwise() {
        var state = PencilPaletteStateMachine()
        _ = state.receive(.began, anchor: .zero, roll: 0, initialIndex: 0)
        XCTAssertEqual(
            state.receive(.changed, anchor: .zero, roll: -.pi / 3),
            .update(.zero, highlightedIndex: 3, selectionChanged: true)
        )
    }

    func testRadialSectorHysteresisPreventsBoundaryJitter() {
        var state = PencilPaletteStateMachine()
        _ = state.receive(.began, anchor: .zero, roll: 0, initialIndex: 0)
        let underForwardThreshold = CGFloat(52.0 * .pi / 180)
        XCTAssertEqual(
            state.receive(.changed, anchor: .zero, roll: underForwardThreshold),
            .update(.zero, highlightedIndex: 0, selectionChanged: false)
        )
        XCTAssertEqual(
            state.receive(.changed, anchor: .zero, roll: CGFloat(54.0 * .pi / 180)),
            .update(.zero, highlightedIndex: 1, selectionChanged: true)
        )
        XCTAssertEqual(
            state.receive(.changed, anchor: .zero, roll: CGFloat(38.0 * .pi / 180)),
            .update(.zero, highlightedIndex: 1, selectionChanged: false)
        )
        XCTAssertEqual(
            state.receive(.changed, anchor: .zero, roll: CGFloat(36.0 * .pi / 180)),
            .update(.zero, highlightedIndex: 0, selectionChanged: true)
        )
    }

    func testCancelledSqueezeNeverCommitsHighlightedSector() {
        var state = PencilPaletteStateMachine()
        _ = state.receive(.began, anchor: .zero, roll: 0, initialIndex: 2)
        _ = state.receive(.changed, anchor: .zero, roll: .pi / 2)
        XCTAssertEqual(state.receive(.cancelled, anchor: .zero), .dismiss)
        XCTAssertFalse(state.isPresented)
    }

    func testToolContactMatrixHasOneDeterministicOwner() {
        let expected: [CanvasTool: [CanvasInputOwner]] = [
            .navigation: [.navigation, .navigation, .navigation],
            .pen: [.stroke, .stroke, .stroke],
            .highlighter: [.stroke, .stroke, .stroke],
            .objectEraser: [.eraser, .eraser, .eraser],
            .lasso: [.lasso, .lasso, .lasso],
            .select: [.selection, .selection, .selection]
        ]
        let contacts: [CanvasInputContact] = [.pencil, .finger, .primaryPointer]
        for tool in CanvasTool.allCases {
            XCTAssertEqual(contacts.map {
                CanvasInputArbitrationPolicy.owner(tool: tool, contact: $0,
                                                   drawsWithFinger: true)
            }, expected[tool], "Unexpected owner for \(tool)")
        }
    }

    func testEditingOwnershipDoesNotDependOnBoardRenderState() {
        enum RenderState: CaseIterable { case blank, image, pdf, vectorPreview, vectorExact }
        for state in RenderState.allCases {
            _ = state
            XCTAssertEqual(CanvasInputArbitrationPolicy.owner(
                tool: .lasso, contact: .finger, drawsWithFinger: false
            ), .lasso)
            XCTAssertEqual(CanvasInputArbitrationPolicy.owner(
                tool: .objectEraser, contact: .finger, drawsWithFinger: false
            ), .eraser)
            XCTAssertEqual(CanvasInputArbitrationPolicy.owner(
                tool: .select, contact: .primaryPointer, drawsWithFinger: false
            ), .selection)
        }
    }

    func testOneFingerNeverNavigatesWhileEditingToolSelected() {
        for tool in CanvasTool.allCases where tool != .navigation {
            XCTAssertEqual(CanvasInputArbitrationPolicy.minimumDirectNavigationTouches(tool: tool), 2)
        }
        XCTAssertEqual(CanvasInputArbitrationPolicy.minimumDirectNavigationTouches(tool: .navigation), 1)
        XCTAssertEqual(CanvasInputArbitrationPolicy.owner(
            tool: .pen, contact: .finger, drawsWithFinger: false
        ), .none)
        XCTAssertEqual(CanvasInputArbitrationPolicy.owner(
            tool: .lasso, contact: .finger, drawsWithFinger: false
        ), .lasso)
        XCTAssertEqual(CanvasInputArbitrationPolicy.owner(
            tool: .lasso, contact: .finger, contactCount: 2, drawsWithFinger: false
        ), .navigation)
        XCTAssertEqual(CanvasInputArbitrationPolicy.owner(
            tool: .pen, contact: .palm, drawsWithFinger: true
        ), .none)
    }

    func testCanvasGesturesRejectVisibleControlDescendantsButAcceptCanvasContent() {
        let canvas = UIView()
        let content = UIView()
        let button = UIButton(type: .system)
        let buttonLabelContainer = UIView()
        canvas.addSubview(content)
        canvas.addSubview(button)
        button.addSubview(buttonLabelContainer)

        XCTAssertTrue(CanvasGestureHitTestPolicy.allowsCanvasGesture(
            from: content, canvasRoot: canvas
        ))
        XCTAssertFalse(CanvasGestureHitTestPolicy.allowsCanvasGesture(
            from: button, canvasRoot: canvas
        ))
        XCTAssertFalse(CanvasGestureHitTestPolicy.allowsCanvasGesture(
            from: buttonLabelContainer, canvasRoot: canvas
        ))
    }
}

final class PencilPersistenceTests: XCTestCase {
    func testLegacyStrokeDecodesWithoutAdvancedMetadata() throws {
        let data = Data("""
        {"id":"old","type":"stroke","color":"#000000","width":4,"opacity":1,"points":[{"x":1,"y":2,"p":0.5}],"translation":{"x":0,"y":0}}
        """.utf8)
        let stroke = try JSONDecoder().decode(UserStroke.self, from: data)
        XCTAssertNil(stroke.pencilTool)
        XCTAssertNil(stroke.points[0].altitude)
        XCTAssertNil(stroke.points[0].roll)
    }

    func testAdvancedMarkerMetadataRoundTripsExactly() throws {
        let point = StrokePoint(x: -20, y: 30, pressure: 0.72, altitude: 0.8,
                                azimuth: 1.1, roll: 6.27, timestamp: 123.4,
                                estimationUpdateIndex: 9)
        let stroke = UserStroke(id: "new", color: "#FFD60A", width: 22,
                                opacity: 0.32, points: [point], pencilTool: .marker)
        let decoded = try JSONDecoder().decode(UserStroke.self,
                                               from: JSONEncoder().encode(stroke))
        XCTAssertEqual(decoded, stroke)
        XCTAssertEqual(decoded.points[0].pressure, 0.72)
        XCTAssertEqual(decoded.points[0].roll, 6.27)
    }

    func testCanvasObjectKeepsPencilMetadataAcrossMoveAndResize() throws {
        let point = WorldPoint(x: 1, y: 2, pressure: 0.4, altitude: 0.7,
                               azimuth: 0.9, roll: 1.3, timestamp: 2,
                               estimationUpdateIndex: 4)
        let object = CanvasObject(id: "stroke", type: "stroke", color: "#123456",
                                  width: 10, opacity: 0.5, points: [point],
                                  translation: nil, sourceMarkdown: nil, text: nil,
                                  x: nil, y: nil, height: nil, fontSize: nil,
                                  pencilTool: .marker)
        let moved = object.translated(by: CGPoint(x: 3, y: 4))
        let scaled = moved.scaled(around: .zero, by: 2)
        XCTAssertEqual(scaled.pencilTool, .marker)
        XCTAssertEqual(scaled.points?.first?.roll, 1.3)
        let decoded = try JSONDecoder().decode(CanvasObject.self,
                                               from: JSONEncoder().encode(scaled))
        XCTAssertEqual(decoded, scaled)
    }
}

@MainActor
final class PencilInteractionOwnershipTests: XCTestCase {
    private func lectureCallbacks() -> LectureCanvasCallbacks {
        LectureCanvasCallbacks(onCameraChanged: { _ in }, onActiveBoardChanged: { _ in },
                               onDetailDemand: { _ in }, onSelectionChanged: { _, _ in },
                               onSelectionScreenBoundsChanged: { _ in },
                               onStroke: { _, _ in }, onMoveSelection: { _, _ in },
                               onResizeSelection: { _, _, _ in }, onDelete: { _ in },
                               onMoveBoard: { _, _ in }, onUndo: {}, onRedo: {},
                               onPencilAction: { _, _ in }, onPencilPaletteMoved: { _ in },
                               onPencilPaletteDismiss: {})
    }

    func testStandaloneCanvasRetainsExactlyOnePencilInteractionAcrossUpdates() throws {
        let document = try SVGDocument.parse("<svg viewBox='0 0 100 100'/>")
        let editor = try JSONDecoder().decode(EditorState.self, from: Data("""
        {"schema_version":4,"revision":0,"viewport":{"x":0,"y":0,"width":100,"height":100},"objects":[],"groups":[],"imported_transforms":{},"source_boards":[],"merged_board_ids":[]}
        """.utf8))
        let canvas = InfiniteCanvasUIView(
            boardID: "one", document: document, camera: editor.viewport,
            composition: SceneComposition.build(boardID: "one", document: document,
                                                editor: editor)
        )
        XCTAssertEqual(canvas.pencilInteractionCountForTesting, 1)
        canvas.update(boardID: "two", document: document, camera: editor.viewport,
                      objects: [], importedTransforms: [:],
                      composition: SceneComposition.build(boardID: "two", document: document,
                                                          editor: editor),
                      pencilPreferences: PencilPreferences(doubleTap: .eraser,
                                                           squeeze: .toolPalette,
                                                           hover: .on))
        XCTAssertEqual(canvas.pencilInteractionCountForTesting, 1)
    }

    func testClassCanvasRetainsExactlyOnePencilInteractionAcrossUpdates() {
        let workspace = LectureWorkspace(
            schemaVersion: 1, revision: 0,
            camera: CameraRect(x: -100, y: -100, width: 1_000, height: 800),
            items: [], activeBoardID: nil, lastViewedAt: nil
        )
        let view = LectureCanvasUIView(
            workspace: workspace, scenes: [:], selectedKeys: [], tool: .pen,
            backgroundStyle: .dots, physicalBoardShowsPaper: false,
            penStyle: .pen, markerStyle: .marker,
            pencilPreferences: .defaults, isPencilPalettePresented: false,
            showsDeveloperDiagnostics: false,
            thumbnailURLs: [:], loadAsset: { _ in Data() },
            callbacks: lectureCallbacks()
        )
        XCTAssertEqual(view.pencilInteractionCountForTesting, 1)
        view.update(workspace: workspace, scenes: [:], selectedKeys: [],
                    tool: .highlighter, backgroundStyle: .blank,
                    physicalBoardShowsPaper: false, penStyle: .pen,
                    markerStyle: .marker,
                    pencilPreferences: PencilPreferences(doubleTap: .previousTool,
                                                         squeeze: .inkAttributes,
                                                         hover: .off),
                    isPencilPalettePresented: false,
                    showsDeveloperDiagnostics: false, thumbnailURLs: [:],
                    loadAsset: { _ in Data() }, focusRequest: nil,
                    callbacks: lectureCallbacks())
        XCTAssertEqual(view.pencilInteractionCountForTesting, 1)
    }

    func testFeedbackProviderCanBeReplacedByRecordingMock() {
        final class Mock: PencilFeedbackProviding {
            var requests: [PencilFeedbackRequest] = []
            func request(_ feedback: PencilFeedbackRequest) { requests.append(feedback) }
        }
        let mock = Mock()
        mock.request(.paletteActivation(CGPoint(x: 10, y: 20)))
        mock.request(.toolSelection(nil))
        XCTAssertEqual(mock.requests, [.paletteActivation(CGPoint(x: 10, y: 20)),
                                       .toolSelection(nil)])
    }

    func testLateStrokeCorrectionUpdatesInPlaceAndKeepsOneUndoAction() {
        let editor = EditorState(
            schemaVersion: 4, revision: 0, updatedAt: nil,
            viewport: CameraRect(x: 0, y: 0, width: 100, height: 100),
            objects: [], groups: [], importedTransforms: [:],
            sourceBoards: [], mergedBoardIDs: []
        )
        let store = BoardDocumentStore(boardID: "pencil-correction", editor: editor)
        let api = APIClient(baseURL: URL(string: "https://pencil-correction.test")!)
        let original = UserStroke(id: "stroke", points: [
            StrokePoint(x: 1, y: 2, pressure: 0.2, timestamp: 1,
                        estimationUpdateIndex: 9)
        ], pencilTool: .pen)
        let corrected = UserStroke(id: "stroke", points: [
            StrokePoint(x: 1.1, y: 2.1, pressure: 0.9, roll: 1.2,
                        timestamp: 1.1, estimationUpdateIndex: 9)
        ], pencilTool: .pen)

        store.applyStroke(original, api: api)
        store.applyStroke(corrected, api: api)
        XCTAssertEqual(store.editor.objects.count, 1)
        XCTAssertEqual(store.editor.objects[0].points?[0].pressure, 0.9)
        XCTAssertEqual(store.editor.objects[0].points?[0].roll, 1.2)
        store.undo(api: api)
        XCTAssertTrue(store.editor.objects.isEmpty)
    }

    #if DEBUG
    func testHardwareHarnessStartsWithEveryRequiredCategoryNotTested() {
        let store = PencilHardwareValidationStore.shared
        store.reset()
        XCTAssertEqual(Set(PencilHardwareFeature.allCases.map(\.rawValue)), Set([
            "DRAW", "PRESSURE", "TILT", "HOVER", "DOUBLE TAP", "SQUEEZE",
            "BARREL ROLL", "HAPTICS", "PALM", "FINGER COEXISTENCE"
        ]))
        XCTAssertTrue(PencilHardwareFeature.allCases.allSatisfy {
            store.status(for: $0) == .notTested
        })
    }
    #endif
}
