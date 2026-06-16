import XCTest
@testable import Traceway

final class DeviceInfoTests: XCTestCase {

    func testCoreKeysPresent() {
        let info = DeviceInfoCollector.collectSync()
        XCTAssertEqual(info["os.name"], "ios")
        XCTAssertEqual(info["device.manufacturer"], "Apple")
        XCTAssertEqual(info["device.brand"], "Apple")
        XCTAssertNotNil(info["os.version"])
        XCTAssertNotNil(info["device.systemVersion"])
        XCTAssertNotNil(info["runtime.version"])
    }

    func testHardwareModelNonEmpty() {
        XCTAssertFalse(DeviceInfoCollector.hardwareModel().isEmpty)
    }

    func testIsPhysicalIsBooleanString() {
        let value = DeviceInfoCollector.collectSync()["device.isPhysical"]
        XCTAssertTrue(value == "true" || value == "false")
    }

    func testLocalePresent() {
        XCTAssertNotNil(DeviceInfoCollector.collectSync()["device.locale"])
    }
}
