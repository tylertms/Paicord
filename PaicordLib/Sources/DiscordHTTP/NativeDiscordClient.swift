import DiscordModels
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Chroncord's watchOS transport for Paicord's endpoint and payload APIs.
public struct NativeDiscordClient: DiscordClient {
  public var captchaCallback: CaptchaChallengeHandler?
  public var mfaCallback: MFAVerificationHandler?
  public let authentication: AuthenticationHeader
  public let appId: ApplicationSnowflake? = nil
  private let session: URLSession
  private let rateLimiter = HTTPRateLimiter(label: "Chroncord")

  public init(token: String? = nil, session: URLSession = .shared) {
    authentication = token.map { .userToken(Secret($0)) } ?? .userNone
    self.session = session
  }

  public func send(request: DiscordHTTPRequest) async throws -> DiscordHTTPResponse {
    try await execute(request)
  }

  public func send<E: Sendable & Encodable & ValidatablePayload>(
    request: DiscordHTTPRequest, payload: E
  ) async throws -> DiscordHTTPResponse {
    try validate(payload)
    return try await execute(request, body: DiscordGlobalConfiguration.encoder.encode(payload))
  }

  public func sendMultipart<E: Sendable & MultipartEncodable & ValidatablePayload>(
    request: DiscordHTTPRequest, payload: E
  ) async throws -> DiscordHTTPResponse {
    try validate(payload)
    if let buffer = try payload.encodeMultipart() {
      return try await execute(
        request, body: Data(buffer: buffer),
        contentType: "multipart/form-data; boundary=\(MultipartConfiguration.boundary)")
    }
    return try await execute(request, body: DiscordGlobalConfiguration.encoder.encode(payload))
  }

  private func validate(_ payload: some ValidatablePayload) throws {
    let failures = payload.validate()
    if !failures.isEmpty {
      throw ClientError(status: 0, message: failures.map(\.description).joined(separator: "\n"))
    }
  }

  private func execute(
    _ req: DiscordHTTPRequest, body: Data? = nil,
    contentType: String = "application/json"
  ) async throws -> DiscordHTTPResponse {
    guard var parts = URLComponents(string: req.endpoint.url) else { throw URLError(.badURL) }
    let queries = req.queries.compactMap { name, value in
      value.map { URLQueryItem(name: name, value: $0) }
    }
    if !queries.isEmpty { parts.queryItems = (parts.queryItems ?? []) + queries }
    guard let url = parts.url else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.httpMethod = req.endpoint.httpMethod.rawValue
    request.httpBody = body
    for header in req.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
    try addHeaders(to: &request, authenticated: req.endpoint.requiresAuthorizationHeader)
    if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    while true {
      switch await rateLimiter.shouldRequest(to: req.endpoint) {
      case .true:
        break
      case .false:
        throw ClientError(status: 429, message: "Please wait a moment before trying again.")
      case .after(let delay):
        guard delay.isFinite, delay >= 0, delay <= 30 else {
          throw ClientError(
            status: 429, message: "Discord is rate limiting requests. Please try again shortly.")
        }
        try await Task.sleep(for: .seconds(delay))
        continue
      }
      break
    }
    let (data, response) = try await perform(request, endpoint: req.endpoint)
    let headers = HTTPHeaders(
      response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) })
    let status = HTTPResponseStatus(statusCode: response.statusCode)
    return .init(
      host: url.host ?? "discord.com", status: status, version: .http1_1,
      headers: headers, body: ByteBuffer(data: data))
  }

  private func addHeaders(to request: inout URLRequest, authenticated: Bool) throws {
    if authenticated {
      guard case .userToken(let secret) = authentication, !secret.value.isEmpty else {
        throw ClientError(status: 401, message: "Please sign in to Discord.")
      }
      request.setValue(secret.value, forHTTPHeaderField: "Authorization")
    }
    request.setValue(SuperProperties.useragent(ws: false), forHTTPHeaderField: "User-Agent")
    request.setValue(
      SuperProperties.GenerateSuperPropertiesHeader(), forHTTPHeaderField: "X-Super-Properties")
    request.setValue(SuperProperties.GenerateLocaleHeader(), forHTTPHeaderField: "X-Discord-Locale")
    request.setValue(
      SuperProperties.GenerateTimezoneHeader(), forHTTPHeaderField: "X-Discord-Timezone")
    request.timeoutInterval = 30
  }

  private func perform(_ request: URLRequest, endpoint: AnyEndpoint? = nil) async throws -> (
    Data, HTTPURLResponse
  ) {
    var request = request
    var captchaAttempts = 0
    var rateLimitAttempts = 0
    var captchaContext = ""
    var captchaSubmittedAt: TimeInterval = 0
    while true {
      try Task.checkCancellation()
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
      if let endpoint {
        let headers = HTTPHeaders(
          response.allHeaderFields.map {
            (String(describing: $0.key), String(describing: $0.value))
          })
        await rateLimiter.include(
          endpoint: endpoint, headers: headers, status: .init(statusCode: response.statusCode))
      }
      if (200..<300).contains(response.statusCode) {
        let requestedHost = request.url?.host?.lowercased()
        let responseHost = response.url?.host?.lowercased()
        if responseHost != requestedHost {
          throw ClientError(
            status: response.statusCode,
            message:
              "A network sign-in page intercepted Discord. Open Wi-Fi settings and sign in, then retry."
          )
        }
        if response.mimeType?.lowercased() == "text/html" || data.first == 60 {
          throw ClientError(
            status: response.statusCode,
            message:
              "The network returned a web page instead of Discord data. Check Wi-Fi access and retry."
          )
        }
        return (data, response)
      }
      if response.statusCode == 429, rateLimitAttempts < 2 {
        struct RateLimit: Decodable { let retry_after: Double }
        let delay =
          (try? JSONDecoder().decode(RateLimit.self, from: data))?.retry_after
          ?? response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        if let delay, delay.isFinite, delay >= 0, delay <= 30 {
          rateLimitAttempts += 1
          try await Task.sleep(nanoseconds: UInt64(max(0.1, delay) * 1_000_000_000))
          continue
        }
      }
      struct Challenge: Decodable {
        let captcha_key: [String]?
        let captcha_service: String?
        let captcha_sitekey: String?
        let captcha_session_id: String?
        let captcha_rqdata: String?
        let captcha_rqtoken: String?
        let should_serve_invisible: Bool?
      }
      if response.statusCode == 400,
        let challenge = try? JSONDecoder().decode(Challenge.self, from: data),
        let keys = challenge.captcha_key
      {
        guard let captchaCallback else {
          throw ClientError(
            status: 400,
            message:
              "Discord requires a CAPTCHA for this request. CAPTCHA challenges are not supported in this app.\nHTTP 400"
          )
        }
        guard captchaAttempts == 0 else {
          let reason = String(keys.joined(separator: ", ").prefix(300))
          let elapsed = Int(max(0, ProcessInfo.processInfo.systemUptime - captchaSubmittedAt))
          throw ClientError(
            status: 400,
            message:
              "Discord didn't accept the security check. Please try again.\n\(reason)\nHTTP 400\n\n\(captchaContext)\nAnswer to rejection: \(elapsed)s\nRate-limit retries: \(rateLimitAttempts)"
          )
        }
        let details = CaptchaChallengeData(
          captchaKey: keys, captchaService: challenge.captcha_service ?? "unknown",
          captchaSiteKey: challenge.captcha_sitekey, captchaSessionId: challenge.captcha_session_id,
          captchaRqdata: challenge.captcha_rqdata, captchaRqtoken: challenge.captcha_rqtoken,
          shouldServeInvisible: challenge.should_serve_invisible)
        let started = ProcessInfo.processInfo.systemUptime
        guard let solution = await captchaCallback(details), !solution.solutionToken.isEmpty else {
          try Task.checkCancellation()
          throw ClientError(
            status: 400, message: "The security check was cancelled. Please try again.")
        }
        try Task.checkCancellation()
        captchaSubmittedAt = ProcessInfo.processInfo.systemUptime
        captchaContext = [
          "Initial challenge: \(String(keys.joined(separator: ", ").prefix(300)))",
          "Service: \(String(details.captchaService.prefix(40)))",
          "Requested widget: \(details.shouldServeInvisible == true ? "invisible" : "checkbox")",
          "Challenge data: \(details.captchaRqdata?.utf8.count ?? 0) bytes",
          "Session ID: \(details.captchaSessionId?.isEmpty == false ? "present" : "missing")",
          "Request token: \(details.captchaRqtoken?.isEmpty == false ? "present" : "missing")",
          "Answer: \(solution.solutionToken.utf8.count) bytes",
          "Challenge to answer: \(Int(max(0, captchaSubmittedAt - started)))s",
        ].joined(separator: "\n")
        request.setValue(solution.solutionToken, forHTTPHeaderField: "X-Captcha-Key")
        request.setValue(challenge.captcha_session_id, forHTTPHeaderField: "X-Captcha-Session-Id")
        request.setValue(challenge.captcha_rqtoken, forHTTPHeaderField: "X-Captcha-Rqtoken")
        captchaAttempts += 1
        continue
      }
      let failure = try? JSONDecoder().decode(JSONError.self, from: data)
      if failure?.mfa != nil {
        throw ClientError(
          status: response.statusCode,
          message:
            "Discord requires two-factor verification for this action. Complete it in Discord.")
      }
      let message = Self.failureMessage(failure, status: response.statusCode)
      throw ClientError(
        status: response.statusCode, message: message + "\nHTTP \(response.statusCode)")
    }
  }

  private static func failureMessage(_ failure: JSONError?, status: Int) -> String {
    switch failure?.code {
    case .cantPerformDueToSlowModeRateLimit:
      return "Slowmode is active. Wait before sending another message."
    case .channelHitWriteRateLimit, .actionOnServerHitWriteRateLimit, .serviceResourceRateLimited:
      return "Discord is limiting this action. Please try again shortly."
    case .missingAccess, .missingPermissions:
      return "You don't have permission to do that."
    case .channelVerificationLevelIsTooHighForYouToGainAccess:
      return "Complete this server's verification in Discord before trying again."
    case .explicitContentCannotBeSentToRecipients,
      .stageTopicOrServerNameOrServerDescriptionOrChannelNamesContainDisallowedWords:
      return "Discord's safety filter blocked this content."
    case .triedToPerformOperationOnArchivedThread:
      return "This thread is archived. Reopen it before trying again."
    case .cannotSendMessagesToThisUser:
      return "This person isn't accepting messages from you."
    case .unknownMessage:
      return "This message is no longer available."
    case .fileUploadedExceedsMaxSize:
      return "This file is larger than your current Discord upload limit."
    case .maxNumberOfAttachmentsInMessageReached:
      return "This message has too many attachments."
    case .tagRequiredToCreateForumPostInChannel:
      return "Choose a tag before creating this forum post."
    default:
      switch status {
      case 401: return "Your session expired. Please sign in again."
      case 403: return failure?.detailedMessage ?? "You don't have permission to do that."
      case 429: return "Discord is rate limiting requests. Please try again shortly."
      default: return failure?.detailedMessage ?? "Discord request failed (\(status))."
      }
    }
  }

  public struct ClientError: LocalizedError {
    public let status: Int
    public let message: String
    public var errorDescription: String? { message }
  }
}
