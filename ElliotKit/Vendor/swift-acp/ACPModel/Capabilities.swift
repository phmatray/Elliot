//
//  Capabilities.swift
//  ACPModel
//
//  Agent Client Protocol - Capability Types
//

import Foundation

// MARK: - Client Capabilities

public struct ClientCapabilities: Codable, Sendable {
    public let fs: FileSystemCapabilities
    public let terminal: Bool
    public let meta: [String: AnyCodable]?
    public let session: ClientSessionCapabilities?
    public let plan: PlanCapabilities?
    public let auth: AuthCapabilities?
    public let elicitation: ElicitationCapabilities?
    public let nes: ClientNesCapabilities?
    public let positionEncodings: [PositionEncodingKind]?

    public init(
        fs: FileSystemCapabilities,
        terminal: Bool,
        meta: [String: AnyCodable]? = nil,
        session: ClientSessionCapabilities? = nil,
        plan: PlanCapabilities? = nil,
        auth: AuthCapabilities? = nil,
        elicitation: ElicitationCapabilities? = nil,
        nes: ClientNesCapabilities? = nil,
        positionEncodings: [PositionEncodingKind]? = nil
    ) {
        self.fs = fs
        self.terminal = terminal
        self.meta = meta
        self.session = session
        self.plan = plan
        self.auth = auth
        self.elicitation = elicitation
        self.nes = nes
        self.positionEncodings = positionEncodings
    }

    enum CodingKeys: String, CodingKey {
        case fs
        case terminal
        case meta = "_meta"
        case session
        case plan
        case auth
        case elicitation
        case nes
        case positionEncodings
    }
}

public struct FileSystemCapabilities: Codable, Sendable {
    public let readTextFile: Bool
    public let writeTextFile: Bool
    public let _meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case readTextFile
        case writeTextFile
        case _meta
    }

    public init(readTextFile: Bool, writeTextFile: Bool, _meta: [String: AnyCodable]? = nil) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self._meta = _meta
    }
}

// MARK: - Agent Capabilities

public struct AgentCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?
    public let auth: AgentAuthCapabilities?
    public let loadSession: Bool?
    public let mcpCapabilities: MCPCapabilities?
    public let nes: NesCapabilities?
    public let positionEncoding: PositionEncodingKind?
    public let promptCapabilities: PromptCapabilities?
    public let providers: ProvidersCapabilities?
    public let sessionCapabilities: SessionCapabilities?

    enum CodingKeys: String, CodingKey {
        case _meta
        case auth
        case loadSession
        case mcpCapabilities
        case nes
        case positionEncoding
        case promptCapabilities
        case providers
        case sessionCapabilities
    }

    public init(
        _meta: [String: AnyCodable]? = nil,
        auth: AgentAuthCapabilities? = nil,
        loadSession: Bool? = nil,
        mcpCapabilities: MCPCapabilities? = nil,
        nes: NesCapabilities? = nil,
        positionEncoding: PositionEncodingKind? = nil,
        promptCapabilities: PromptCapabilities? = nil,
        providers: ProvidersCapabilities? = nil,
        sessionCapabilities: SessionCapabilities? = nil
    ) {
        self._meta = _meta
        self.auth = auth
        self.loadSession = loadSession
        self.mcpCapabilities = mcpCapabilities
        self.nes = nes
        self.positionEncoding = positionEncoding
        self.promptCapabilities = promptCapabilities
        self.providers = providers
        self.sessionCapabilities = sessionCapabilities
    }
}

public struct AgentAuthCapabilities: Codable, Sendable {
    public let logout: LogoutCapabilities?
    public let _meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case logout
        case _meta
    }

    public init(logout: LogoutCapabilities? = nil, _meta: [String: AnyCodable]? = nil) {
        self.logout = logout
        self._meta = _meta
    }
}

public struct LogoutCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case _meta
    }

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct MCPCapabilities: Codable, Sendable {
    public let acp: Bool?
    public let http: Bool?
    public let sse: Bool?
    public let _meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case acp
        case http
        case sse
        case _meta
    }

    public init(acp: Bool? = nil, http: Bool? = nil, sse: Bool? = nil, _meta: [String: AnyCodable]? = nil) {
        self.acp = acp
        self.http = http
        self.sse = sse
        self._meta = _meta
    }
}

public struct PromptCapabilities: Codable, Sendable {
    public let audio: Bool?
    public let embeddedContext: Bool?
    public let image: Bool?
    public let _meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case audio
        case embeddedContext
        case image
        case _meta
    }

    public init(
        audio: Bool? = nil, embeddedContext: Bool? = nil, image: Bool? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.audio = audio
        self.embeddedContext = embeddedContext
        self.image = image
        self._meta = _meta
    }
}

public struct SessionCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?
    public let additionalDirectories: SessionAdditionalDirectoriesCapabilities?
    public let close: SessionCloseCapabilities?
    public let delete: SessionDeleteCapabilities?
    public let fork: SessionForkCapabilities?
    public let list: SessionListCapabilities?
    public let resume: SessionResumeCapabilities?

    public init(
        _meta: [String: AnyCodable]? = nil,
        additionalDirectories: SessionAdditionalDirectoriesCapabilities? = nil,
        close: SessionCloseCapabilities? = nil,
        delete: SessionDeleteCapabilities? = nil,
        fork: SessionForkCapabilities? = nil,
        list: SessionListCapabilities? = nil,
        resume: SessionResumeCapabilities? = nil
    ) {
        self._meta = _meta
        self.additionalDirectories = additionalDirectories
        self.close = close
        self.delete = delete
        self.fork = fork
        self.list = list
        self.resume = resume
    }
}

public struct SessionAdditionalDirectoriesCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct SessionCloseCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct SessionForkCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct SessionDeleteCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct SessionListCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct SessionResumeCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

// MARK: - Draft Client Capabilities

public struct ClientSessionCapabilities: Codable, Sendable {
    public let configOptions: SessionConfigOptionsCapabilities?
    public let _meta: [String: AnyCodable]?

    public init(configOptions: SessionConfigOptionsCapabilities? = nil, _meta: [String: AnyCodable]? = nil) {
        self.configOptions = configOptions
        self._meta = _meta
    }
}

public struct SessionConfigOptionsCapabilities: Codable, Sendable {
    public let boolean: BooleanConfigOptionCapabilities?
    public let _meta: [String: AnyCodable]?

    public init(boolean: BooleanConfigOptionCapabilities? = nil, _meta: [String: AnyCodable]? = nil) {
        self.boolean = boolean
        self._meta = _meta
    }
}

public struct BooleanConfigOptionCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct PlanCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct AuthCapabilities: Codable, Sendable {
    public let terminal: Bool?
    public let _meta: [String: AnyCodable]?

    public init(terminal: Bool? = nil, _meta: [String: AnyCodable]? = nil) {
        self.terminal = terminal
        self._meta = _meta
    }
}

public struct ElicitationCapabilities: Codable, Sendable {
    public let form: ElicitationFormCapabilities?
    public let url: ElicitationUrlCapabilities?
    public let _meta: [String: AnyCodable]?

    public init(
        form: ElicitationFormCapabilities? = nil,
        url: ElicitationUrlCapabilities? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.form = form
        self.url = url
        self._meta = _meta
    }
}

public struct ElicitationFormCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct ElicitationUrlCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct ClientNesCapabilities: Codable, Sendable {
    public let jump: NesJumpCapabilities?
    public let rename: NesRenameCapabilities?
    public let searchAndReplace: NesSearchAndReplaceCapabilities?
    public let _meta: [String: AnyCodable]?

    public init(
        jump: NesJumpCapabilities? = nil,
        rename: NesRenameCapabilities? = nil,
        searchAndReplace: NesSearchAndReplaceCapabilities? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.jump = jump
        self.rename = rename
        self.searchAndReplace = searchAndReplace
        self._meta = _meta
    }
}

public struct NesJumpCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct NesRenameCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct NesSearchAndReplaceCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

// MARK: - Draft Agent Capabilities

public struct ProvidersCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct NesCapabilities: Codable, Sendable {
    public let events: NesEventCapabilities?
    public let context: NesContextCapabilities?
    public let _meta: [String: AnyCodable]?

    public init(
        events: NesEventCapabilities? = nil,
        context: NesContextCapabilities? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.events = events
        self.context = context
        self._meta = _meta
    }
}

public struct NesEventCapabilities: Codable, Sendable {
    public let document: NesDocumentEventCapabilities?
    public let _meta: [String: AnyCodable]?

    public init(document: NesDocumentEventCapabilities? = nil, _meta: [String: AnyCodable]? = nil) {
        self.document = document
        self._meta = _meta
    }
}

public struct NesDocumentEventCapabilities: Codable, Sendable {
    public let didOpen: NesDocumentDidOpenCapabilities?
    public let didChange: NesDocumentDidChangeCapabilities?
    public let didClose: NesDocumentDidCloseCapabilities?
    public let didSave: NesDocumentDidSaveCapabilities?
    public let didFocus: NesDocumentDidFocusCapabilities?
    public let _meta: [String: AnyCodable]?

    public init(
        didOpen: NesDocumentDidOpenCapabilities? = nil,
        didChange: NesDocumentDidChangeCapabilities? = nil,
        didClose: NesDocumentDidCloseCapabilities? = nil,
        didSave: NesDocumentDidSaveCapabilities? = nil,
        didFocus: NesDocumentDidFocusCapabilities? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.didOpen = didOpen
        self.didChange = didChange
        self.didClose = didClose
        self.didSave = didSave
        self.didFocus = didFocus
        self._meta = _meta
    }
}

public struct NesDocumentDidOpenCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct NesDocumentDidChangeCapabilities: Codable, Sendable {
    public let syncKind: TextDocumentSyncKind
    public let _meta: [String: AnyCodable]?

    public init(syncKind: TextDocumentSyncKind, _meta: [String: AnyCodable]? = nil) {
        self.syncKind = syncKind
        self._meta = _meta
    }
}

public struct NesDocumentDidCloseCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct NesDocumentDidSaveCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct NesDocumentDidFocusCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct NesContextCapabilities: Codable, Sendable {
    public let recentFiles: NesRecentFilesCapabilities?
    public let relatedSnippets: NesRelatedSnippetsCapabilities?
    public let editHistory: NesEditHistoryCapabilities?
    public let userActions: NesUserActionsCapabilities?
    public let openFiles: NesOpenFilesCapabilities?
    public let diagnostics: NesDiagnosticsCapabilities?
    public let _meta: [String: AnyCodable]?

    public init(
        recentFiles: NesRecentFilesCapabilities? = nil,
        relatedSnippets: NesRelatedSnippetsCapabilities? = nil,
        editHistory: NesEditHistoryCapabilities? = nil,
        userActions: NesUserActionsCapabilities? = nil,
        openFiles: NesOpenFilesCapabilities? = nil,
        diagnostics: NesDiagnosticsCapabilities? = nil,
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

public struct NesRecentFilesCapabilities: Codable, Sendable {
    public let maxCount: UInt32?
    public let _meta: [String: AnyCodable]?

    public init(maxCount: UInt32? = nil, _meta: [String: AnyCodable]? = nil) {
        self.maxCount = maxCount
        self._meta = _meta
    }
}

public struct NesRelatedSnippetsCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct NesEditHistoryCapabilities: Codable, Sendable {
    public let maxCount: UInt32?
    public let _meta: [String: AnyCodable]?

    public init(maxCount: UInt32? = nil, _meta: [String: AnyCodable]? = nil) {
        self.maxCount = maxCount
        self._meta = _meta
    }
}

public struct NesUserActionsCapabilities: Codable, Sendable {
    public let maxCount: UInt32?
    public let _meta: [String: AnyCodable]?

    public init(maxCount: UInt32? = nil, _meta: [String: AnyCodable]? = nil) {
        self.maxCount = maxCount
        self._meta = _meta
    }
}

public struct NesOpenFilesCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}

public struct NesDiagnosticsCapabilities: Codable, Sendable {
    public let _meta: [String: AnyCodable]?

    public init(_meta: [String: AnyCodable]? = nil) {
        self._meta = _meta
    }
}
