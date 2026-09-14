import DiscordModels

public struct MessageSearchQuery: Sendable {
  public var offset: Int
  public var limit: Int
  public var content: String?
  public var channelID: ChannelSnowflake?
  public var authorID: UserSnowflake?
  public var mentions: String?
  public var authorType: String?
  public var contentType: String?
  public var minimumMessageID: MessageSnowflake?
  public var sortBy: String
  public var sortOrder: String

  public init(
    offset: Int = 0,
    limit: Int = 25,
    content: String? = nil,
    channelID: ChannelSnowflake? = nil,
    authorID: UserSnowflake? = nil,
    mentions: String? = nil,
    authorType: String? = nil,
    contentType: String? = nil,
    minimumMessageID: MessageSnowflake? = nil,
    sortBy: String = "timestamp",
    sortOrder: String = "desc"
  ) {
    self.offset = offset
    self.limit = limit
    self.content = content
    self.channelID = channelID
    self.authorID = authorID
    self.mentions = mentions
    self.authorType = authorType
    self.contentType = contentType
    self.minimumMessageID = minimumMessageID
    self.sortBy = sortBy
    self.sortOrder = sortOrder
  }

  var queries: [(String, String?)] {
    [
      ("offset", String(max(0, offset))),
      ("limit", String(min(max(1, limit), 25))),
      ("content", content),
      ("channel_id", channelID?.rawValue),
      ("author_id", authorID?.rawValue),
      ("mentions", mentions),
      ("author_type", authorType),
      ("has", contentType),
      ("min_id", minimumMessageID?.rawValue),
      ("sort_by", sortBy),
      ("sort_order", sortOrder),
    ]
  }
}

public struct ThreadSearchQuery: Sendable {
  public var archived: Bool
  public var offset: Int
  public var limit: Int
  public var name: String?
  public var tagIDs: [ForumTagSnowflake]
  public var matchAllTags: Bool
  public var sortBy: String

  public init(
    archived: Bool,
    offset: Int = 0,
    limit: Int = 25,
    name: String? = nil,
    tagIDs: [ForumTagSnowflake] = [],
    matchAllTags: Bool = false,
    sortBy: String = "last_message_time"
  ) {
    self.archived = archived
    self.offset = offset
    self.limit = limit
    self.name = name
    self.tagIDs = tagIDs
    self.matchAllTags = matchAllTags
    self.sortBy = sortBy
  }

  var queries: [(String, String?)] {
    [
      ("archived", String(archived)),
      ("offset", String(max(0, offset))),
      ("limit", String(min(max(1, limit), 25))),
      ("name", name),
      ("tag_setting", matchAllTags ? "match_all" : "match_some"),
      ("sort_by", sortBy),
      ("sort_order", "desc"),
    ] + tagIDs.map { ("tag", $0.rawValue) }
  }
}

extension DiscordClient {
  public func searchChannelMessages(
    channelID: ChannelSnowflake,
    query: MessageSearchQuery
  ) async throws -> DiscordClientResponse<Responses.SearchMessages> {
    try await send(
      request: .init(
        to: UserAPIEndpoint.messaging(.searchChannelMessages(channelId: channelID)),
        queries: query.queries
      )
    )
  }

  public func searchGuildMessages(
    guildID: GuildSnowflake,
    query: MessageSearchQuery
  ) async throws -> DiscordClientResponse<Responses.SearchMessages> {
    try await send(
      request: .init(
        to: UserAPIEndpoint.messaging(.searchGuildMessages(guildId: guildID)),
        queries: query.queries
      )
    )
  }

  public func searchThreads(
    channelID: ChannelSnowflake,
    query: ThreadSearchQuery
  ) async throws -> DiscordClientResponse<Responses.SearchThreads> {
    try await send(
      request: .init(
        to: UserAPIEndpoint.messaging(.searchThreads(channelId: channelID)),
        queries: query.queries
      )
    )
  }

  public func updateUserGuildSettings(
    guildID: GuildSnowflake,
    payload: Payloads.UpdateUserGuildSettings
  ) async throws -> DiscordClientResponse<DiscordModels.Guild.UserGuildSettings> {
    try await send(
      request: .init(to: UserAPIEndpoint.messaging(.updateGuildSettings(guildId: guildID))),
      payload: payload
    )
  }
}
