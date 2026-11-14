import Foundation
import Testing

@testable import Gitter

/// Update notices Task 2: the request and the session, asserted on the `URLRequest` and the
/// configuration without sending anything, and the redirect and response rules as pure functions.
/// No test here sends the request.
@Suite struct UpdateFeedTests {

    @Test func theRequestCarriesExactlyTheFourHeaders() {
        let request = GitHubUpdateFeed.request(url: UpdateCheck.apiURL, userAgent: "Gitter/0.2.0")
        #expect(
            request.allHTTPHeaderFields == [
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "Gitter/0.2.0",
                "Accept-Language": "en",
            ])
        #expect(request.timeoutInterval == 15)
        #expect(request.httpMethod == "GET")
        #expect(request.url == UpdateCheck.apiURL)
        #expect(request.httpBody == nil)
    }

    @Test func theUserAgentNamesTheBundleVersion() {
        #expect(GitHubUpdateFeed.userAgent(info: ["CFBundleShortVersionString": "0.2.0"]) == "Gitter/0.2.0")
        #expect(GitHubUpdateFeed.userAgent(info: [:]) == "Gitter/?")
    }

    @Test func theSessionKeepsNothing() {
        let configuration = GitHubUpdateFeed.configuration()
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 30)
        #expect(configuration.httpAdditionalHeaders == nil)
    }

    @Test func theRedirectRuleRefusesOtherHosts() {
        let feed = UpdateCheck.apiURL
        func allows(_ text: String) -> Bool { UpdateRedirectGuard.allows(URL(string: text), feed: feed) }
        #expect(allows("https://api.github.com/x"))
        #expect(!allows("https://github.com/x"))
        #expect(!allows("http://api.github.com/x"))
        #expect(!allows("https://api.github.com.evil.example/x"))
        #expect(!allows("https://api.github.com:8443/x"))
        #expect(!allows("https://user@api.github.com/x"))
        #expect(!allows("https://127.0.0.1:8080/x"))
        #expect(!UpdateRedirectGuard.allows(nil, feed: feed))
    }

    #if DEBUG
        /// The harness's 127.0.0.1 feed may redirect on its own host and port, and nowhere else.
        @Test func aLocalFeedMayRedirectOnlyToItself() {
            let feed = URL(string: "http://127.0.0.1:8123/feed.json")!
            func allows(_ text: String) -> Bool { UpdateRedirectGuard.allows(URL(string: text), feed: feed) }
            #expect(allows("http://127.0.0.1:8123/other.json"))
            #expect(!allows("http://127.0.0.1:8124/other.json"))
            #expect(!allows("http://localhost:8123/other.json"))
            #expect(!allows("https://github.com/x"))
            #expect(allows("https://api.github.com/x"))
        }
    #endif

    @Test func aFileFeedAnswersAsStatus200() {
        let body = Data(#"{"tag_name":"v9.9.9"}"#.utf8)
        let file = URLResponse(
            url: URL(fileURLWithPath: "/tmp/feed.json"), mimeType: "application/json",
            expectedContentLength: body.count, textEncodingName: nil)
        #expect(GitHubUpdateFeed.answer(data: body, response: file) == .response(status: 200, body: body))
        let missing = HTTPURLResponse(url: UpdateCheck.apiURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        #expect(GitHubUpdateFeed.answer(data: Data(), response: missing) == .response(status: 404, body: Data()))
    }
}
