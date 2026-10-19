import CoreNFC
import Foundation

struct TagDetail: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let value: String
}

struct SensorMeasurement: Equatable {
    let temperature: Double
    let humidity: Double
    let measuredAt: Date
}

// Core NFC serializes its delegate callbacks and this type explicitly marshals
// UI-facing changes onto the main queue. Declaring the reference sendable lets
// the async NTAG operation closure retain it without a Swift concurrency warning.
final class NFCReader: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isScanning = false
    @Published private(set) var status = "Ready."
    @Published private(set) var details: [TagDetail] = []
    @Published private(set) var latestMeasurement: SensorMeasurement?
    var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

    private enum Operation { case readTag, readSHT40, configureNTAG5 }
    private var session: NFCTagReaderSession?
    private var operation: Operation = .readTag
    private var completedSuccessfully = false
    private var operationFailure: String?

    func beginScanning() {
        beginSession(.readTag, options: [.iso14443, .iso15693], prompt: "Hold your iPhone near an NFC tag.")
    }

    func beginSHT40Measurement() {
        latestMeasurement = nil
        beginSession(.readSHT40, options: [.iso15693], prompt: "Hold the top of your iPhone against the NTAG 5 sensor card and keep it still.")
    }

    func beginNTAG5Configuration() {
        beginSession(.configureNTAG5, options: [.iso15693], prompt: "Keep the externally powered NTAG 5 card against your iPhone until configuration completes.")
    }

    private func beginSession(_ operation: Operation, options: NFCTagReaderSession.PollingOption, prompt: String) {
        guard isAvailable else {
            status = "This iPhone does not support NFC tag reading."
            return
        }
        details = []
        status = "Waiting for a tag…"
        isScanning = true
        completedSuccessfully = false
        operationFailure = nil
        self.operation = operation

        guard let session = NFCTagReaderSession(pollingOption: options, delegate: self, queue: nil) else {
            status = "Could not create an NFC reader session."
            isScanning = false
            return
        }
        session.alertMessage = prompt
        self.session = session
        session.begin()
    }
}

extension NFCReader: NFCTagReaderSessionDelegate {
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        publish(status: "Scanning for a nearby NFC tag…")
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let readerError = error as? NFCReaderError
        let wasCancelled = readerError?.code == .readerSessionInvalidationErrorUserCanceled
        let success = completedSuccessfully
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === session else { return }
            self.isScanning = false
            self.session = nil
            if success { return }
            if let operationFailure = self.operationFailure {
                self.status = operationFailure
                return
            }
            if !wasCancelled { self.status = "Scan ended: \(error.localizedDescription)" }
            else if self.details.isEmpty { self.status = "Scan cancelled." }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = "More than one tag was detected. Move the others away and try again."
            session.restartPolling()
            return
        }
        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if let error {
                session.invalidate(errorMessage: "Could not connect to the tag: \(error.localizedDescription)")
                return
            }
            switch self.operation {
            case .readTag:
                self.readTag(tag, in: session)
            case .readSHT40:
                self.runNTAG5Task(tag, in: session) { try await self.readSHT40(using: $0) }
            case .configureNTAG5:
                self.runNTAG5Task(tag, in: session) { try await self.configureNTAG5($0) }
            }
        }
    }
}

private extension NFCReader {
    enum NTAG5Error: LocalizedError {
        case requiresISO15693, requiresNXP, i2cAddressNAK, i2cDataNAK, i2cWatchdog, i2cTimeout, sensorCRC, configurationVerification
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .requiresISO15693: return "This operation requires an ISO 15693 NTAG 5 tag."
            case .requiresNXP: return "The detected ISO 15693 tag is not an NXP tag."
            case .invalidResponse(let command): return "NTAG 5 returned an invalid response to \(command)."
            case .i2cAddressNAK: return "SHT40 did not acknowledge I²C address 0x44. Check power, orientation, SDA and SCL."
            case .i2cDataNAK: return "SHT40 rejected the I²C data byte."
            case .i2cWatchdog: return "The NTAG 5 I²C-master watchdog expired. Check the bus and pull-ups."
            case .i2cTimeout: return "The NTAG 5 I²C transaction did not complete in time."
            case .sensorCRC: return "SHT40 returned data with an invalid CRC. Keep the phone steady and try again."
            case .configurationVerification: return "The NTAG 5 configuration read-back did not match the requested values."
            }
        }
    }

    struct SHT40Reading { let temperature: Double; let humidity: Double; let rawData: Data }

    func runNTAG5Task(_ tag: NFCTag, in session: NFCTagReaderSession, task: @escaping (NFCISO15693Tag) async throws -> ([TagDetail], String)) {
        guard case .iso15693(let isoTag) = tag else {
            session.invalidate(errorMessage: NTAG5Error.requiresISO15693.localizedDescription)
            return
        }
        guard isoTag.icManufacturerCode == 0x04 else {
            session.invalidate(errorMessage: NTAG5Error.requiresNXP.localizedDescription)
            return
        }
        let hardware = hardwareDetails(for: tag)
        Task { [weak self] in
            guard let self else { return }
            do {
                let (result, message) = try await task(isoTag)
                self.finish(session: session, details: hardware + result, message: message)
            } catch {
                let diagnostic = self.diagnosticDescription(for: error)
                self.operationFailure = "Operation failed: \(diagnostic)"
                self.trace("FAILED \(diagnostic)")
                session.invalidate(errorMessage: error.localizedDescription)
            }
        }
    }

    func readSHT40(using tag: NFCISO15693Tag) async throws -> ([TagDetail], String) {
        publish(status: "Starting an SHT40 measurement through NTAG 5…")
        // D4 WRITE I2C: slave address, length minus one, SHT40 high-precision command.
        _ = try await customCommand(tag, code: 0xD4, parameters: [0x44, 0x00, 0xFD])
        try await waitForI2CMaster(tag)
        try await Task.sleep(nanoseconds: 12_000_000)
        // D5 READ I2C stores six bytes in SRAM; D2 READ SRAM retrieves them.
        _ = try await customCommand(tag, code: 0xD5, parameters: [0x44, 0x05])
        try await waitForI2CMaster(tag)
        let response = try await customCommand(tag, code: 0xD2, parameters: [0x00, 0x05])
        let reading = try decodeSHT40(response)
        DispatchQueue.main.async { [weak self] in
            self?.latestMeasurement = SensorMeasurement(
                temperature: reading.temperature,
                humidity: reading.humidity,
                measuredAt: Date()
            )
        }
        return ([
            TagDetail(label: "Temperature", value: String(format: "%.2f °C", reading.temperature)),
            TagDetail(label: "Relative humidity", value: String(format: "%.2f %%RH", reading.humidity)),
            TagDetail(label: "SHT40 I²C address", value: "0x44"),
            TagDetail(label: "SHT40 response", value: reading.rawData.hexString),
            TagDetail(label: "CRC", value: "Valid")
        ], "Fresh SHT40 measurement read through NTAG 5.")
    }

    func configureNTAG5(_ tag: NFCISO15693Tag) async throws -> ([TagDetail], String) {
        publish(status: "Reading the current NTAG 5 configuration…")
        let old37 = try await readConfigurationBlock(tag, address: 0x0037)
        let old3D = try await readConfigurationBlock(tag, address: 0x003D)

        var new37 = old37
        // CONFIG_1: auto EH arbitration, I²C master, normal arbiter, SRAM enabled.
        new37[1] = (old37[1] & 0x41) | 0x92
        var new3D = old3D
        // EH_CONFIG: 2.7 mA selector, bypass check for bring-up, 3.0 V, enabled.
        new3D[0] = 0x3D

        publish(status: "Writing NTAG 5 I²C-master and energy-harvesting configuration…")
        try await writeConfigurationBlock(tag, address: 0x0037, bytes: new37)
        try await Task.sleep(nanoseconds: 15_000_000)
        try await writeConfigurationBlock(tag, address: 0x003D, bytes: new3D)
        try await Task.sleep(nanoseconds: 15_000_000)
        let verify37 = try await readConfigurationBlock(tag, address: 0x0037)
        let verify3D = try await readConfigurationBlock(tag, address: 0x003D)
        guard verify37 == new37, verify3D == new3D else {
            throw NTAG5Error.configurationVerification
        }
        return ([
            TagDetail(label: "Block 0x37 before", value: Data(old37).hexString),
            TagDetail(label: "Block 0x37 after", value: Data(new37).hexString),
            TagDetail(label: "Block 0x3D before", value: Data(old3D).hexString),
            TagDetail(label: "Block 0x3D after", value: Data(new3D).hexString),
            TagDetail(label: "I²C mode", value: "Master; SRAM enabled"),
            TagDetail(label: "Energy harvesting", value: "3.0 V; enabled; power check disabled"),
            TagDetail(label: "Required next step", value: "Remove NFC and external power, then fully power-cycle the card")
        ], "NTAG 5 configured and verified. Fully power-cycle the card before reading SHT40.")
    }

    func customCommand(_ tag: NFCISO15693Tag, code: Int, parameters: [UInt8]) async throws -> Data {
        // Core NFC inserts NXP's 0x04 manufacturer byte automatically.
        let request = Data(parameters)
        trace(String(format: "TX command=0x%02X parameters=[%@]", code, request.hexString))
        do {
            let response = try await tag.customCommand(
                requestFlags: [.highDataRate],
                customCommandCode: code,
                customRequestParameters: request
            )
            trace(String(format: "RX command=0x%02X data=[%@]", code, response.hexString))
            return response
        } catch {
            trace(String(format: "RX command=0x%02X ERROR %@", code, diagnosticDescription(for: error)))
            throw error
        }
    }

    func readConfigurationBlock(_ tag: NFCISO15693Tag, address: UInt8) async throws -> [UInt8] {
        // READ CONFIG takes an 8-bit block address followed by number-of-blocks minus one.
        let data = try await customCommand(tag, code: 0xC0, parameters: [address, 0x00])
        guard data.count >= 4 else { throw NTAG5Error.invalidResponse("READ CONFIGURATION") }
        return Array(data.prefix(4))
    }

    func writeConfigurationBlock(_ tag: NFCISO15693Tag, address: UInt8, bytes: [UInt8]) async throws {
        guard bytes.count == 4 else { throw NTAG5Error.invalidResponse("WRITE CONFIGURATION") }
        // WRITE CONFIG takes one 8-bit block address and exactly four data bytes.
        _ = try await customCommand(tag, code: 0xC1, parameters: [address] + bytes)
    }

    func waitForI2CMaster(_ tag: NFCISO15693Tag) async throws {
        for _ in 0..<50 {
            let statusBlock = try await readConfigurationBlock(tag, address: 0x00AD)
            let value = statusBlock[0]
            let busy = (value & 0x01) != 0
            let transactionStatus = (value >> 1) & 0x03
            if (value & 0x08) != 0 { throw NTAG5Error.i2cWatchdog }
            if !busy {
                if transactionStatus == 0x03 { return }
                if transactionStatus == 0x01 { throw NTAG5Error.i2cAddressNAK }
                if transactionStatus == 0x02 { throw NTAG5Error.i2cDataNAK }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NTAG5Error.i2cTimeout
    }

    func decodeSHT40(_ response: Data) throws -> SHT40Reading {
        guard response.count >= 6 else { throw NTAG5Error.invalidResponse("READ SRAM") }
        let bytes = Array(response.prefix(6))
        guard sht40CRC(bytes[0...1]) == bytes[2], sht40CRC(bytes[3...4]) == bytes[5] else { throw NTAG5Error.sensorCRC }
        let rawT = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let rawRH = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
        let temperature = -45.0 + 175.0 * Double(rawT) / 65_535.0
        let humidity = min(100.0, max(0.0, -6.0 + 125.0 * Double(rawRH) / 65_535.0))
        return SHT40Reading(temperature: temperature, humidity: humidity, rawData: Data(bytes))
    }

    func sht40CRC(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0xFF
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x31 : crc << 1 }
        }
        return crc
    }

    func readTag(_ tag: NFCTag, in session: NFCTagReaderSession) {
        var result = hardwareDetails(for: tag)
        guard let ndefTag = ndefTag(from: tag) else {
            result.append(TagDetail(label: "NDEF", value: "Not supported"))
            finish(session: session, details: result, message: "Tag read successfully.")
            return
        }
        ndefTag.queryNDEFStatus { ndefStatus, capacity, error in
            if let error {
                result.append(TagDetail(label: "NDEF", value: "Status unavailable: \(error.localizedDescription)"))
                self.finish(session: session, details: result, message: "Tag detected, but NDEF status could not be read.")
                return
            }
            result.append(TagDetail(label: "NDEF access", value: self.description(for: ndefStatus)))
            result.append(TagDetail(label: "NDEF capacity", value: "\(capacity) bytes"))
            guard ndefStatus != .notSupported else {
                self.finish(session: session, details: result, message: "Tag read successfully. It contains no NDEF data.")
                return
            }
            ndefTag.readNDEF { message, error in
                if let error { result.append(TagDetail(label: "NDEF message", value: "Could not read: \(error.localizedDescription)")) }
                else if let message {
                    result.append(TagDetail(label: "NDEF records", value: "\(message.records.count)"))
                    for (index, record) in message.records.enumerated() { result.append(contentsOf: self.details(for: record, index: index + 1)) }
                } else { result.append(TagDetail(label: "NDEF records", value: "0")) }
                self.finish(session: session, details: result, message: "Tag read successfully.")
            }
        }
    }

    func hardwareDetails(for tag: NFCTag) -> [TagDetail] {
        switch tag {
        case .miFare(let t): return [TagDetail(label: "Tag technology", value: "MiFare / ISO 14443"), TagDetail(label: "Identifier", value: t.identifier.hexString)]
        case .iso7816(let t): return [TagDetail(label: "Tag technology", value: "ISO 7816"), TagDetail(label: "Identifier", value: t.identifier.hexString)]
        case .iso15693(let t): return [TagDetail(label: "Tag technology", value: "ISO 15693"), TagDetail(label: "Identifier", value: t.identifier.hexString), TagDetail(label: "Manufacturer code", value: String(format: "0x%02X", t.icManufacturerCode)), TagDetail(label: "IC serial number", value: t.icSerialNumber.hexString)]
        case .feliCa(let t): return [TagDetail(label: "Tag technology", value: "FeliCa"), TagDetail(label: "Current IDm", value: t.currentIDm.hexString)]
        @unknown default: return [TagDetail(label: "Tag technology", value: "Unknown")]
        }
    }

    func ndefTag(from tag: NFCTag) -> NFCNDEFTag? {
        switch tag {
        case .miFare(let t): return t
        case .iso7816(let t): return t
        case .iso15693(let t): return t
        case .feliCa(let t): return t
        @unknown default: return nil
        }
    }

    func description(for status: NFCNDEFStatus) -> String {
        switch status { case .notSupported: return "Not supported"; case .readOnly: return "Read-only"; case .readWrite: return "Read and write"; @unknown default: return "Unknown" }
    }

    func details(for record: NFCNDEFPayload, index: Int) -> [TagDetail] {
        let prefix = "Record \(index)"
        var result = [TagDetail(label: "\(prefix) type", value: record.typeNameFormat.readableName)]
        if let text = record.wellKnownText { result.append(TagDetail(label: "\(prefix) text", value: text)) }
        else if let url = record.wellKnownURL { result.append(TagDetail(label: "\(prefix) URL", value: url.absoluteString)) }
        else if let payload = String(data: record.payload, encoding: .utf8), !payload.isEmpty { result.append(TagDetail(label: "\(prefix) payload", value: payload)) }
        else { result.append(TagDetail(label: "\(prefix) payload (hex)", value: record.payload.hexString)) }
        return result
    }

    func finish(session: NFCTagReaderSession, details: [TagDetail], message: String) {
        completedSuccessfully = true
        session.alertMessage = message
        session.invalidate()
        DispatchQueue.main.async { [weak self] in self?.details = details; self?.status = message }
    }

    func publish(status: String) { DispatchQueue.main.async { [weak self] in self?.status = status } }

    func diagnosticDescription(for error: Error) -> String {
        let nsError = error as NSError
        let tagResponse = nsError.userInfo[NFCISO15693TagResponseErrorKey]
            .map { " tagResponse=\($0)" } ?? ""
        return "\(nsError.localizedDescription) [\(nsError.domain):\(nsError.code)]\(tagResponse) userInfo=\(nsError.userInfo)"
    }

    func trace(_ message: String) {
        print("[NTAG5] \(message)")
    }
}

private extension Data { var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") } }

private extension NFCNDEFPayload {
    var wellKnownText: String? {
        guard typeNameFormat == .nfcWellKnown, type == Data([0x54]), let status = payload.first else { return nil }
        let length = Int(status & 0x3F)
        guard payload.count > length + 1 else { return nil }
        return String(data: Data(payload.dropFirst(length + 1)), encoding: (status & 0x80) == 0 ? .utf8 : .utf16BigEndian)
    }
    var wellKnownURL: URL? { typeNameFormat == .nfcWellKnown && type == Data([0x55]) ? wellKnownTypeURIPayload() : nil }
}

private extension NFCTypeNameFormat {
    var readableName: String {
        switch self { case .empty: return "Empty"; case .nfcWellKnown: return "NFC well-known"; case .media: return "Media/MIME"; case .absoluteURI: return "Absolute URI"; case .nfcExternal: return "NFC external"; case .unknown: return "Unknown"; case .unchanged: return "Unchanged"; @unknown default: return "Other" }
    }
}
