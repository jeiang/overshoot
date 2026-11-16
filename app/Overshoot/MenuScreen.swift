import SwiftUI

/// The camera menu: Canon blue highlight bar, Nikon black with yellow highlight.
struct MenuScreen: View {
    @Environment(CameraModel.self) private var model
    @State private var pickedDate = Date()

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                if model.camera.hasDateStamp {
                    Picker("Date Stamp", selection: $model.dateStamp) {
                        Text("Off").tag(DateStampMode.off)
                        Text("Date").tag(DateStampMode.date)
                        Text("Date & Time").tag(DateStampMode.dateTime)
                    }
                }
                Section {
                    DatePicker("Date/Time", selection: $pickedDate)
                        .onChange(of: pickedDate) { _, picked in
                            model.clockOffsetSeconds = picked.timeIntervalSinceNow
                        }
                    Button("Use current time") {
                        model.clockOffsetSeconds = 0
                        pickedDate = Date()
                    }
                }
                Toggle("Facebook Copy", isOn: $model.facebookCopy)
            }
            .font(.system(size: 15, weight: .bold, design: .monospaced))
            .tint(highlight)
            .scrollContentBackground(.hidden)
            .background(background)
            .navigationTitle(model.camera == .canonA3400 ? "MENU" : "SET UP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(highlight, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(model.camera == .canonA3400 ? .dark : .light, for: .navigationBar)
        }
        .onAppear { pickedDate = model.cameraClockDate }
        .colorScheme(.dark)
    }

    private var highlight: Color {
        model.camera == .canonA3400 ? Color(red: 0.10, green: 0.35, blue: 0.85) : .yellow
    }

    private var background: Color {
        model.camera == .canonA3400 ? Color(red: 0.05, green: 0.08, blue: 0.20) : .black
    }
}
