import Foundation
import UIKit

/// On-disk storage for chat image attachments. Images are downscaled and JPEG
/// compressed before they touch the disk, and never leave the device except in
/// the request body sent to the model the user configured.
enum AttachmentStore {
    static let maxDimension: CGFloat = 1568
    static let jpegQuality: CGFloat = 0.82
    static let maxAttachmentsPerMessage = 4

    private static var directoryURL: URL {
        let url = FileStore.directoryURL.appendingPathComponent("Attachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private static func url(for attachment: MessageAttachment) -> URL {
        directoryURL.appendingPathComponent(attachment.fileName)
    }

    // MARK: Saving

    static func save(_ image: UIImage) -> MessageAttachment? {
        let resized = image.downscaled(maxDimension: maxDimension)
        guard let data = resized.jpegData(compressionQuality: jpegQuality) else { return nil }
        let id = UUID()
        let fileName = "\(id.uuidString).jpg"
        let destination = directoryURL.appendingPathComponent(fileName)
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            return nil
        }
        return MessageAttachment(
            id: id,
            fileName: fileName,
            pixelWidth: Int(resized.size.width * resized.scale),
            pixelHeight: Int(resized.size.height * resized.scale),
            byteCount: data.count
        )
    }

    // MARK: Loading

    static func data(for attachment: MessageAttachment) -> Data? {
        try? Data(contentsOf: url(for: attachment))
    }

    static func image(for attachment: MessageAttachment) -> UIImage? {
        guard let data = data(for: attachment) else { return nil }
        return UIImage(data: data)
    }

    /// Cached `data:image/jpeg;base64,…` payload for the chat wire format.
    private static var dataURLCache: [UUID: String] = [:]

    static func dataURL(for attachment: MessageAttachment) -> String? {
        if let cached = dataURLCache[attachment.id] { return cached }
        guard let data = data(for: attachment) else { return nil }
        let url = "data:image/jpeg;base64,\(data.base64EncodedString())"
        dataURLCache[attachment.id] = url
        return url
    }

    // MARK: Deleting

    static func delete(_ attachment: MessageAttachment) {
        try? FileManager.default.removeItem(at: url(for: attachment))
        dataURLCache.removeValue(forKey: attachment.id)
    }

    static func delete(_ attachments: [MessageAttachment]) {
        for attachment in attachments { delete(attachment) }
    }

    static func deleteAll() {
        let url = directoryURL
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
        for item in contents { try? FileManager.default.removeItem(at: item) }
        dataURLCache.removeAll()
    }

    /// Removes files that no message references any more.
    static func prune(referencedFileNames: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { return }
        for item in contents where !referencedFileNames.contains(item.lastPathComponent) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    static var totalBytes: Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return contents.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
    }
}

extension UIImage {
    /// Scales the image down so its longest edge is at most `maxDimension`,
    /// preserving orientation.
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
