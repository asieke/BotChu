import Foundation
import BotChuCore

/// OpenRouter's video API: submit a job, poll it, download its clip. The key goes only in the
/// Authorization header of `openrouter.ai/api/` requests and is never logged.
struct OpenRouterVideos {
    let key: String
    static let base = URL(string: "https://openrouter.ai/api/v1/videos")!

    func submit(_ body: Data) async throws -> PetVideo.Job {
        var request = authorized(Self.base)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await job(from: request)
    }

    func status(of id: String) async throws -> PetVideo.Job {
        try await job(from: authorized(Self.base.appendingPathComponent(id)))
    }

    /// Downloads a finished job's first clip to `file`.
    func download(_ id: String, to file: URL) async throws {
        var components = URLComponents(url: Self.base.appendingPathComponent(id).appendingPathComponent("content"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "index", value: "0")]
        let (temporary, response) = try await URLSession.shared.download(for: authorized(components.url!))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? Data(contentsOf: temporary)).flatMap(PetVideo.Job.errorMessage)
            throw PetError("Downloading the clip failed: \(message ?? "status \((response as? HTTPURLResponse)?.statusCode ?? 0)").")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("BotChu", forHTTPHeaderField: "X-Title")
        return request
    }

    private func job(from request: URLRequest) async throws -> PetVideo.Job {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let job = PetVideo.Job.parse(data) { return job }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw PetError("OpenRouter refused the clip (status \(status)): \(PetVideo.Job.errorMessage(data) ?? "no reason given").")
    }
}
