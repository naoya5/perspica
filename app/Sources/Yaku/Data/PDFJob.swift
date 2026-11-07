import Foundation
import SwiftData

/// One PDF translation (SPEC 11).
///
/// The input is kept as a security-scoped bookmark so the job can be retried
/// after a relaunch. `progress` and `stage` are the live values the panel, the
/// menu bar icon and the island read; they are written with the rest of the row
/// but are only meaningful while the state is `running`.
@Model
final class PDFJob {
    @Attribute(.unique) var id: UUID
    var inputBookmark: Data
    var fileName: String
    var outputMonoPath: String
    var outputDualPath: String
    /// queued / running / done / failed / cancelled
    var state: String
    var pageCount: Int
    var seconds: Double
    var date: Date
    var errorMessage: String
    var progress: Double
    var stage: String

    init(
        id: UUID = UUID(),
        inputBookmark: Data,
        fileName: String,
        outputMonoPath: String = "",
        outputDualPath: String = "",
        state: PDFJobState = .queued,
        pageCount: Int = 0,
        seconds: Double = 0,
        date: Date = Date(),
        errorMessage: String = "",
        progress: Double = 0,
        stage: String = ""
    ) {
        self.id = id
        self.inputBookmark = inputBookmark
        self.fileName = fileName
        self.outputMonoPath = outputMonoPath
        self.outputDualPath = outputDualPath
        self.state = state.rawValue
        self.pageCount = pageCount
        self.seconds = seconds
        self.date = date
        self.errorMessage = errorMessage
        self.progress = progress
        self.stage = stage
    }

    var jobState: PDFJobState {
        get { PDFJobState(rawValue: state) ?? .queued }
        set { state = newValue.rawValue }
    }
}

/// The five states a job can be in (SPEC 4.4, 11).
public enum PDFJobState: String, Sendable, CaseIterable {
    case queued
    case running
    case done
    case failed
    case cancelled

    public var isFinished: Bool {
        self == .done || self == .failed || self == .cancelled
    }

    public var japaneseName: String {
        switch self {
        case .queued: "順番待ち"
        case .running: "処理中"
        case .done: "完了"
        case .failed: "失敗"
        case .cancelled: "取り消し"
        }
    }
}
