//
//  LocalOAuthServer.swift
//  Buzzkill
//
//  Minimal `localhost` HTTP server for OAuth redirects (using FlyingFox).
//

import Combine
import FlyingFox
import Foundation

final class LocalOAuthServer {
  private var server: HTTPServer?
  private var runTask: Task<(), Never>?
  private var isStopped = false
  private var cancellables = Set<AnyCancellable>()

  // Redirect the browser to the app's custom URL scheme (which surfaces the status bar panel).
  static var responseConnecting = HTTPResponse(
    statusCode: .ok,
    headers: [.contentType: "text/html; charset=utf-8"],
    body: Data(
      """
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8" />
          <style>
            * {
              box-sizing: border-box;
              margin: 0;
              padding: 0;
              font-family: system-ui, sans-serif;
            }

            body {
              display: flex;
              flex-direction: column;
              align-items: center;
              gap: 1rem;
              background-color: #ffffff;
              padding-top: 40vh;
              width: 100vw;
              height: 100vh;
              color: #000000;
            }

            @media (prefers-color-scheme: dark) {
              body {
                background-color: #1a1a1a;
                color: #f0f0f0;
              }
            }

            h3 {
              font-weight: normal;
            }
          </style>
          <title>Buzzkill Authentication</title>
        </head>
        <body>
          <h1>Buzzkill is connecting to OpenRouter...</h1>
          <h3>If nothing happens, close this window and open the app.</h3>
          <script>
            (function () {
              try {
                setTimeout(() => (window.location.href = "buzzkill://open"), 250);
              } catch (error) {
                console.error(error);
              }
            })();
          </script>
        </body>
      </html>
      """.utf8)
  )

  /// Starts listening on a random `localhost` port and returns the callback URL string.
  /// Calls `onRequest` when the first request arrives and then terminates.
  func start(
    path: String = "/buzzkill/authenticate",
    onRequest: @escaping @Sendable (_ query: [String: String]) -> Void
  ) async -> String? {
    // Stop any previous instance defensively.
    stop()

    // Set up `GET` handler for routes prefixed with `path`.
    var routes = RoutedHTTPHandler()
    struct ClosureHandler: HTTPHandler, Sendable {
      let handle: @Sendable (HTTPRequest) async throws -> HTTPResponse
      func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await handle(request)
      }
    }
    let handler = ClosureHandler { request in
      // Only handle the desired path prefix; return 404 otherwise.
      guard request.path.hasPrefix(path) else {
        return Self.responseConnecting
      }
      let query = Dictionary(uniqueKeysWithValues: request.query.map { ($0.name, $0.value) })
      onRequest(query)
      Events.localOAuthServerRequestedStop.send()
      return Self.responseConnecting
    }
    routes.appendRoute(HTTPRoute(method: .GET, path: path), to: handler)

    // Serve on a specific range of ports accepted by OpenRouter.
    let chosenPort = Self.pickEphemeralPort()
    let server = HTTPServer(address: .loopback(port: chosenPort), handler: routes)
    self.server = server
    isStopped = false

    // Observe stop requests.
    Events.localOAuthServerRequestedStop
      .sink { [weak self] in
        self?.stop()
      }
      .store(in: &cancellables)

    // Run the server in a background task and return the callback URL.
    runTask = Task {
      // Ignore errors; server is short-lived and may be cancelled by stop().
      try? await server.run()
    }
    return "http://localhost:\(chosenPort)\(path)"
  }

  func stop() {
    guard !isStopped else {
      return
    }

    isStopped = true
    cancellables.removeAll()
    runTask?.cancel()
    runTask = nil
    server = nil
  }

  private static func pickEphemeralPort() -> UInt16 {
    // OpenRouter does not support many ports outside certain ranges.
    return UInt16(Int.random(in: 3005...3009))
  }
}
