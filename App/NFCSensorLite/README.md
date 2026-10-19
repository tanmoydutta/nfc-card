# NFC Sensor Lite

Standalone SwiftUI iPhone app for reading temperature and humidity from SHT40 through NTAG 5's I²C master. Includes the existing NTAG configuration and tag diagnostics features.

Only the latest successful measurement and its timestamp are displayed. No history, charts, or measurement persistence is included.

Open `NFCSensorLite.xcodeproj` in Xcode, select the NFCSensorLite scheme and your signing team, then run on an NFC-capable iPhone (iOS 17 or later). NFC requires a physical device.

Bundle identifier: `com.td.NFCSensorLite`. Home screen name: **NFC Sensor Lite**. The teal thermometer/droplet icon distinguishes it from the full app, and both apps can be installed together.

This project is independent of the original NFCReaderApp. Configuring NTAG 5 writes its hardware configuration; use the same stable external supply and power-cycle procedure as the full app.
