import SwiftUI

/// The settings menu: a dark panel over the viewfinder with an icon tab row and list rows, the
/// selected row lit by the orange highlight bar.
struct MenuPanel: View {
    @Environment(CameraModel.self) private var model
    let close: () -> Void
    @State private var tab: Tab = .camera
    @State private var pickedDate = Date()

    enum Tab: CaseIterable {
        case camera, stamp, clock, facebook

        var symbol: String {
            switch self {
            case .camera: "camera.fill"
            case .stamp: "calendar"
            case .clock: "clock.fill"
            case .facebook: "square.and.arrow.up.fill"
            }
        }

        var title: String {
            switch self {
            case .camera: "Camera"
            case .stamp: "Date stamp"
            case .clock: "Camera clock"
            case .facebook: "Facebook copy"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.self) { item in
                    Button { tab = item } label: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .modifier(HighlightRow(selected: tab == item))
                    }
                    .accessibilityLabel(item.title)
                }
            }
            .padding(6)
            Text(tab.title)
                .font(Theme.font(17))
                .foregroundStyle(Theme.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            VStack(spacing: 4) { rows }
                .padding(6)
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            HStack {
                Spacer()
                Button("Done", action: close).buttonStyle(SoftKeyStyle())
            }
            .padding(.horizontal, 8)
        }
        .font(Theme.font(16))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .background(BarBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.silver.opacity(0.4), lineWidth: 1))
        .onAppear { pickedDate = model.cameraClockDate }
        .onChange(of: model.camera) { _, camera in
            if !camera.hasDateStamp, tab == .stamp { tab = .camera }
        }
    }

    private var tabs: [Tab] {
        model.camera.hasDateStamp ? Tab.allCases : Tab.allCases.filter { $0 != .stamp }
    }

    @ViewBuilder private var rows: some View {
        switch tab {
        case .camera:
            ForEach(Camera.allCases, id: \.self) { camera in
                row(camera.displayName, selected: model.camera == camera) { model.camera = camera }
            }
        case .stamp:
            row("Off", selected: model.dateStamp == .off) { model.dateStamp = .off }
            row("Date", selected: model.dateStamp == .date) { model.dateStamp = .date }
            row("Date & time", selected: model.dateStamp == .dateTime) { model.dateStamp = .dateTime }
        case .clock:
            DatePicker("Set", selection: $pickedDate)
                .tint(Theme.orange)
                .colorScheme(.dark)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .onChange(of: pickedDate) { _, picked in model.clockOffsetSeconds = picked.timeIntervalSinceNow }
            row("Use the current time", selected: model.clockOffsetSeconds == 0) {
                model.clockOffsetSeconds = 0
                pickedDate = Date()
            }
        case .facebook:
            row("Off", selected: !model.facebookCopy) { model.facebookCopy = false }
            row("Also save a 720 px copy", selected: model.facebookCopy) { model.facebookCopy = true }
        }
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .modifier(HighlightRow(selected: selected))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
