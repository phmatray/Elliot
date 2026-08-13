//
//  Logger+ACP.swift
//  ACP
//
//  Logging utility for ACP
//

import Foundation
import os.log

extension Logger {
    /// Repointed from upstream's `com.acp` when vendored: a second subsystem is a second place to
    /// look when a run goes quiet, and `log show` is already hard enough to get output from here.
    private static let acpSubsystem = "dev.phmatray.elliot"

    /// Create a logger for a specific category
    public static func forCategory(_ category: String) -> Logger {
        Logger(subsystem: acpSubsystem, category: category)
    }

    /// Convenience logger for ACP
    public static let acp = Logger.forCategory("ACP")
}
