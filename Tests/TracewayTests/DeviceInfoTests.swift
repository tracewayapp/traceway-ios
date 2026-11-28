import XCTest
@testable import Traceway

final class DeviceInfoTests: XCTestCase {

    func testCoreKeysPresent() throws {
        let info = DeviceInfoCollector.collectSync()
        XCTAssertEqual(info["os.name"], "ios")
        XCTAssertEqual(info["device.manufacturer"], "Apple")
        XCTAssertEqual(info["device.brand"], "Apple")
        // The bare version (`17.4`), as on Android: rules compare it as a number.
        let version = try XCTUnwrap(info["os.version"])
        XCTAssertTrue(version.first?.isNumber == true, version)
        XCTAssertFalse(version.contains(" "), version)
        XCTAssertEqual(info["os.major"], version.split(separator: ".").first.map(String.init))
        XCTAssertNotNil(info["device.systemVersion"])
        XCTAssertNotNil(info["runtime.version"])
    }

    #if canImport(Darwin)
    func testHardwareModelNonEmpty() {
        XCTAssertFalse(DeviceInfoCollector.hardwareModel().isEmpty)
    }
    #endif

    func testIsPhysicalIsBooleanString() {
        let value = DeviceInfoCollector.collectSync()["device.isPhysical"]
        XCTAssertTrue(value == "true" || value == "false")
    }

    func testLocalePresent() {
        XCTAssertNotNil(DeviceInfoCollector.collectSync()["device.locale"])
    }
}
