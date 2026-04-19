import XCTest
@testable import DriveClient

final class DriveFilesAPITests: XCTestCase {

    func testListFolderRequestShape() {
        let req = DriveFilesAPI.listFolderRequest(name: "2024", parentId: "parent-id")
        XCTAssertEqual(req.httpMethod, "GET")
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let query = Dictionary(
            uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(query["fields"], "files(id,name)")
        XCTAssertEqual(query["spaces"], "drive")
        XCTAssertEqual(query["pageSize"], "10")
        let q = query["q"]!
        XCTAssertTrue(q.contains("name = '2024'"), "got: \(q)")
        XCTAssertTrue(q.contains("mimeType = 'application/vnd.google-apps.folder'"))
        XCTAssertTrue(q.contains("'parent-id' in parents"))
        XCTAssertTrue(q.contains("trashed = false"))
    }

    func testCreateFolderRequestShape() throws {
        let req = try DriveFilesAPI.createFolderRequest(name: "2024-06-14", parentId: "parent-id")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        let body = try XCTUnwrap(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["name"] as? String, "2024-06-14")
        XCTAssertEqual(json?["mimeType"] as? String, "application/vnd.google-apps.folder")
        XCTAssertEqual(json?["parents"] as? [String], ["parent-id"])
    }

    func testFindByContentHashRequestShape() {
        let req = DriveFilesAPI.findByContentHashRequest(
            contentHash: "abc123",
            parentId: "folder-id"
        )
        XCTAssertEqual(req.httpMethod, "GET")
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let q = components.queryItems!.first { $0.name == "q" }!.value!
        XCTAssertTrue(q.contains("appProperties has { key='contentHash' and value='abc123' }"))
        XCTAssertTrue(q.contains("'folder-id' in parents"))
    }

    func testEscapesSingleQuotesInQueryValues() {
        let req = DriveFilesAPI.listFolderRequest(name: "foo'bar", parentId: "p")
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let q = components.queryItems!.first { $0.name == "q" }!.value!
        XCTAssertTrue(q.contains(#"name = 'foo\'bar'"#), "got: \(q)")
    }

    func testDriveFileListDecodingHandlesMissingAppProperties() throws {
        let json = #"""
        {"files": [{"id": "f1", "name": "x.jpg"}]}
        """#.data(using: .utf8)!
        let list = try JSONDecoder().decode(DriveFilesAPI.DriveFileList.self, from: json)
        XCTAssertEqual(list.files.count, 1)
        XCTAssertEqual(list.files[0].id, "f1")
        XCTAssertNil(list.files[0].appProperties)
    }

    func testDriveFileDecodingWithAppProperties() throws {
        let json = #"""
        {"id": "f2", "name": "y.cr2", "appProperties": {"contentHash": "h123", "dimroomAssetId": "uuid"}}
        """#.data(using: .utf8)!
        let file = try JSONDecoder().decode(DriveFilesAPI.DriveFile.self, from: json)
        XCTAssertEqual(file.appProperties?["contentHash"], "h123")
        XCTAssertEqual(file.appProperties?["dimroomAssetId"], "uuid")
    }
}
