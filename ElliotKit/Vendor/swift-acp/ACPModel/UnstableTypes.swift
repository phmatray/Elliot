//
//  UnstableTypes.swift
//  ACPModel
//
//  Draft ACP extension types mirrored from upstream SDKs.
//

import Foundation

// MARK: - Raw String Identifiers

public struct ProviderId: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct LlmProtocol: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String

    public static let anthropic = Self("anthropic")
    public static let openai = Self("openai")
    public static let azure = Self("azure")
    public static let vertex = Self("vertex")
    public static let bedrock = Self("bedrock")

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct McpServerAcpId: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct McpConnectionId: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ElicitationId: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct PositionEncodingKind: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String

    public static let utf16 = Self("utf-16")
    public static let utf32 = Self("utf-32")
    public static let utf8 = Self("utf-8")

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - Providers

public struct ProviderCurrentConfig: Codable, Sendable {
    public let apiType: LlmProtocol
    public let baseUrl: String
    public let _meta: [String: AnyCodable]?

    public init(apiType: LlmProtocol, baseUrl: String, _meta: [String: AnyCodable]? = nil) {
        self.apiType = apiType
        self.baseUrl = baseUrl
        self._meta = _meta
    }
}

public struct ProviderInfo: Codable, Sendable {
    public let providerId: ProviderId
    public let supported: [LlmProtocol]
    public let required: Bool
    public let current: ProviderCurrentConfig?
    public let _meta: [String: AnyCodable]?

    public init(
        providerId: ProviderId,
        supported: [LlmProtocol],
        required: Bool,
        current: ProviderCurrentConfig? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.providerId = providerId
        self.supported = supported
        self.required = required
        self.current = current
        self._meta = _meta
    }
}

public struct ListProvidersRequest: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct ListProvidersResponse: Codable, Sendable {
    public let providers: [ProviderInfo]
    public let _meta: [String: AnyCodable]?

    public init(providers: [ProviderInfo], _meta: [String: AnyCodable]? = nil) {
        self.providers = providers
        self._meta = _meta
    }
}

public struct SetProviderRequest: Codable, Sendable {
    public let providerId: ProviderId
    public let apiType: LlmProtocol
    public let baseUrl: String
    public let headers: [String: String]?
    public let _meta: [String: AnyCodable]?

    public init(
        providerId: ProviderId,
        apiType: LlmProtocol,
        baseUrl: String,
        headers: [String: String]? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.providerId = providerId
        self.apiType = apiType
        self.baseUrl = baseUrl
        self.headers = headers
        self._meta = _meta
    }
}

public struct SetProviderResponse: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct DisableProviderRequest: Codable, Sendable {
    public let providerId: ProviderId
    public let _meta: [String: AnyCodable]?

    public init(providerId: ProviderId, _meta: [String: AnyCodable]? = nil) {
        self.providerId = providerId
        self._meta = _meta
    }
}

public struct DisableProviderResponse: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

// MARK: - Session Fork

public struct ForkSessionRequest: Codable, Sendable {
    public let sessionId: SessionId
    public let cwd: String
    public let additionalDirectories: [String]?
    public let mcpServers: [MCPServerConfig]
    public let _meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case cwd
        case additionalDirectories
        case mcpServers
        case _meta
    }

    public init(
        sessionId: SessionId,
        cwd: String,
        additionalDirectories: [String]? = nil,
        mcpServers: [MCPServerConfig] = [],
        _meta: [String: AnyCodable]? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self._meta = _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(SessionId.self, forKey: .sessionId)
        cwd = try container.decode(String.self, forKey: .cwd)
        additionalDirectories = try container.decodeIfPresent([String].self, forKey: .additionalDirectories)
        mcpServers = try container.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers) ?? []
        _meta = try container.decodeIfPresent([String: AnyCodable].self, forKey: ._meta)
    }
}

public struct ForkSessionResponse: Codable, Sendable {
    public let sessionId: SessionId
    public let modes: ModesInfo?
    public let configOptions: [SessionConfigOption]?
    public let _meta: [String: AnyCodable]?

    public init(
        sessionId: SessionId,
        modes: ModesInfo? = nil,
        configOptions: [SessionConfigOption]? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.sessionId = sessionId
        self.modes = modes
        self.configOptions = configOptions
        self._meta = _meta
    }
}

// MARK: - MCP over ACP

public struct MCPAcpServerConfig: Codable, Sendable {
    public let name: String
    public let serverId: McpServerAcpId
    public let _meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case name
        case serverId
        case id
        case acpId
        case _meta
    }

    public init(name: String, serverId: McpServerAcpId, _meta: [String: AnyCodable]? = nil) {
        self.name = name
        self.serverId = serverId
        self._meta = _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        serverId =
            try container.decodeIfPresent(McpServerAcpId.self, forKey: .serverId)
            ?? container.decodeIfPresent(McpServerAcpId.self, forKey: .id)
            ?? container.decodeIfPresent(McpServerAcpId.self, forKey: .acpId)
            ?? {
                throw DecodingError.keyNotFound(
                    CodingKeys.serverId,
                    DecodingError.Context(
                        codingPath: decoder.codingPath, debugDescription: "Missing serverId"))
            }()
        _meta = try container.decodeIfPresent([String: AnyCodable].self, forKey: ._meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(serverId, forKey: .serverId)
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }
}

public struct ConnectMcpRequest: Codable, Sendable {
    public let serverId: McpServerAcpId
    public let _meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case serverId
        case acpId
        case _meta
    }

    public init(serverId: McpServerAcpId, _meta: [String: AnyCodable]? = nil) {
        self.serverId = serverId
        self._meta = _meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverId =
            try container.decodeIfPresent(McpServerAcpId.self, forKey: .serverId)
            ?? container.decodeIfPresent(McpServerAcpId.self, forKey: .acpId)
            ?? {
                throw DecodingError.keyNotFound(
                    CodingKeys.serverId,
                    DecodingError.Context(
                        codingPath: decoder.codingPath, debugDescription: "Missing serverId"))
            }()
        _meta = try container.decodeIfPresent([String: AnyCodable].self, forKey: ._meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverId, forKey: .serverId)
        try container.encodeIfPresent(_meta, forKey: ._meta)
    }
}

public struct ConnectMcpResponse: Codable, Sendable {
    public let connectionId: McpConnectionId
    public let _meta: [String: AnyCodable]?

    public init(connectionId: McpConnectionId, _meta: [String: AnyCodable]? = nil) {
        self.connectionId = connectionId
        self._meta = _meta
    }
}

public struct DisconnectMcpRequest: Codable, Sendable {
    public let connectionId: McpConnectionId
    public let _meta: [String: AnyCodable]?

    public init(connectionId: McpConnectionId, _meta: [String: AnyCodable]? = nil) {
        self.connectionId = connectionId
        self._meta = _meta
    }
}

public struct DisconnectMcpResponse: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct MessageMcpRequest: Codable, Sendable {
    public let connectionId: McpConnectionId
    public let method: String
    public let params: AnyCodable?
    public let _meta: [String: AnyCodable]?

    public init(
        connectionId: McpConnectionId,
        method: String,
        params: AnyCodable? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.connectionId = connectionId
        self.method = method
        self.params = params
        self._meta = _meta
    }
}

public typealias MessageMcpNotification = MessageMcpRequest
public typealias MessageMcpResponse = AnyCodable

// MARK: - Elicitation

public struct ElicitationSchema: Codable, Sendable {
    public let type: String?
    public let title: String?
    public let description: String?
    public let properties: [String: AnyCodable]?
    public let required: [String]?
    public let _meta: [String: AnyCodable]?

    public init(
        type: String? = "object",
        title: String? = nil,
        description: String? = nil,
        properties: [String: AnyCodable]? = nil,
        required: [String]? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.properties = properties
        self.required = required
        self._meta = _meta
    }
}

public struct CreateElicitationRequest: Codable, Sendable {
    public let mode: String
    public let message: String
    public let sessionId: SessionId?
    public let toolCallId: String?
    public let requestId: RequestId?
    public let requestedSchema: ElicitationSchema?
    public let elicitationId: ElicitationId?
    public let url: String?
    public let _meta: [String: AnyCodable]?

    public init(
        mode: String,
        message: String,
        sessionId: SessionId? = nil,
        toolCallId: String? = nil,
        requestId: RequestId? = nil,
        requestedSchema: ElicitationSchema? = nil,
        elicitationId: ElicitationId? = nil,
        url: String? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.mode = mode
        self.message = message
        self.sessionId = sessionId
        self.toolCallId = toolCallId
        self.requestId = requestId
        self.requestedSchema = requestedSchema
        self.elicitationId = elicitationId
        self.url = url
        self._meta = _meta
    }
}

public struct CreateElicitationResponse: Codable, Sendable {
    public let action: String
    public let content: [String: AnyCodable]?
    public let _meta: [String: AnyCodable]?

    public init(action: String, content: [String: AnyCodable]? = nil, _meta: [String: AnyCodable]? = nil) {
        self.action = action
        self.content = content
        self._meta = _meta
    }
}

public struct CompleteElicitationNotification: Codable, Sendable {
    public let elicitationId: ElicitationId
    public let _meta: [String: AnyCodable]?

    public init(elicitationId: ElicitationId, _meta: [String: AnyCodable]? = nil) {
        self.elicitationId = elicitationId
        self._meta = _meta
    }
}

// MARK: - NES and Document Events

public struct TextPosition: Codable, Hashable, Sendable {
    public let line: UInt32
    public let character: UInt32
    public let _meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case line
        case character
        case _meta
    }

    public static func == (lhs: TextPosition, rhs: TextPosition) -> Bool {
        lhs.line == rhs.line && lhs.character == rhs.character
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(line)
        hasher.combine(character)
    }

    public init(line: UInt32, character: UInt32, _meta: [String: AnyCodable]? = nil) {
        self.line = line
        self.character = character
        self._meta = _meta
    }
}

public struct TextRange: Codable, Hashable, Sendable {
    public let start: TextPosition
    public let end: TextPosition
    public let _meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case _meta
    }

    public static func == (lhs: TextRange, rhs: TextRange) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(start)
        hasher.combine(end)
    }

    public init(start: TextPosition, end: TextPosition, _meta: [String: AnyCodable]? = nil) {
        self.start = start
        self.end = end
        self._meta = _meta
    }
}

public struct WorkspaceFolder: Codable, Sendable {
    public let uri: String
    public let name: String
    public let _meta: [String: AnyCodable]?

    public init(uri: String, name: String, _meta: [String: AnyCodable]? = nil) {
        self.uri = uri
        self.name = name
        self._meta = _meta
    }
}

public struct NesRepository: Codable, Sendable {
    public let name: String
    public let owner: String
    public let remoteUrl: String
    public let _meta: [String: AnyCodable]?

    public init(name: String, owner: String, remoteUrl: String, _meta: [String: AnyCodable]? = nil) {
        self.name = name
        self.owner = owner
        self.remoteUrl = remoteUrl
        self._meta = _meta
    }
}

public struct NesTriggerKind: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String

    public static let automatic = Self("automatic")
    public static let diagnostic = Self("diagnostic")
    public static let manual = Self("manual")

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct NesRejectReason: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String

    public static let rejected = Self("rejected")
    public static let ignored = Self("ignored")
    public static let replaced = Self("replaced")
    public static let cancelled = Self("cancelled")

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum TextDocumentSyncKind: String, Codable, Sendable {
    case full
    case incremental
}

public struct NesTextEdit: Codable, Sendable {
    public let range: TextRange
    public let newText: String
    public let _meta: [String: AnyCodable]?

    public init(range: TextRange, newText: String, _meta: [String: AnyCodable]? = nil) {
        self.range = range
        self.newText = newText
        self._meta = _meta
    }
}

public struct NesExcerpt: Codable, Sendable {
    public let startLine: UInt32
    public let endLine: UInt32
    public let text: String
    public let _meta: [String: AnyCodable]?

    public init(startLine: UInt32, endLine: UInt32, text: String, _meta: [String: AnyCodable]? = nil) {
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
        self._meta = _meta
    }
}

public struct NesRecentFile: Codable, Sendable {
    public let uri: String
    public let languageId: String
    public let text: String
    public let _meta: [String: AnyCodable]?

    public init(uri: String, languageId: String, text: String, _meta: [String: AnyCodable]? = nil) {
        self.uri = uri
        self.languageId = languageId
        self.text = text
        self._meta = _meta
    }
}

public struct NesRelatedSnippet: Codable, Sendable {
    public let uri: String
    public let excerpts: [NesExcerpt]
    public let _meta: [String: AnyCodable]?

    public init(uri: String, excerpts: [NesExcerpt], _meta: [String: AnyCodable]? = nil) {
        self.uri = uri
        self.excerpts = excerpts
        self._meta = _meta
    }
}

public struct NesEditHistoryEntry: Codable, Sendable {
    public let uri: String
    public let diff: String
    public let _meta: [String: AnyCodable]?

    public init(uri: String, diff: String, _meta: [String: AnyCodable]? = nil) {
        self.uri = uri
        self.diff = diff
        self._meta = _meta
    }
}

public struct NesUserAction: Codable, Sendable {
    public let action: String
    public let uri: String
    public let position: TextPosition
    public let timestampMs: UInt64
    public let _meta: [String: AnyCodable]?

    public init(
        action: String,
        uri: String,
        position: TextPosition,
        timestampMs: UInt64,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.action = action
        self.uri = uri
        self.position = position
        self.timestampMs = timestampMs
        self._meta = _meta
    }
}

public struct NesOpenFile: Codable, Sendable {
    public let uri: String
    public let languageId: String
    public let visibleRange: TextRange?
    public let lastFocusedMs: UInt64?
    public let _meta: [String: AnyCodable]?

    public init(
        uri: String,
        languageId: String,
        visibleRange: TextRange? = nil,
        lastFocusedMs: UInt64? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.uri = uri
        self.languageId = languageId
        self.visibleRange = visibleRange
        self.lastFocusedMs = lastFocusedMs
        self._meta = _meta
    }
}

public struct NesDiagnosticSeverity: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let value: String

    public static let error = Self("error")
    public static let warning = Self("warning")
    public static let information = Self("information")
    public static let hint = Self("hint")

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct NesDiagnostic: Codable, Sendable {
    public let uri: String
    public let range: TextRange
    public let severity: NesDiagnosticSeverity
    public let message: String
    public let _meta: [String: AnyCodable]?

    public init(
        uri: String,
        range: TextRange,
        severity: NesDiagnosticSeverity,
        message: String,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.uri = uri
        self.range = range
        self.severity = severity
        self.message = message
        self._meta = _meta
    }
}

public struct NesSuggestContext: Codable, Sendable {
    public let recentFiles: [NesRecentFile]?
    public let relatedSnippets: [NesRelatedSnippet]?
    public let editHistory: [NesEditHistoryEntry]?
    public let userActions: [NesUserAction]?
    public let openFiles: [NesOpenFile]?
    public let diagnostics: [NesDiagnostic]?
    public let _meta: [String: AnyCodable]?

    public init(
        recentFiles: [NesRecentFile]? = nil,
        relatedSnippets: [NesRelatedSnippet]? = nil,
        editHistory: [NesEditHistoryEntry]? = nil,
        userActions: [NesUserAction]? = nil,
        openFiles: [NesOpenFile]? = nil,
        diagnostics: [NesDiagnostic]? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.recentFiles = recentFiles
        self.relatedSnippets = relatedSnippets
        self.editHistory = editHistory
        self.userActions = userActions
        self.openFiles = openFiles
        self.diagnostics = diagnostics
        self._meta = _meta
    }
}

public struct NesSuggestion: Codable, Sendable {
    public let kind: String
    public let id: String
    public let uri: String?
    public let edits: [NesTextEdit]?
    public let cursorPosition: TextPosition?
    public let position: TextPosition?
    public let newName: String?
    public let search: String?
    public let replace: String?
    public let isRegex: Bool?
    public let _meta: [String: AnyCodable]?

    public init(
        kind: String,
        id: String,
        uri: String? = nil,
        edits: [NesTextEdit]? = nil,
        cursorPosition: TextPosition? = nil,
        position: TextPosition? = nil,
        newName: String? = nil,
        search: String? = nil,
        replace: String? = nil,
        isRegex: Bool? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.kind = kind
        self.id = id
        self.uri = uri
        self.edits = edits
        self.cursorPosition = cursorPosition
        self.position = position
        self.newName = newName
        self.search = search
        self.replace = replace
        self.isRegex = isRegex
        self._meta = _meta
    }
}

public struct StartNesRequest: Codable, Sendable {
    public let workspaceUri: String?
    public let workspaceFolders: [WorkspaceFolder]?
    public let repository: NesRepository?
    public let _meta: [String: AnyCodable]?

    public init(
        workspaceUri: String? = nil,
        workspaceFolders: [WorkspaceFolder]? = nil,
        repository: NesRepository? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.workspaceUri = workspaceUri
        self.workspaceFolders = workspaceFolders
        self.repository = repository
        self._meta = _meta
    }
}

public struct StartNesResponse: Codable, Sendable {
    public let sessionId: SessionId
    public let _meta: [String: AnyCodable]?

    public init(sessionId: SessionId, _meta: [String: AnyCodable]? = nil) {
        self.sessionId = sessionId
        self._meta = _meta
    }
}

public struct SuggestNesRequest: Codable, Sendable {
    public let sessionId: SessionId
    public let uri: String
    public let version: Int64
    public let position: TextPosition
    public let selection: TextRange?
    public let triggerKind: NesTriggerKind
    public let context: NesSuggestContext?
    public let _meta: [String: AnyCodable]?

    public init(
        sessionId: SessionId,
        uri: String,
        version: Int64,
        position: TextPosition,
        selection: TextRange? = nil,
        triggerKind: NesTriggerKind,
        context: NesSuggestContext? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.sessionId = sessionId
        self.uri = uri
        self.version = version
        self.position = position
        self.selection = selection
        self.triggerKind = triggerKind
        self.context = context
        self._meta = _meta
    }
}

public struct SuggestNesResponse: Codable, Sendable {
    public let suggestions: [NesSuggestion]
    public let _meta: [String: AnyCodable]?

    public init(suggestions: [NesSuggestion], _meta: [String: AnyCodable]? = nil) {
        self.suggestions = suggestions
        self._meta = _meta
    }
}

public struct AcceptNesNotification: Codable, Sendable {
    public let sessionId: SessionId
    public let id: String
    public let _meta: [String: AnyCodable]?

    public init(sessionId: SessionId, id: String, _meta: [String: AnyCodable]? = nil) {
        self.sessionId = sessionId
        self.id = id
        self._meta = _meta
    }
}

public struct RejectNesNotification: Codable, Sendable {
    public let sessionId: SessionId
    public let id: String
    public let reason: NesRejectReason?
    public let _meta: [String: AnyCodable]?

    public init(
        sessionId: SessionId, id: String, reason: NesRejectReason? = nil, _meta: [String: AnyCodable]? = nil
    ) {
        self.sessionId = sessionId
        self.id = id
        self.reason = reason
        self._meta = _meta
    }
}

public struct CloseNesRequest: Codable, Sendable {
    public let sessionId: SessionId
    public let _meta: [String: AnyCodable]?

    public init(sessionId: SessionId, _meta: [String: AnyCodable]? = nil) {
        self.sessionId = sessionId
        self._meta = _meta
    }
}

public struct CloseNesResponse: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct TextDocumentContentChangeEvent: Codable, Sendable {
    public let range: TextRange?
    public let text: String
    public let _meta: [String: AnyCodable]?

    public init(range: TextRange? = nil, text: String, _meta: [String: AnyCodable]? = nil) {
        self.range = range
        self.text = text
        self._meta = _meta
    }
}

public struct DidOpenDocumentNotification: Codable, Sendable {
    public let sessionId: SessionId
    public let uri: String
    public let languageId: String
    public let version: Int64
    public let text: String
    public let _meta: [String: AnyCodable]?

    public init(
        sessionId: SessionId,
        uri: String,
        languageId: String,
        version: Int64,
        text: String,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.sessionId = sessionId
        self.uri = uri
        self.languageId = languageId
        self.version = version
        self.text = text
        self._meta = _meta
    }
}

public struct DidChangeDocumentNotification: Codable, Sendable {
    public let sessionId: SessionId
    public let uri: String
    public let version: Int64
    public let contentChanges: [TextDocumentContentChangeEvent]
    public let _meta: [String: AnyCodable]?

    public init(
        sessionId: SessionId,
        uri: String,
        version: Int64,
        contentChanges: [TextDocumentContentChangeEvent],
        _meta: [String: AnyCodable]? = nil
    ) {
        self.sessionId = sessionId
        self.uri = uri
        self.version = version
        self.contentChanges = contentChanges
        self._meta = _meta
    }
}

public struct DidCloseDocumentNotification: Codable, Sendable {
    public let sessionId: SessionId
    public let uri: String
    public let _meta: [String: AnyCodable]?

    public init(sessionId: SessionId, uri: String, _meta: [String: AnyCodable]? = nil) {
        self.sessionId = sessionId
        self.uri = uri
        self._meta = _meta
    }
}

public typealias DidSaveDocumentNotification = DidCloseDocumentNotification

public struct DidFocusDocumentNotification: Codable, Sendable {
    public let sessionId: SessionId
    public let uri: String
    public let version: Int64
    public let position: TextPosition
    public let visibleRange: TextRange
    public let _meta: [String: AnyCodable]?

    public init(
        sessionId: SessionId,
        uri: String,
        version: Int64,
        position: TextPosition,
        visibleRange: TextRange,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.sessionId = sessionId
        self.uri = uri
        self.version = version
        self.position = position
        self.visibleRange = visibleRange
        self._meta = _meta
    }
}
