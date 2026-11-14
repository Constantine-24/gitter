import Foundation

/// Where the update checker gets GitHub's answer: the real feed in the app, a script in tests.
protocol UpdateFetching: Sendable {
    func fetch() async -> UpdateAnswer
}

/// GitHub's latest-release endpoint (or, in DEBUG, the harness's `file://` or 127.0.0.1 feed),
/// asked through an ephemeral session that keeps no credentials, cookies or cache, with exactly
/// four headers and redirects only to `https://api.github.com/` (`UpdateRedirectGuard`).
struct GitHubUpdateFeed: UpdateFetching {
    let url: URL
    let userAgent: String

    /// `Gitter/<CFBundleShortVersionString>`: the bundle's own string, never the DEBUG version
    /// override.
    static func userAgent(info: [String: Any]) -> String {
        "Gitter/\(info["CFBundleShortVersionString"] as? String ?? "?")"
    }

    /// A GET with these four headers and nothing else, and a 15 s timeout. The User-Agent and
    /// Accept-Language are set so CFNetwork's own (naming the CFNetwork and Darwin versions, and
    /// the user's languages) are not sent.
    static func request(url: URL, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// Ephemeral, and keeping nothing even in memory: no credential storage, cookie storage or
    /// cache, no cookies sent or accepted. 15 s for the request, 30 s for the whole answer.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    /// An HTTP answer's status, or 200 for a response that is not HTTP: a `file://` feed's.
    static func answer(data: Data, response: URLResponse) -> UpdateAnswer {
        .response(status: (response as? HTTPURLResponse)?.statusCode ?? 200, body: data)
    }

    /// One request on a session of its own, invalidated afterwards (a session keeps its delegate
    /// until then). A cancelled task cancels the request.
    func fetch() async -> UpdateAnswer {
        let session = URLSession(
            configuration: Self.configuration(), delegate: UpdateRedirectGuard(feed: url), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: Self.request(url: url, userAgent: userAgent))
            return Self.answer(data: data, response: response)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

/// Follows a redirect only to `https://api.github.com/…` — and, in DEBUG, to the harness feed's
/// own 127.0.0.1 host and port. Any other redirect is refused, and the redirect's own answer
/// becomes the response (a 3xx: `UpdateOutcome.httpError`).
final class UpdateRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let feed: URL

    init(feed: URL) { self.feed = feed }

    /// The rule, pure: an https URL on exactly `api.github.com`, with no port and no user — or,
    /// in DEBUG, an http URL on the feed's own 127.0.0.1 host and port.
    static func allows(_ target: URL?, feed: URL) -> Bool {
        guard let target, let components = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            return false
        }
        guard components.user == nil, components.password == nil else { return false }
        if components.scheme == "https", components.host == "api.github.com", components.port == nil {
            return true
        }
        #if DEBUG
            if feed.scheme == "http", feed.host == "127.0.0.1", components.scheme == "http",
                components.host == "127.0.0.1", components.port == feed.port
            {
                return true
            }
        #endif
        return false
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        Self.allows(request.url, feed: feed) ? request : nil
    }
}
