import ImageIO
import Photos
import SwiftUI

/// The Overshoot album: a thumbnail grid, and a full-screen viewer with swipe, share and delete.
struct GalleryScreen: View {
    @Environment(CameraModel.self) private var model
    let close: () -> Void
    @State private var assets: [PHAsset] = []
    @State private var access: Access = .loading
    @State private var viewing: Int?

    private enum Access { case loading, granted, denied }

    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width > geometry.size.height ? 6 : 4
            VStack(spacing: 0) {
                titleBar
                    .frame(height: 48)
                content(columns: columns, width: geometry.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                HStack {
                    Button("Back", action: close).buttonStyle(SoftKeyStyle())
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 52)
                .background(BarBackground())
            }
        }
        .background(BarBackground().ignoresSafeArea())
        .foregroundStyle(.white)
        .statusBarHidden()
        .task { await load() }
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            PhotoViewer(assets: $assets, index: viewing ?? 0) { viewing = nil }
        }
        .onChange(of: viewing) { _, index in
            if index == nil { Task { await model.loadLastThumbnail() } }
        }
    }

    private var titleBar: some View {
        HStack {
            Image(systemName: "photo.on.rectangle").foregroundStyle(Theme.orange)
            Text("Overshoot album")
            Spacer()
            if access == .granted { Text("\(assets.count)").foregroundStyle(Theme.silver).monospacedDigit() }
        }
        .font(Theme.font(17))
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(BarBackground())
    }

    @ViewBuilder private func content(columns: Int, width: CGFloat) -> some View {
        switch access {
        case .loading:
            ProgressView().tint(Theme.orange)
        case .denied:
            VStack(spacing: 16) {
                Text("Allow Photos access to see your photos here.")
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(SoftKeyStyle())
            }
            .font(Theme.font(16))
            .padding(24)
        case .granted where assets.isEmpty:
            Text("No photos yet. Take one with the orange key.")
                .font(Theme.font(16))
                .foregroundStyle(Theme.silver)
                .multilineTextAlignment(.center)
                .padding(24)
        case .granted:
            let side = (width - CGFloat(columns - 1) * 2) / CGFloat(columns)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 2), count: columns), spacing: 2) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        Button { viewing = index } label: { Thumbnail(asset: asset, side: side) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(asset.creationDate.map { DateStamp.text(date: $0, includeTime: true) } ?? "Photo")
                    }
                }
            }
        }
    }

    private func load() async {
        guard await PhotoLibrary.authorize() else {
            access = .denied
            return
        }
        assets = PhotoLibrary.assets()
        access = .granted
    }
}

private struct Thumbnail: View {
    let asset: PHAsset
    let side: CGFloat
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: asset.localIdentifier) {
            let pixels = side * displayScale
            image = await PhotoLibrary.image(for: asset, size: CGSize(width: pixels, height: pixels), mode: .aspectFill)
        }
    }
}

/// Swipes through the album. The top bar shows the date and the camera from the photo's EXIF.
private struct PhotoViewer: View {
    @Binding var assets: [PHAsset]
    @State var index: Int
    let close: () -> Void
    @State private var shareURL: URL?
    @State private var cameraName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(dateText)
                Spacer()
                Text(cameraName).foregroundStyle(Theme.silver)
            }
            .font(Theme.font(15))
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(BarBackground())
            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { offset, asset in
                    FullImage(asset: asset).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(.black)
            HStack {
                Button("Back", action: close).buttonStyle(SoftKeyStyle())
                Spacer()
                if let shareURL {
                    ShareLink(item: shareURL) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(SoftKeyStyle())
                        .accessibilityLabel("Share")
                }
                Spacer()
                Button { Task { await deleteCurrent() } } label: { Image(systemName: "trash") }
                    .buttonStyle(SoftKeyStyle())
                    .accessibilityLabel("Delete")
            }
            .padding(.horizontal, 8)
            .frame(height: 52)
            .background(BarBackground())
        }
        .background(BarBackground().ignoresSafeArea())
        .foregroundStyle(.white)
        .statusBarHidden()
        .task(id: index) { await loadDetails() }
    }

    private var current: PHAsset? { assets.indices.contains(index) ? assets[index] : nil }

    private var dateText: String {
        guard let date = current?.creationDate else { return "" }
        return DateStamp.text(date: date, includeTime: true)
    }

    /// Writes the original JPEG to a temporary file for the share sheet and reads its camera.
    private func loadDetails() async {
        shareURL = nil
        cameraName = ""
        guard let asset = current, let data = await PhotoLibrary.data(for: asset) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Overshoot-\(index + 1).jpg")
        try? data.write(to: url)
        shareURL = url
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let model = tiff[kCGImagePropertyTIFFModel] as? String {
            cameraName = model
        }
    }

    private func deleteCurrent() async {
        guard let asset = current else { return }
        // iOS asks the person to confirm; cancelling throws and leaves the photo.
        guard (try? await PhotoLibrary.delete(asset)) != nil else { return }
        assets.removeAll { $0.localIdentifier == asset.localIdentifier }
        if assets.isEmpty {
            close()
        } else {
            index = min(index, assets.count - 1)
        }
    }
}

private struct FullImage: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().tint(Theme.orange)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .task(id: asset.localIdentifier) {
                let size = CGSize(width: geometry.size.width * displayScale, height: geometry.size.height * displayScale)
                image = await PhotoLibrary.image(for: asset, size: size, mode: .aspectFit)
            }
        }
    }
}
