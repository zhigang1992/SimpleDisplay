import XCTest
@testable import SimpleDisplayCore

final class ControlProtocolTests: XCTestCase {

    private let builtIn = DisplaySnapshot(
        id: 1, uuid: "AAAA-1111", name: "Built-in Retina Display", enabled: true, main: true,
        builtIn: true, virtual: false, remembered: false, mode: nil
    )
    private let lg = DisplaySnapshot(
        id: 3, uuid: "BBBB-2222", name: "LG HDR 4K", enabled: true, main: false,
        builtIn: false, virtual: false, remembered: false, mode: nil
    )
    private let lg2 = DisplaySnapshot(
        id: 5, uuid: "CCCC-3333", name: "LG UltraFine", enabled: false, main: false,
        builtIn: false, virtual: false, remembered: true, mode: nil
    )
    private var all: [DisplaySnapshot] { [builtIn, lg, lg2] }

    // MARK: - DisplaySelector

    func testResolveByKeyword() {
        XCTAssertEqual(try DisplaySelector.resolve("main", in: all).get(), builtIn)
        XCTAssertEqual(try DisplaySelector.resolve("BuiltIn", in: all).get(), builtIn)
    }

    func testResolveByID() {
        XCTAssertEqual(try DisplaySelector.resolve("5", in: all).get(), lg2)
    }

    func testResolveByUUIDCaseInsensitive() {
        XCTAssertEqual(try DisplaySelector.resolve("bbbb-2222", in: all).get(), lg)
    }

    func testResolveByExactNameBeatsSubstring() {
        XCTAssertEqual(try DisplaySelector.resolve("lg hdr 4k", in: all).get(), lg)
    }

    func testResolveByUniqueSubstring() {
        XCTAssertEqual(try DisplaySelector.resolve("ultra", in: all).get(), lg2)
    }

    func testAmbiguousSubstring() {
        guard case .failure(.ambiguous(_, let candidates)) = DisplaySelector.resolve("LG", in: all) else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    func testNotFound() {
        XCTAssertEqual(DisplaySelector.resolve("Dell", in: all), .failure(.notFound("Dell")))
    }

    // MARK: - ModeMatcher

    private func mode(_ w: Int, _ h: Int, _ hz: Double, hiDPI: Bool) -> ModeSnapshot {
        let scale = hiDPI ? 2 : 1
        return ModeSnapshot(width: w, height: h, pixelWidth: w * scale, pixelHeight: h * scale, refreshRate: hz, hiDPI: hiDPI)
    }

    func testPickPrefersCurrentHiDPIAndRefresh() {
        let modes = [
            mode(1920, 1080, 60, hiDPI: false),
            mode(1920, 1080, 60, hiDPI: true),
            mode(1920, 1080, 120, hiDPI: true),
        ]
        let current = mode(2560, 1440, 60, hiDPI: true)
        let picked = ModeMatcher.pick(ModeQuery(width: 1920, height: 1080), from: modes, current: current)
        XCTAssertEqual(picked, mode(1920, 1080, 60, hiDPI: true))
    }

    func testPickHonorsExplicitFilters() {
        let modes = [
            mode(1920, 1080, 60, hiDPI: false),
            mode(1920, 1080, 120, hiDPI: true),
        ]
        let current = mode(1920, 1080, 120, hiDPI: true)
        let picked = ModeMatcher.pick(ModeQuery(width: 1920, height: 1080, hiDPI: false), from: modes, current: current)
        XCTAssertEqual(picked, mode(1920, 1080, 60, hiDPI: false))
    }

    func testPickHighestRefreshWithoutCurrent() {
        let modes = [mode(1920, 1080, 60, hiDPI: false), mode(1920, 1080, 144, hiDPI: false)]
        XCTAssertEqual(ModeMatcher.pick(ModeQuery(width: 1920, height: 1080), from: modes, current: nil)?.refreshRate, 144)
    }

    func testPickNoMatch() {
        XCTAssertNil(ModeMatcher.pick(ModeQuery(width: 800, height: 600), from: [mode(1920, 1080, 60, hiDPI: false)], current: nil))
    }

    func testParseSize() {
        XCTAssertTrue(ModeQuery.parseSize("1920x1080")! == (1920, 1080))
        XCTAssertTrue(ModeQuery.parseSize("2560X1440")! == (2560, 1440))
        XCTAssertNil(ModeQuery.parseSize("1920"))
        XCTAssertNil(ModeQuery.parseSize("0x100"))
    }

    // MARK: - Wire format

    func testRequestRoundTrip() throws {
        let requests: [ControlRequest] = [
            .list,
            .setEnabled(display: "LG", enabled: false),
            .setMode(display: "main", mode: ModeQuery(width: 1920, height: 1080, hiDPI: true)),
        ]
        for request in requests {
            let data = try ControlSocket.encode(request)
            XCTAssertEqual(data.last, 0x0A)
            XCTAssertEqual(try ControlSocket.decode(ControlRequest.self, from: data.dropLast()), request)
        }
    }

    func testResponseRoundTrip() throws {
        let response = ControlResponse.displays(all)
        let data = try ControlSocket.encode(response)
        XCTAssertEqual(try ControlSocket.decode(ControlResponse.self, from: data.dropLast()), response)
    }

    func testSocketAddressRejectsLongPath() {
        XCTAssertNil(ControlSocket.address(for: String(repeating: "a", count: 200)))
        XCTAssertNotNil(ControlSocket.address(for: "/tmp/x.sock"))
    }
}
