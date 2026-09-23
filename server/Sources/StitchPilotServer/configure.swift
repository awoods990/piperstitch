import Vapor

func configure(_ app: Application) throws {
    // Raw RGBA uploads from the browser: a 2000x2000 image is 16 MB before
    // the browser gzips it (flat-color artwork compresses 20-50x). The
    // browser also downscales anything larger than the pipeline can use
    // (see web/src/engine/decode.ts), so this ceiling is generous, not
    // routine.
    app.routes.defaultMaxBodySize = "48mb"
    app.http.server.configuration.requestDecompression = .enabled(limit: .size(64 * 1024 * 1024))
    app.http.server.configuration.responseCompression = .enabled
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "0.0.0.0"
    app.auth = AuthConfig.fromEnvironment(app)

    // Fail closed. Without a License Admin URL the entitlement gate lets
    // everyone through -- which is what you want on a laptop and a
    // catastrophe in production, where it quietly turns the paywall off.
    // Refusing to boot makes a missing variable a failed deploy (Railway
    // keeps the previous one running) instead of a free engine nobody
    // notices.
    if app.environment == .production && !app.auth.enabled {
        app.logger.critical("LICENSE_ADMIN_URL is not set: the entitlement gate would let everyone in. Refusing to start.")
        throw Abort(.internalServerError, reason: "LICENSE_ADMIN_URL is required in production")
    }

    // Development: the Vite dev server (another origin) talks to us
    // directly. Production serves the built web app from this same process
    // (see below), so cross-origin requests are normally none at all.
    let allowedOrigins = (Environment.get("CORS_ORIGINS") ?? "http://localhost:5173,http://127.0.0.1:5173")
        .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    let cors = CORSMiddleware(configuration: .init(
        allowedOrigin: .any(allowedOrigins),
        allowedMethods: [.GET, .POST, .OPTIONS],
        allowedHeaders: [.accept, .contentType, .contentEncoding, .origin, .authorization, "X-Requested-With"],
        allowCredentials: true
    ))
    app.middleware.use(cors, at: .beginning)
    app.middleware.use(SecurityHeaders())

    // The built web app, when present (Docker copies web/dist here). Any
    // path that isn't an API route falls through to index.html so the
    // browser router can take it from there.
    let publicDir = app.directory.publicDirectory
    if FileManager.default.fileExists(atPath: publicDir + "index.html") {
        app.middleware.use(SPAFallback(indexPath: publicDir + "index.html"))
        app.middleware.use(FileMiddleware(publicDirectory: publicDir, defaultFile: "index.html"))
    }

    try routes(app)
}

/// A GET for a path that is neither an API route nor a real file gets the
/// app's index.html, so a deep link (a saved project's URL, say) loads the
/// app and lets its router show the right thing.
struct SPAFallback: AsyncMiddleware {
    let indexPath: String

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let error as AbortError where error.status == .notFound
            && request.method == .GET && !request.url.path.hasPrefix("/api/")
            && !(request.url.path.split(separator: "/").last?.contains(".") ?? false) {  // a missing asset stays a 404
            return try await request.fileio.asyncStreamFile(at: indexPath)
        }
    }
}
