import Foundation
import os

/// Shared logger for every checkpoint on the export path: menu → sheet
/// → coordinator → terminal phase. Filed under one category so Console.app
/// (or `log stream --predicate 'subsystem == "com.dimroom.app" && category == "export"'`)
/// shows the whole flow on one line set. Added for #242 so the next
/// silent-export regression is visible without code spelunking.
enum ExportLog {
    static let logger = Logger(subsystem: "com.dimroom.app", category: "export")
}
