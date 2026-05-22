//
//  PureQErrors.swift
//  PureQ
//

import Foundation

enum DriverInstallError: LocalizedError {
    case privilegedCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .privilegedCommandFailed(let message):
            return message
        }
    }
}

enum AudioEngineStartError: LocalizedError {
    case virtualOutputSwitchFailed(String)

    var errorDescription: String? {
        switch self {
        case .virtualOutputSwitchFailed(let outputName):
            return "Could not switch macOS output to \(outputName)."
        }
    }
}
