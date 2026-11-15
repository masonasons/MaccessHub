import SwiftUI

/// Disk sounds, from Plattersong: the on/off switch and each disk's mix.
struct DiskSoundsSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var selectedID: String?

    private var feature: DiskSoundsFeature { AppController.shared.diskSounds }
    private var disks: [PhysicalDisk] { feature.disks }
    private var selected: PhysicalDisk? { disks.first { $0.id == selectedID } ?? disks.first }

    private func mix(_ disk: PhysicalDisk) -> Binding<DiskMix> {
        Binding(get: { store.data.diskSounds.mix(for: disk.id) },
                set: { store.data.diskSounds.disks[disk.id] = $0 })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Play disk sounds", isOn: $store.data.diskSounds.enabled)
                Text("A short click each time a physical disk reads, and a lower one when it writes, so you can hear the Mac working. Control-Shift-K turns disk sounds on or off; you can change that under Shortcuts. For reverb, or a volume and tone for all disks at once, choose Disk sounds on the Sound Processing tab.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let disk = selected {
                Section("Disk") {
                    Picker("Disk", selection: Binding(get: { disk.id }, set: { selectedID = $0 })) {
                        ForEach(disks) { Text($0.title).tag($0.id) }
                    }
                    Toggle("Play sounds for this disk", isOn: mix(disk).enabled)
                }
                mixSections(disk)
            } else {
                Section("Disk") {
                    Text("No physical disks found yet. Disks are checked every few seconds and whenever one is connected.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Credits") {
                Text("Disk sounds come from Plattersong by Onj (MIT licence). Its click sound is adapted from Sensor Readout 6.6.1 (MIT licence).")
                    .font(.callout).foregroundStyle(.secondary)
                Link("Plattersong on GitHub", destination: URL(string: "https://github.com/OnjLouis/Plattersong")!)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func mixSections(_ disk: PhysicalDisk) -> some View {
        let binding = mix(disk)
        let current = binding.wrappedValue
        Section("Sound") {
            Slider(value: intBinding(binding.volume), in: 0...100, step: 5) { Text("Volume") }
                minimumValueLabel: { Text("0%") } maximumValueLabel: { Text("100%") }
                .accessibilityValue("\(current.volume) percent")
            Slider(value: intBinding(binding.pan), in: -100...100, step: 10) { Text("Pan") }
                minimumValueLabel: { Text("Left") } maximumValueLabel: { Text("Right") }
                .accessibilityValue(Self.panDescription(current.pan))
            eqSlider("Bass", value: binding.bass)
            eqSlider("Middle", value: binding.middle)
            eqSlider("Treble", value: binding.treble)
        }
        .disabled(!current.enabled)
        Section("Try it") {
            HStack {
                Button("Preview Read") { feature.preview(current, write: false) }
                    .accessibilityHint("Plays ten read clicks with this disk's sound.")
                Button("Preview Write") { feature.preview(current, write: true) }
                    .accessibilityHint("Plays ten write clicks with this disk's sound.")
                Spacer()
                Button("Reset This Disk") {
                    var reset = DiskMix()
                    reset.enabled = current.enabled
                    binding.wrappedValue = reset
                    announce("Disk sound reset")
                }
                .accessibilityHint("Volume 30 percent, centred, flat tone.")
            }
            .disabled(!current.enabled)
        }
    }

    private func intBinding(_ value: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
    }

    private func eqSlider(_ title: String, value: Binding<Int>) -> some View {
        Slider(value: intBinding(value), in: -12...12, step: 1) {
            Text("\(title): \(value.wrappedValue > 0 ? "+" : "")\(value.wrappedValue) dB")
        } minimumValueLabel: { Text("-12") } maximumValueLabel: { Text("+12") }
        .accessibilityLabel(title)
        .accessibilityValue(SoundProcessingSettingsView.decibels(Double(value.wrappedValue)))
    }

    static func panDescription(_ pan: Int) -> String {
        pan == 0 ? "Centre" : "\(pan < 0 ? "Left" : "Right") \(abs(pan)) percent"
    }
}
