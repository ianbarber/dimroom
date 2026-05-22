import XCTest
@testable import DriveClient

final class DriveChangesAPITests: XCTestCase {

    func testChangesListRequestRequestsAppPropertiesField() {
        // Issue #273: poller needs `appProperties` in the response so it
        // can drop changes for files dimroom didn't write. The `fields`
        // query parameter on `drive.changes.list` is what gates that.
        let req = DriveChangesAPI.changesListRequest(pageToken: "tok-1")
        XCTAssertEqual(req.httpMethod, "GET")
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let fields = components.queryItems!.first { $0.name == "fields" }?.value ?? ""
        XCTAssertTrue(
            fields.contains("appProperties"),
            "expected `appProperties` in fields parameter: \(fields)"
        )
    }

    func testChangeFileDecodesAppProperties() throws {
        let json = #"""
        {"id": "f1", "appProperties": {"dimroom": "1"}}
        """#.data(using: .utf8)!
        let file = try JSONDecoder().decode(DriveChangesAPI.ChangeFile.self, from: json)
        XCTAssertEqual(file.appProperties?["dimroom"], "1")
    }

    func testChangeFileDecodesMissingAppPropertiesAsNil() throws {
        let json = #"""
        {"id": "f1"}
        """#.data(using: .utf8)!
        let file = try JSONDecoder().decode(DriveChangesAPI.ChangeFile.self, from: json)
        XCTAssertNil(file.appProperties)
    }
}
