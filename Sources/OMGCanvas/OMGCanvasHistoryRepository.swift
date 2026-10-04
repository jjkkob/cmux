import Foundation

/// Reads one operator-selected metadata file without touching session or transcript stores.
actor OMGCanvasHistoryRepository {
    func read(_ url: URL) throws -> OMGCanvasHistoryManifest {
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resource.isRegularFile == true, let count = resource.fileSize,
              count <= OMGCanvasHistoryManifest.maximumBytes else { throw OMGCanvasHistoryManifest.Failure.invalid }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: OMGCanvasHistoryManifest.maximumBytes + 1) ?? Data()
        return try OMGCanvasHistoryManifest.decode(data)
    }
}
