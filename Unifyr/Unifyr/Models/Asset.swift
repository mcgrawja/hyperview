//
//  Asset.swift
//  Unifyr
//
//  §4.2 — v1 active entity. Images/files pasted or dropped into notes. Binary
//  lives in CloudKit-external storage so records stay small; the owning note is
//  referenced by UUID (assets can outlive an open editor session).
//

import Foundation
import SwiftData

@Model
final class Asset {
    var id: UUID = UUID()
    var noteID: UUID? = nil
    var filename: String = ""
    var mimeType: String = ""

    @Attribute(.externalStorage)
    var data: Data = Data()

    init(
        noteID: UUID? = nil,
        filename: String = "",
        mimeType: String = "",
        data: Data = Data()
    ) {
        self.id = UUID()
        self.noteID = noteID
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}
