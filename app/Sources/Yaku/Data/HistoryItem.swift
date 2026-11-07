import Foundation
import SwiftData

/// One translated request (SPEC 11). The manager's history list is M2; M1 only
/// writes rows so the data is there.
@Model
final class HistoryItem {
    var date: Date
    /// panel / hud / manager / overlay / pdf
    var origin: String
    var source: String
    var target: String
    var sourceLanguage: String
    var targetLanguage: String
    var form: String
    var frontApp: String
    var model: String
    var seconds: Double

    init(
        date: Date,
        origin: String,
        source: String,
        target: String,
        sourceLanguage: String,
        targetLanguage: String,
        form: String,
        frontApp: String,
        model: String,
        seconds: Double
    ) {
        self.date = date
        self.origin = origin
        self.source = source
        self.target = target
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.form = form
        self.frontApp = frontApp
        self.model = model
        self.seconds = seconds
    }
}
