import AppKit
import Foundation
import Observation
import SwiftUI
import YakuCore

/// What the island is showing (SPEC 4.5).
enum NotchState: Equatable {
    case closed
    case drop
    case activity
    case done
    case error
}

/// The island's state: drop target and PDF progress only, no text translation
/// (SPEC 4.5: 文の翻訳はパネルに任せる).
@MainActor
@Observable
final class NotchModel {
    var state: NotchState = .closed
    /// Set when the island is clicked open (file name, stage, bar, buttons).
    var expanded = false
    var dropHover = false
    var dropMessage = "PDF をドロップして日本語に"
    /// Drives the one-off shake for a non-PDF drop.
    var dropShake: CGFloat = 0

    var fileName = ""
    var progress: Double = 0
    var stage = ""
    var elapsed: Double = 0
    var monoPath = ""
    var dualPath = ""
    var errorMessage = ""

    /// The physical notch this island is drawn over.
    var notchSize = CGSize(width: 180, height: 32)
    /// Radius of the top ears (see `NotchShape`). A small, fixed ear reads as a
    /// black bump where the island meets the screen edge as soon as the island
    /// is taller than the notch, so it grows with the island (SPEC 4.5:
    /// 上の耳が小さな黒い突起に見える問題).
    var earRadius: CGFloat {
        state == .closed ? 6 : min(14, max(6, islandSize.height / 12))
    }
    /// Set by the demo options so the hover timer does not close a forced state.
    var demoHold = false

    private var startedAt: Date?

    // MARK: geometry

    var viewMode: NotchState { state }

    var islandSize: CGSize {
        switch state {
        case .closed:
            notchSize
        case .drop:
            CGSize(width: 440, height: 156)
        case .activity, .done, .error:
            expanded
                ? CGSize(width: 560, height: expandedHeight)
                : CGSize(width: notchSize.width + 120, height: notchSize.height)
        }
    }

    var cornerRadius: CGFloat {
        switch state {
        case .drop: 28
        case .activity, .done, .error: expanded ? 28 : 10
        case .closed: 10
        }
    }

    private var expandedHeight: CGFloat {
        switch state {
        case .done: 208
        case .error: 176
        default: 196
        }
    }

    // MARK: text

    var stageJapanese: String { PDFStage.japaneseName(for: stage) }

    var progressText: String { "\(Int((progress * 100).rounded()))%" }

    var elapsedText: String {
        let total = max(0, Int(elapsed.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: transitions

    func beginJob(fileName: String) {
        self.fileName = fileName
        progress = 0
        stage = ""
        errorMessage = ""
        monoPath = ""
        dualPath = ""
        elapsed = 0
        startedAt = Date()
        expanded = false
        state = .activity
    }

    func update(progress: Double, stage: String) {
        guard state == .activity else { return }
        self.progress = min(max(progress, 0), 1)
        self.stage = stage
    }

    func finish(monoPath: String, dualPath: String) {
        self.monoPath = monoPath
        self.dualPath = dualPath
        progress = 1
        state = .done
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
    }

    func fail(message: String) {
        errorMessage = message
        state = .error
    }

    func close() {
        state = .closed
        expanded = false
        startedAt = nil
    }

    func toggleExpanded() {
        guard state != .closed, state != .drop else { return }
        expanded.toggle()
    }

    func dragNear(isOverIsland: Bool) {
        guard state == .closed || state == .drop else { return }
        if state != .drop {
            state = .drop
            expanded = false
            dropMessage = "PDF をドロップして日本語に"
        }
        dropHover = isOverIsland
    }

    func dragLeftZone() {
        guard state == .drop else { return }
        state = .closed
        dropHover = false
        dropMessage = "PDF をドロップして日本語に"
    }

    func rejectDrop() {
        dropMessage = "PDF だけ対応しています"
        dropHover = false
        withAnimation(.easeInOut(duration: 0.30)) { dropShake = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.dropShake = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.state == .drop else { return }
            self.dropMessage = "PDF をドロップして日本語に"
            self.state = .closed
        }
    }

    // MARK: demo

    func setDemoActivity(fileName: String = "attention.pdf", progress: Double = 0.42, stage: String = "Translate Paragraphs") {
        demoHold = true
        self.fileName = fileName
        self.progress = progress
        self.stage = stage
        elapsed = 6
        startedAt = Date().addingTimeInterval(-6)
        state = .activity
        expanded = false
    }

    func setDemoDrop() {
        demoHold = true
        dragNear(isOverIsland: false)
    }

    func setDemoDone() {
        demoHold = true
        fileName = "attention.pdf"
        monoPath = ""
        dualPath = ""
        progress = 1
        elapsed = 96
        state = .done
        expanded = false
    }

    func setDemoError() {
        demoHold = true
        fileName = "attention.pdf"
        errorMessage = "PDF を訳せませんでした"
        state = .error
        expanded = false
    }
}
