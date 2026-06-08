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
    case virtualOutputSwitchPending(String)
    case virtualOutputFormatMismatch(String)

    var errorDescription: String? {
        switch self {
        case .virtualOutputSwitchFailed(let outputName):
            return "Could not switch macOS output to \(outputName)."
        case .virtualOutputSwitchPending(let outputName):
            return "Switching macOS output to \(outputName). Audio will start when CoreAudio confirms the change."
        case .virtualOutputFormatMismatch(let message):
            return message
        }
    }
}
