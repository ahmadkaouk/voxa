#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
import CoreGraphics
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

enum IslandPresentationChecks {
    static func activeDictationOwnsTheIsland() throws {
        // Delayed review publications must never interrupt the next recording.
        for visible in [false, true] {
            for awaiting in [false, true] {
                for analyzing in [false, true] {
                    try unitEqual(IslandPresentation.resolve(activity: .listening, feedbackVisible: visible,
                        awaitingFeedback: awaiting, isAnalyzing: analyzing), .recording)
                    try unitEqual(IslandPresentation.resolve(activity: .transcribing, feedbackVisible: visible,
                        awaitingFeedback: awaiting, isAnalyzing: analyzing), .processing)
                }
            }
        }
    }

    static func feedbackSurvivesCompletionAndItsTimer() throws {
        try unitEqual(IslandPresentation.resolve(activity: .outputting, feedbackVisible: false,
            awaitingFeedback: true, isAnalyzing: true), .completion)
        // A fast review replaces the checkmark. Clearing activity 900 ms later
        // must preserve that same review instead of ordering out its shared panel.
        try unitEqual(IslandPresentation.resolve(activity: .outputting, feedbackVisible: true,
            awaitingFeedback: true, isAnalyzing: false), .feedback)
        try unitEqual(IslandPresentation.resolve(activity: .idle, feedbackVisible: true,
            awaitingFeedback: false, isAnalyzing: false), .feedback)
        try unitEqual(IslandPresentation.resolve(activity: .idle, feedbackVisible: false,
            awaitingFeedback: false, isAnalyzing: false), .hidden)
    }

    static func slowFeedbackBridgesOnlyTheCurrentDelivery() throws {
        try unitEqual(IslandPresentation.resolve(activity: .idle, feedbackVisible: false,
            awaitingFeedback: true, isAnalyzing: true), .reviewing)
        try unitEqual(IslandPresentation.resolve(activity: .idle, feedbackVisible: true,
            awaitingFeedback: true, isAnalyzing: false), .feedback)
        // Finished analysis with no review, or analysis left from a cancelled
        // delivery, must not leave a permanent processing indicator behind.
        for (awaiting, analyzing) in [(false, true), (true, false), (false, false)] {
            try unitEqual(IslandPresentation.resolve(activity: .idle, feedbackVisible: false,
                awaitingFeedback: awaiting, isAnalyzing: analyzing), .hidden)
        }
    }

    static func expansionKeepsTheSameTopAndCenter() throws {
        let screen = CGRect(x: 0, y: 32, width: 1512, height: 918)
        let compact = IslandPresentation.frame(size: CGSize(width: 320, height: 64), visibleFrame: screen)
        let expanded = IslandPresentation.frame(size: CGSize(width: 680, height: 600), visibleFrame: screen,
            centerX: compact.midX, topY: compact.maxY)
        try unitEqual(compact.midX, screen.midX)
        try unitEqual(compact.maxY, screen.maxY - 8)
        try unitEqual(expanded.midX, compact.midX)
        try unitEqual(expanded.maxY, compact.maxY)
        try unitEqual(expanded.size, CGSize(width: 680, height: 600))
        let collapsed = IslandPresentation.frame(size: compact.size, visibleFrame: screen,
            centerX: expanded.midX, topY: expanded.maxY)
        try unitEqual(collapsed, compact)
    }

    static func placementFitsSmallAndOffsetScreens() throws {
        // Secondary displays can have negative origins. Clamp the requested
        // anchor without drifting onto the primary display.
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let positioned = IslandPresentation.frame(size: CGSize(width: 640, height: 500), visibleFrame: screen,
            centerX: 900, topY: 2000)
        try unitEqual(positioned.maxX, screen.maxX - 8)
        try unitEqual(positioned.maxY, screen.maxY - 8)
        try unitExpect(screen.contains(positioned))

        let oversized = IslandPresentation.frame(size: CGSize(width: 1800, height: 1200), visibleFrame: screen)
        try unitEqual(oversized, screen.insetBy(dx: 8, dy: 8))
        let lowAnchor = IslandPresentation.frame(size: CGSize(width: 640, height: 500), visibleFrame: screen,
            centerX: -3000, topY: -3000)
        try unitEqual(lowAnchor.minX, screen.minX + 8)
        try unitEqual(lowAnchor.minY, screen.minY + 8)

        // The inset is configurable for a shell that meets the menu-bar edge.
        let flush = IslandPresentation.frame(size: CGSize(width: 320, height: 64), visibleFrame: screen, inset: 0)
        try unitEqual(flush.maxY, screen.maxY)
    }

    static func sideDockDoesNotMoveTheIslandCenter() throws {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let leftDock = CGRect(x: -1360, y: 0, width: 1360, height: 878)
        let rightDock = CGRect(x: -1440, y: 0, width: 1360, height: 878)
        let sizes = [CGSize(width: 232, height: 42), CGSize(width: 296, height: 60),
                     CGSize(width: 480, height: 620), CGSize(width: 300, height: 50)]
        for visible in [leftDock, rightDock] {
            for size in sizes {
                let island = IslandPresentation.centeredFrame(size: size, screenFrame: screen, visibleFrame: visible)
                try unitEqual(island.midX, screen.midX)
                try unitEqual(island.maxY, visible.maxY - 8)
                try unitExpect(visible.contains(island))
            }
        }
    }

    static func defaultActivityKeepsItsBottomAcrossStates() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 70, width: 1512, height: 888)
        let states: [(IslandPresentation, CGSize)] = [
            (.recording, CGSize(width: 232, height: 42)),
            (.recording, CGSize(width: 296, height: 60)),
            (.processing, CGSize(width: 240, height: 46)),
            (.completion, CGSize(width: 240, height: 46)),
            (.reviewing, CGSize(width: 252, height: 46))
        ]
        for (state, size) in states {
            let placed = IslandPresentation.defaultFrame(for: state, size: size,
                screenFrame: screen, visibleFrame: visible)
            try unitEqual(placed.size, size)
            try unitEqual(placed.midX, screen.midX)
            try unitEqual(placed.minY, visible.minY + 20)
            try unitExpect(visible.contains(placed))
        }
        try unitEqual(IslandPresentation.defaultFrame(for: .hidden, size: states[0].1,
            screenFrame: screen, visibleFrame: visible), .zero)
    }

    static func defaultFeedbackKeepsItsBottomAcrossReviewSizes() throws {
        let screen = CGRect(x: -1512, y: -200, width: 1512, height: 982)
        let visible = CGRect(x: -1512, y: -130, width: 1512, height: 888)
        let sizes = [CGSize(width: 300, height: 50), CGSize(width: 400, height: 230), CGSize(width: 400, height: 420),
                     CGSize(width: 480, height: 380), CGSize(width: 480, height: 700)]
        for size in sizes {
            let placed = IslandPresentation.defaultFrame(for: .feedback, size: size,
                screenFrame: screen, visibleFrame: visible)
            try unitEqual(placed.size, size)
            try unitEqual(placed.midX, screen.midX)
            try unitEqual(placed.minY, visible.minY + 20)
            try unitExpect(visible.contains(placed))
            // Review publications and intervening activity sizes must not
            // accumulate offsets or reuse a prior frame's dimensions.
            _ = IslandPresentation.defaultFrame(for: .recording, size: CGSize(width: 296, height: 60),
                screenFrame: screen, visibleFrame: visible)
            try unitEqual(IslandPresentation.defaultFrame(for: .feedback, size: size,
                screenFrame: screen, visibleFrame: visible), placed)
        }
    }

    static func defaultPlacementFitsSideDocksAndSmallScreens() throws {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let leftDock = CGRect(x: -1360, y: -200, width: 1360, height: 878)
        let rightDock = CGRect(x: -1440, y: -200, width: 1360, height: 878)
        let states: [(IslandPresentation, CGSize)] = [
            (.recording, CGSize(width: 232, height: 42)),
            (.recording, CGSize(width: 296, height: 60)),
            (.processing, CGSize(width: 240, height: 46)),
            (.completion, CGSize(width: 240, height: 46)),
            (.reviewing, CGSize(width: 252, height: 46)),
            (.feedback, CGSize(width: 400, height: 230)),
            (.feedback, CGSize(width: 480, height: 620))
        ]
        for visible in [leftDock, rightDock] {
            for (state, size) in states {
                let placed = IslandPresentation.defaultFrame(for: state, size: size,
                    screenFrame: screen, visibleFrame: visible)
                try unitEqual(placed.midX, screen.midX)
                try unitEqual(placed.minY, visible.minY + 20)
                try unitExpect(visible.contains(placed))
            }
        }

        let smallScreen = CGRect(x: -600, y: -400, width: 600, height: 400)
        let smallVisible = CGRect(x: -600, y: -350, width: 600, height: 326)
        for state: IslandPresentation in [.recording, .processing, .completion, .reviewing, .feedback] {
            let oversized = IslandPresentation.defaultFrame(for: state, size: CGSize(width: 900, height: 700),
                screenFrame: smallScreen, visibleFrame: smallVisible)
            try unitEqual(oversized, smallVisible.insetBy(dx: 8, dy: 8))
        }
    }

    static func draggedAnchorSurvivesResizingAndClampsToScreen() throws {
        let visible = CGRect(x: -1440, y: -160, width: 1440, height: 836)
        let centerX: CGFloat = -640
        let bottomY: CGFloat = -90
        for size in [CGSize(width: 208, height: 34), CGSize(width: 260, height: 38),
                     CGSize(width: 480, height: 500)] {
            let placed = IslandPresentation.bottomAnchoredFrame(size: size,
                visibleFrame: visible, centerX: centerX, bottomY: bottomY)
            try unitEqual(placed.midX, centerX)
            try unitEqual(placed.minY, bottomY)
            try unitExpect(visible.contains(placed))
        }
        let movedOutside = IslandPresentation.bottomAnchoredFrame(size: CGSize(width: 480, height: 500),
            visibleFrame: visible, centerX: 3000, bottomY: 3000)
        try unitEqual(movedOutside.maxX, visible.maxX - 8)
        try unitEqual(movedOutside.maxY, visible.maxY - 8)
        let oversized = IslandPresentation.bottomAnchoredFrame(size: CGSize(width: 1800, height: 1200),
            visibleFrame: visible, centerX: centerX, bottomY: bottomY)
        try unitEqual(oversized, visible.insetBy(dx: 8, dy: 8))
    }

    static let all: [(String, () throws -> Void)] = [
        ("dynamic island: active dictation owns the shared presentation", activeDictationOwnsTheIsland),
        ("dynamic island: feedback survives completion and its timer", feedbackSurvivesCompletionAndItsTimer),
        ("dynamic island: slow feedback bridges only the current delivery", slowFeedbackBridgesOnlyTheCurrentDelivery),
        ("dynamic island: expansion preserves the top edge and center", expansionKeepsTheSameTopAndCenter),
        ("dynamic island: fitting and anchors respect the selected screen", placementFitsSmallAndOffsetScreens),
        ("dynamic island: side Dock keeps every state at the screen center", sideDockDoesNotMoveTheIslandCenter),
        ("default placement: activity keeps its bottom edge through recording and delivery", defaultActivityKeepsItsBottomAcrossStates),
        ("default placement: compact and detailed feedback keep the bottom edge", defaultFeedbackKeepsItsBottomAcrossReviewSizes),
        ("default placement: side Docks and small displays keep content reachable", defaultPlacementFitsSideDocksAndSmallScreens),
        ("dragged placement: size changes preserve the anchor and keep content reachable", draggedAnchorSurvivesResizingAndClampsToScreen)
    ]
}

#if !VOXA_STANDALONE_TESTS
final class IslandPresentationTests: XCTestCase {
    func testActiveDictationOwnsTheIsland() throws { try IslandPresentationChecks.activeDictationOwnsTheIsland() }
    func testFeedbackSurvivesCompletion() throws { try IslandPresentationChecks.feedbackSurvivesCompletionAndItsTimer() }
    func testSlowFeedbackBridge() throws { try IslandPresentationChecks.slowFeedbackBridgesOnlyTheCurrentDelivery() }
    func testExpansionKeepsAnchor() throws { try IslandPresentationChecks.expansionKeepsTheSameTopAndCenter() }
    func testPlacementFitsScreen() throws { try IslandPresentationChecks.placementFitsSmallAndOffsetScreens() }
    func testSideDockKeepsScreenCenter() throws { try IslandPresentationChecks.sideDockDoesNotMoveTheIslandCenter() }
    func testDefaultActivityBottom() throws { try IslandPresentationChecks.defaultActivityKeepsItsBottomAcrossStates() }
    func testDefaultFeedbackBottom() throws { try IslandPresentationChecks.defaultFeedbackKeepsItsBottomAcrossReviewSizes() }
    func testDefaultPlacementFitsScreens() throws { try IslandPresentationChecks.defaultPlacementFitsSideDocksAndSmallScreens() }
    func testDraggedAnchorFitsScreen() throws { try IslandPresentationChecks.draggedAnchorSurvivesResizingAndClampsToScreen() }
}
#endif
#endif
