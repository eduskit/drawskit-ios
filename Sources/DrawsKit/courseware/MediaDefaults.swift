import Foundation

enum MediaDefaults {
    static let kindVideo = "video"
    static let kindAudio = "audio"
    static let sourceTypeVideo = "video"
    static let shapeTypeAudio = "audio"
    static let keyPrefixSlot = "slot"
    static let keyPrefixFile = "file"
    static let keyPrefixElement = "element"
    static let keySeparator = ":"
    static let defaultAudioWidth = 240.0
    static let defaultAudioHeight = 48.0
    static let defaultPageWidth = 1280.0
    static let defaultPageHeight = 720.0
    static let defaultAudioVolume = 100
    static let syncIntervalMs: TimeInterval = 0.5
    static let syncMessageType = "drawskit_media_status"
    static let syncActionPlay = "play"
    static let syncActionPause = "pause"
    static let syncActionSeek = "seek"
    static let syncActionState = "state"

    static func slotKey(fileId: String, mediaId: String) -> String {
        [keyPrefixSlot, fileId, mediaId].joined(separator: keySeparator)
    }

    static func fileKey(_ fileId: String) -> String {
        [keyPrefixFile, fileId].joined(separator: keySeparator)
    }

    static func elementKey(_ elementId: String) -> String {
        [keyPrefixElement, elementId].joined(separator: keySeparator)
    }
}
