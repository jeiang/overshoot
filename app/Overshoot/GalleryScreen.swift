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
/// Pinch or double-tap zooms; swiping between photos pauses while a photo is zoomed.
private struct PhotoViewer: View {
    @Binding var assets: [PHAsset]
    @State var index: Int
    let close: () -> Void
    @State private var shareURL: URL?
    @State private var cameraName = ""
    @State private var zoomed = false
    @Environment(\.openURL) private var openURL

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
                    ZoomableImage(asset: asset, zoomed: offset == index ? $zoomed : .constant(false)).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(zoomed)
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
                // iOS has no public way to open one photo in Photos; this opens the Photos app.
                Button { openURL(URL(string: "photos-redirect://")!) } label: { Image(systemName: "photo.on.rectangle") }
                    .buttonStyle(SoftKeyStyle())
                    .accessibilityLabel("Open Photos")
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

/// A photo that zooms like an old compact's playback: pinch or double-tap to zoom about the
/// centre, drag to pan, and a corner navigator shows which part of the photo is on screen.
private struct ZoomableImage: View {
    let asset: PHAsset
    @Binding var zoomed: Bool
    @State private var image: UIImage?
    @State private var fullResolution = false
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    private static let maximumScale: CGFloat = 8
    private static let doubleTapScale: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let fitted = fittedSize(in: geometry.size)
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                } else {
                    ProgressView().tint(Theme.orange)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnify(fitted: fitted, container: geometry.size))
            .simultaneousGesture(scale > 1 ? pan(fitted: fitted, container: geometry.size) : nil)
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    setScale(scale > 1 ? 1 : Self.doubleTapScale, fitted: fitted, container: geometry.size)
                }
                baseScale = scale
            }
            .overlay(alignment: .bottomTrailing) {
                if scale > 1, let image {
                    Navigator(image: image, visible: visibleRect(fitted: fitted, container: geometry.size))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .task(id: asset.localIdentifier) {
                let size = CGSize(width: geometry.size.width * displayScale, height: geometry.size.height * displayScale)
                image = await PhotoLibrary.image(for: asset, size: size, mode: .aspectFit)
            }
            .task(id: scale > 1) {
                guard scale > 1, !fullResolution else { return }
                fullResolution = true
                let size = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
                if let full = await PhotoLibrary.image(for: asset, size: size, mode: .aspectFit) { image = full }
            }
            .onDisappear {
                setScale(1, fitted: fitted, container: geometry.size)
                baseScale = 1
            }
        }
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0, container.width > 0, container.height > 0 else { return container }
        let aspect = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        return container.width / container.height > aspect
            ? CGSize(width: container.height * aspect, height: container.height)
            : CGSize(width: container.width, height: container.width / aspect)
    }

    private func magnify(fitted: CGSize, container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in setScale(baseScale * value.magnification, fitted: fitted, container: container) }
            .onEnded { _ in
                if scale < 1.05 { withAnimation(.easeOut(duration: 0.2)) { setScale(1, fitted: fitted, container: container) } }
                baseScale = scale
            }
    }

    private func pan(fitted: CGSize, container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clamped(
                    CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height),
                    scale: scale, fitted: fitted, container: container
                )
            }
            .onEnded { _ in baseOffset = offset }
    }

    private func setScale(_ value: CGFloat, fitted: CGSize, container: CGSize) {
        scale = min(max(value, 1), Self.maximumScale)
        offset = clamped(offset, scale: scale, fitted: fitted, container: container)
        baseOffset = offset
        zoomed = scale > 1
    }

    /// Keeps the zoomed photo covering the screen: no pan past its edges.
    private func clamped(_ offset: CGSize, scale: CGFloat, fitted: CGSize, container: CGSize) -> CGSize {
        let limitX = max(0, (fitted.width * scale - container.width) / 2)
        let limitY = max(0, (fitted.height * scale - container.height) / 2)
        return CGSize(width: min(max(offset.width, -limitX), limitX), height: min(max(offset.height, -limitY), limitY))
    }

    /// The on-screen part of the photo, in unit coordinates of the photo.
    private func visibleRect(fitted: CGSize, container: CGSize) -> CGRect {
        let width = min(1, container.width / (fitted.width * scale))
        let height = min(1, container.height / (fitted.height * scale))
        let centreX = 0.5 - offset.width / (fitted.width * scale)
        let centreY = 0.5 - offset.height / (fitted.height * scale)
        return CGRect(x: centreX - width / 2, y: centreY - height / 2, width: width, height: height)
    }
}

/// The playback-zoom navigator: the whole photo in miniature with a frame around the shown part.
private struct Navigator: View {
    let image: UIImage
    let visible: CGRect
    private let side: CGFloat = 96

    var body: some View {
        let aspect = image.size.width / max(image.size.height, 1)
        let size = aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
        Image(uiImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .opacity(0.6)
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .stroke(Theme.orange, lineWidth: 2)
                    .frame(width: visible.width * size.width, height: visible.height * size.height)
                    .offset(x: visible.minX * size.width, y: visible.minY * size.height)
            }
            .padding(3)
            .background(.black.opacity(0.7))
            .overlay(Rectangle().stroke(.white.opacity(0.8), lineWidth: 1))
    }
}
