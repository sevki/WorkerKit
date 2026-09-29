import Testing
@testable import WorkerKit

// Request, Headers, Env and Context wrap JavaScript objects, so they are
// covered by the end-to-end tests in Tests/e2e. These tests cover the Swift
// side of Response, which runs before any JavaScript is involved.

@Test func okIsPlainText200() {
    let response = Response.ok("hi")

    #expect(response.status == 200)
    #expect(response.body == Array("hi".utf8))
    #expect(response.headers.map(\.name) == ["content-type"])
    #expect(response.headers.map(\.value) == ["text/plain; charset=utf-8"])
}

@Test func errorCarriesItsStatus() {
    let response = Response.error("Not Found", 404)

    #expect(response.status == 404)
    #expect(response.body == Array("Not Found".utf8))
}

@Test func withHeaderAppendsInOrder() {
    let response = Response.empty().withHeader("set-cookie", "a=1").withHeader("set-cookie", "b=2")

    #expect(response.status == 204)
    #expect(response.headers.map(\.value) == ["a=1", "b=2"])
}

@Test(arguments: [200, 204, 304, 404, 599])
func validatedKeepsStatusesResponseAccepts(status: Int) {
    #expect(Response(status: status).validated().status == status)
}

@Test(arguments: [0, 101, 199, 600, 1000])
func validatedRejectsStatusesResponseCannotRepresent(status: Int) {
    let response = Response(status: status).validated()

    #expect(response.status == 500)
    #expect(String(decoding: response.body, as: UTF8.self) == "Response status \(status) is outside 200-599")
}

@Test(arguments: [
    ("x-bad", "a\u{0}b"),
    ("x-bad", "line\nbreak"),
    ("x-bad", "carriage\rreturn"),
    ("x-bad", "emoji \u{1F642}"),
    ("bad name", "value"),
    ("", "value"),
    ("x-caf\u{e9}", "value"),
])
func validatedRejectsHeadersFetchCannotRepresent(name: String, value: String) {
    let response = Response.ok("hi").withHeader(name, value).validated()

    #expect(response.status == 500)
    #expect(String(decoding: response.body, as: UTF8.self) == "Response header is not a valid HTTP header")
}

@Test func validatedAcceptsTokenNamesAndLatin1Values() {
    let response = Response.ok("hi").withHeader("X-Custom_Header.v2!", "caf\u{e9} value").validated()

    #expect(response.status == 200)
}
