import Foundation

/// Serializes writes away from the UI actor; only the provider's stdin is writable here.
actor OMGCanvasChatInputWriter {
    private let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func close() { try? handle.close() }
}
