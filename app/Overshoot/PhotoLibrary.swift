import Photos
import UIKit

/// The "Overshoot" album in Photos. Every photo the app saves goes there, and the gallery shows
/// that album only.
enum PhotoLibrary {
    private static let albumTitle = "Overshoot"
    private static let albumKey = "albumIdentifier"

    static var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static func authorize() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    private static func album() -> PHAssetCollection? {
        if let identifier = UserDefaults.standard.string(forKey: albumKey),
           let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject {
            return album
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumTitle)
        let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
        if let album { UserDefaults.standard.set(album.localIdentifier, forKey: albumKey) }
        return album
    }

    /// Saves the photos into the album, creating the album on first use. Blocks; call off the
    /// main thread after `authorize`.
    static func save(_ photos: [Data], date: Date) throws {
        let existing = album()
        var createdAlbum: PHObjectPlaceholder?
        try PHPhotoLibrary.shared().performChangesAndWait {
            let albumRequest: PHAssetCollectionChangeRequest?
            if let existing {
                albumRequest = PHAssetCollectionChangeRequest(for: existing)
            } else {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                createdAlbum = request.placeholderForCreatedAssetCollection
                albumRequest = request
            }
            var created: [PHObjectPlaceholder] = []
            for photo in photos {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: photo, options: nil)
                request.creationDate = date
                if let placeholder = request.placeholderForCreatedAsset { created.append(placeholder) }
            }
            albumRequest?.addAssets(created as NSArray)
        }
        if let createdAlbum { UserDefaults.standard.set(createdAlbum.localIdentifier, forKey: albumKey) }
    }

    /// The album's photos, newest saved first.
    static func assets() -> [PHAsset] {
        guard let album = album() else { return [] }
        let result = PHAsset.fetchAssets(in: album, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets.reversed()
    }

    static func delete(_ asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }

    static func image(for asset: PHAsset, size: CGSize, mode: PHImageContentMode) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: mode, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// The original JPEG bytes, for sharing and for reading the camera model from EXIF.
    static func data(for asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .original
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
