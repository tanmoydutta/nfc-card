import SwiftUI

struct ContentView: View {
    @StateObject private var reader = NFCReader()
    @State private var showConfigurationConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        .font(.system(size: 68)).foregroundStyle(.blue).accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("NTAG 5 Sensor").font(.largeTitle.bold())
                        Text("Read a fresh SHT40 measurement directly through the NTAG 5 I²C master.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    Button(action: reader.beginSHT40Measurement) {
                        Label(reader.isScanning ? "Working…" : "Read SHT40", systemImage: "thermometer.medium")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(reader.isScanning || !reader.isAvailable)

                    if let measurement = reader.latestMeasurement {
                        measurementCard(measurement)
                            .transition(.scale.combined(with: .opacity))
                    }

                    HStack {
                        Button(action: reader.beginScanning) {
                            Label("Read tag / NDEF", systemImage: "wave.3.right").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                        Button { showConfigurationConfirmation = true } label: {
                            Label("Configure", systemImage: "gearshape.2").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).tint(.orange)
                    }.disabled(reader.isScanning || !reader.isAvailable)

                    if !reader.isAvailable {
                        Label("NFC reading is not available on this device.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    statusCard
                    if !reader.details.isEmpty { technicalDetailsCard }
                }.padding()
                .animation(.spring(response: 0.45, dampingFraction: 0.82), value: reader.latestMeasurement)
            }
            .navigationTitle("NFC Sensor Lite")
            .alert("Configure NTAG 5?", isPresented: $showConfigurationConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Configure", role: .destructive, action: reader.beginNTAG5Configuration)
            } message: {
                Text("This rewrites configuration blocks 0x37 and 0x3D for I²C-master mode, SRAM and 3.0 V energy harvesting. Use stable external 3.3 V while configuring. Remove all power and the NFC field afterward so the new settings load on the next power-up.")
            }
        }
    }

    private func measurementCard(_ measurement: SensorMeasurement) -> some View {
        VStack(spacing: 18) {
            Label("Latest measurement", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            HStack(spacing: 12) {
                measurementValue(
                    title: "Temperature",
                    value: String(format: "%.1f°", measurement.temperature),
                    unit: "Celsius",
                    symbol: "thermometer.medium",
                    color: .orange
                )

                Divider().frame(height: 96)

                measurementValue(
                    title: "Humidity",
                    value: String(format: "%.1f%%", measurement.humidity),
                    unit: "Relative humidity",
                    symbol: "humidity.fill",
                    color: .blue
                )
            }

            Text(measurement.measuredAt, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.blue.opacity(0.13), Color.orange.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.blue.opacity(0.22), lineWidth: 1)
        }
    }

    private func measurementValue(
        title: String,
        value: String,
        unit: String,
        symbol: String,
        color: Color
    ) -> some View {
        VStack(spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Status", systemImage: reader.isScanning ? "dot.radiowaves.left.and.right" : "info.circle").font(.headline)
            Text(reader.status).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.secondary)
        }.cardStyle()
    }

    private var technicalDetailsCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(reader.details) { detail in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(detail.label).font(.caption).foregroundStyle(.secondary)
                        Text(detail.value).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if detail.id != reader.details.last?.id { Divider() }
                }
            }
            .padding(.top, 14)
        } label: {
            Label("NFC technical details", systemImage: "wave.3.right.circle")
                .font(.headline)
        }
        .cardStyle()
    }
}

private extension View {
    func cardStyle() -> some View { padding().frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16)) }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
