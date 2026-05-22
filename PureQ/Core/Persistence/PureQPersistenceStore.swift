//
//  PureQPersistenceStore.swift
//  PureQ
//

import Foundation

enum PureQPersistenceStore {
    static let appSupportDirectoryURL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("PureQ", isDirectory: true)
    static let sessionSnapshotURL = appSupportDirectoryURL.appendingPathComponent("LastSession.pureqsession.json")

    static func writeSessionSnapshot(_ snapshot: PureQSessionSnapshot) throws {
        try FileManager.default.createDirectory(
            at: appSupportDirectoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: sessionSnapshotURL, options: .atomic)
    }
}

