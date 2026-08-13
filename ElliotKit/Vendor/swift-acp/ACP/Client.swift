//
//  Client.swift
//  ACP
//
//  Actor-based ACP agent subprocess manager
//

import ACPModel
import Foundation
import os.log

// MARK: - Debug Message Types

public enum DebugMessageDirection: Sendable {
    case outgoing
    case incoming
}

public struct DebugMessage: Sendable {
    public let direction: DebugMessageDirection
    public let timestamp: Date
    public let rawData: Data
    public let method: String?

    public var jsonString: String? {
        String(data: rawData, encoding: .utf8)
    }
}

public actor Client {
    // MARK: - Properties

    private let logger = Logger.forCategory("Client")

    /// The connection to the agent. Vendored change: upstream held an `ACPProcessManager` here and
    /// spawned its own child. Elliot supplies a `Transport` over `ChildProcess` instead, because
    /// this package has exactly one thing that starts a child.
    private let transport: any Transport
    private let requestRouter: ACPRequestRouter
    private let errorHandler: ErrorHandler

    /// Drains `transport.messages` and dispatches each into `handleMessage`. Retained so `terminate()`
    /// can cancel it. `AsyncStream` is single-consumer — this task is the only iterator of
    /// `transport.messages`, and nothing else may consume it.
    private var readLoop: Task<Void, Never>?

    /// Whether a read loop is currently running.
    ///
    /// Vendored addition (#381). `internal`, and its only reader is
    /// `ClientTerminationTests.startReadLoopAfterTerminateIsANoOp`, which is the deterministic pin
    /// on the guard below: post-`terminate()` this must stay `false`. A test cannot read
    /// `readLoop` itself — it is `private` and staying that way, because widening it would also
    /// let a test *write* the one piece of state `terminate()`'s two branches are chosen by.
    var hasReadLoop: Bool { readLoop != nil }

    /// Set by `terminate()`. Read by `startReadLoop()`, which `init` defers into a `Task` and
    /// which can therefore run *after* a caller has already terminated — vendored fix (#381,
    /// criterion 4). Without it the loop starts on a dead transport and parks on a `messages`
    /// stream that will never yield.
    private var isTerminated = false

    /// How long a closed agent is given to flush before it is signalled.
    ///
    /// Two seconds, not fifteen: this is the window for a process that has been told to stop
    /// and has only bytes left to write.
    public static let defaultFlushGrace: Duration = .seconds(2)

    /// SIGTERM→SIGKILL grace, mirroring `ElliotProcess.ProcessTermination.hardKillGrace`
    /// (`.seconds(15)`). Restated rather than imported: `ACP` does not depend on
    /// `ElliotProcess`, and adding that edge to pick up one constant would invert the module
    /// order the whole vendoring rests on.
    public static let defaultEscalationGrace: Duration = .seconds(15)

    private let flushGrace: Duration
    private let escalationGrace: Duration

    private var pendingRequests: [RequestId: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var nextRequestId: Int = 1

    private let notificationContinuation: AsyncStream<JSONRPCNotification>.Continuation
    private let notificationStream: AsyncStream<JSONRPCNotification>

    private var debugContinuation: AsyncStream<DebugMessage>.Continuation?
    private var debugStream: AsyncStream<DebugMessage>?

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public weak var delegate: ClientDelegate?

    private enum TimeoutError: Error {
        case requestTimedOut
    }

    // MARK: - Initialization

    public init(
        transport: any Transport,
        flushGrace: Duration = Client.defaultFlushGrace,
        escalationGrace: Duration = Client.defaultEscalationGrace
    ) {
        self.transport = transport
        self.flushGrace = flushGrace
        self.escalationGrace = escalationGrace

        decoder = JSONDecoder()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        var continuation: AsyncStream<JSONRPCNotification>.Continuation!
        notificationStream = AsyncStream { cont in
            continuation = cont
        }
        notificationContinuation = continuation

        requestRouter = ACPRequestRouter(encoder: encoder, decoder: decoder)
        errorHandler = ErrorHandler(encoder: encoder)

        // Assigning `readLoop` directly here does not compile: the compiler rejects it with
        // "cannot access property 'readLoop' here in nonisolated initializer" at this point in this
        // initializer's body. `startReadLoop()` does not hit it — it is an ordinary actor method,
        // isolated by default — so the fix is to defer into it rather than to pin down exactly which
        // part of this initializer's shape trips the diagnostic. Deferring the loop's start by one
        // hop loses nothing, since `transport.messages` is `.unbounded`-buffered and holds whatever
        // arrives before a consumer starts pulling.
        Task { [weak self] in
            await self?.startReadLoop()
        }
    }

    /// Drains `transport.messages` into `handleMessage`, storing the `Task` in `readLoop` so
    /// `terminate()` can cancel it. Split out of `init` for the isolation reason explained there.
    ///
    /// `internal` rather than `private` — vendored change (#381). `init` is still the only
    /// production caller; the second one is a test, and it exists because the `isTerminated` guard
    /// below is otherwise **unreachable on purpose**. In production that guard fires only when
    /// `init`'s deferred `Task` lands after a caller has already terminated, which no test can
    /// arrange from outside: both hops go to this actor's serial executor and which arrives first
    /// is a race. Measured on this branch by deleting the guard — the whole suite stayed green,
    /// 8 filtered runs out of 8 and one full run of 2 798 tests. Calling this method directly
    /// after `terminate()` reproduces exactly the ordering the guard is written for, and nothing
    /// else does.
    func startReadLoop() {
        guard !isTerminated else { return }
        // Captured locally rather than read as `self.transport` inside the closure below, so the
        // loop does not hold `self` alive on its own — only the `[weak self]` calls it makes.
        let transport = self.transport
        readLoop = Task { [weak self] in
            for await message in transport.messages {
                await self?.handleMessage(data: message)
            }
            // The stream finishing is the agent going away. `handleTermination` is what fails every
            // in-flight request, so a caller is never left awaiting a reply that cannot come — see
            // its own doc comment for why that failure is `.connectionClosed` and not an invented
            // exit code.
            await self?.handleTermination()
        }
    }

    // MARK: - Public API

    public var notifications: AsyncStream<JSONRPCNotification> {
        notificationStream
    }

    public var debugMessages: AsyncStream<DebugMessage>? {
        debugStream
    }

    public func enableDebugStream() {
        guard debugStream == nil else { return }
        var continuation: AsyncStream<DebugMessage>.Continuation!
        debugStream = AsyncStream { cont in
            continuation = cont
        }
        debugContinuation = continuation
    }

    public func disableDebugStream() {
        debugContinuation?.finish()
        debugContinuation = nil
        debugStream = nil
    }

    // Vendored change: `processIdentifier()`, `processGroupIdentifier()`, `stderrLines()` and
    // `launch(...)` are deleted rather than forwarded onto `transport`. The caller constructs the
    // `Transport` — an `ACPTransport` over `ChildProcess` — and already has the process identifier,
    // the stderr accumulated in `collectedStderr()`, and the thing that spawned the child in the
    // first place. Re-exposing them here would be a second, narrower window onto state the owner
    // already holds directly.

    public func setDelegate(_ delegate: ClientDelegate?) {
        self.delegate = delegate
        Task {
            await requestRouter.setDelegate(delegate)
        }
    }

    public func initialize(
        protocolVersion: Int = 1,
        capabilities: ClientCapabilities,
        clientInfo: ClientInfo? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> InitializeResponse {
        let info =
            clientInfo
            ?? ClientInfo(
                name: "ACP",
                title: "ACP Client",
                version: "1.0.0"
            )

        let request = InitializeRequest(
            protocolVersion: protocolVersion,
            clientCapabilities: capabilities,
            clientInfo: info
        )

        let response = try await sendRequest(method: "initialize", params: request, timeout: timeout)

        guard let result = response.result else {
            if let error = response.error {
                throw ClientError.agentError(error)
            }
            throw ClientError.invalidResponse
        }

        let data = try encoder.encode(result)
        return try decoder.decode(InitializeResponse.self, from: data)
    }

    public func newSession(
        workingDirectory: String,
        additionalDirectories: [String]? = nil,
        mcpServers: [MCPServerConfig] = [],
        timeout: TimeInterval? = nil
    ) async throws -> NewSessionResponse {
        let request = NewSessionRequest(
            cwd: workingDirectory,
            additionalDirectories: additionalDirectories,
            mcpServers: mcpServers
        )

        let response = try await sendRequest(method: "session/new", params: request, timeout: timeout)

        guard let result = response.result else {
            if let error = response.error {
                throw ClientError.agentError(error)
            }
            throw ClientError.invalidResponse
        }

        let data = try encoder.encode(result)
        return try decoder.decode(NewSessionResponse.self, from: data)
    }

    public func sendPrompt(
        sessionId: SessionId,
        content: [ContentBlock]
    ) async throws -> SessionPromptResponse {
        let request = SessionPromptRequest(
            sessionId: sessionId,
            prompt: content
        )

        let response = try await sendRequest(method: "session/prompt", params: request, timeout: nil)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        let data = try encoder.encode(result)
        return try decoder.decode(SessionPromptResponse.self, from: data)
    }

    public func authenticate(
        authMethodId: String,
        credentials: [String: String]? = nil
    ) async throws -> AuthenticateResponse {
        let request = AuthenticateRequest(
            methodId: authMethodId,
            credentials: credentials
        )

        let response = try await sendRequest(method: "authenticate", params: request, timeout: nil)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        if response.result == nil || (response.result?.value is NSNull) {
            return AuthenticateResponse(success: true, error: nil)
        }

        if let dict = response.result?.value as? [String: Any], dict.isEmpty {
            return AuthenticateResponse(success: true, error: nil)
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        do {
            let data = try encoder.encode(result)
            return try decoder.decode(AuthenticateResponse.self, from: data)
        } catch {
            return AuthenticateResponse(success: true, error: nil)
        }
    }

    public func setMode(
        sessionId: SessionId,
        modeId: String
    ) async throws -> SetModeResponse {
        let request = SetModeRequest(
            sessionId: sessionId,
            modeId: modeId
        )

        let response = try await sendRequest(method: "session/set_mode", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        if response.result == nil || (response.result?.value is NSNull) {
            return SetModeResponse()
        }

        if let dict = response.result?.value as? [String: Any], dict.isEmpty {
            return SetModeResponse()
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        do {
            let data = try encoder.encode(result)
            return try decoder.decode(SetModeResponse.self, from: data)
        } catch {
            return SetModeResponse()
        }
    }

    public func setModel(
        sessionId: SessionId,
        modelId: String
    ) async throws -> SetModelResponse {
        let request = SetModelRequest(
            sessionId: sessionId,
            modelId: modelId
        )

        let response = try await sendRequest(method: "session/set_model", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        if response.result == nil || (response.result?.value is NSNull) {
            return SetModelResponse()
        }

        if let dict = response.result?.value as? [String: Any], dict.isEmpty {
            return SetModelResponse()
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        do {
            let data = try encoder.encode(result)
            return try decoder.decode(SetModelResponse.self, from: data)
        } catch {
            return SetModelResponse()
        }
    }

    public func setConfigOption(
        sessionId: SessionId,
        configId: SessionConfigId,
        value: SessionConfigValueId
    ) async throws -> SetSessionConfigOptionResponse {
        return try await setConfigOption(
            sessionId: sessionId,
            configId: configId,
            value: .select(value)
        )
    }

    public func setConfigOption(
        sessionId: SessionId,
        configId: SessionConfigId,
        value: Bool
    ) async throws -> SetSessionConfigOptionResponse {
        return try await setConfigOption(
            sessionId: sessionId,
            configId: configId,
            value: .boolean(value)
        )
    }

    public func setConfigOption(
        sessionId: SessionId,
        configId: SessionConfigId,
        value: SessionConfigOptionValue
    ) async throws -> SetSessionConfigOptionResponse {
        let request = SetSessionConfigOptionRequest(
            sessionId: sessionId,
            configId: configId,
            value: value
        )

        let response = try await sendRequest(method: "session/set_config_option", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        let data = try encoder.encode(result)
        return try decoder.decode(SetSessionConfigOptionResponse.self, from: data)
    }

    public func cancelSession(sessionId: SessionId) async throws {
        try await sendCancelNotification(sessionId: sessionId)
    }

    public func loadSession(
        sessionId: SessionId,
        cwd: String,
        additionalDirectories: [String]? = nil,
        mcpServers: [MCPServerConfig] = []
    ) async throws -> LoadSessionResponse {
        let request = LoadSessionRequest(
            sessionId: sessionId,
            cwd: cwd,
            additionalDirectories: additionalDirectories,
            mcpServers: mcpServers
        )

        let response = try await sendRequest(method: "session/load", params: request)

        if let error = response.error {
            if isSessionAlreadyActive(error) {
                return LoadSessionResponse(sessionId: sessionId, modes: nil, models: nil, configOptions: nil)
            }
            throw ClientError.agentError(error)
        }

        let extractedSessionId = extractSessionId(from: response.result)

        guard let result = response.result else {
            return LoadSessionResponse(
                sessionId: extractedSessionId,
                modes: nil,
                models: nil,
                configOptions: nil
            )
        }

        let data = try encoder.encode(result)
        if let payload = try? decoder.decode(LoadSessionResponsePayload.self, from: data) {
            return LoadSessionResponse(
                sessionId: payload.sessionId ?? extractedSessionId,
                modes: payload.modes,
                models: payload.models,
                configOptions: payload.configOptions
            )
        }

        if let decoded = try? decoder.decode(LoadSessionResponse.self, from: data) {
            return decoded
        }

        return LoadSessionResponse(
            sessionId: extractedSessionId,
            modes: nil,
            models: nil,
            configOptions: nil
        )
    }

    public func resumeSession(
        sessionId: SessionId,
        cwd: String,
        additionalDirectories: [String]? = nil,
        mcpServers: [MCPServerConfig] = []
    ) async throws -> ResumeSessionResponse {
        let request = ResumeSessionRequest(
            sessionId: sessionId,
            cwd: cwd,
            additionalDirectories: additionalDirectories,
            mcpServers: mcpServers
        )

        let response = try await sendRequest(method: "session/resume", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        return try decodeEmptyTolerantResponse(
            ResumeSessionResponse.self,
            from: response,
            emptyValue: ResumeSessionResponse()
        )
    }

    public func forkSession(
        sessionId: SessionId,
        cwd: String,
        additionalDirectories: [String]? = nil,
        mcpServers: [MCPServerConfig] = []
    ) async throws -> ForkSessionResponse {
        let request = ForkSessionRequest(
            sessionId: sessionId,
            cwd: cwd,
            additionalDirectories: additionalDirectories,
            mcpServers: mcpServers
        )

        let response = try await sendRequest(method: "session/fork", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        let data = try encoder.encode(result)
        return try decoder.decode(ForkSessionResponse.self, from: data)
    }

    public func listSessions(
        cwd: String? = nil,
        cursor: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ListSessionsResponse {
        let request = ListSessionsRequest(cwd: cwd, cursor: cursor)
        let response = try await sendRequest(method: "session/list", params: request, timeout: timeout)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        let data = try encoder.encode(result)
        return try decoder.decode(ListSessionsResponse.self, from: data)
    }

    public func closeSession(sessionId: SessionId) async throws -> CloseSessionResponse {
        let request = CloseSessionRequest(sessionId: sessionId)
        let response = try await sendRequest(method: "session/close", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        return try decodeEmptyTolerantResponse(
            CloseSessionResponse.self,
            from: response,
            emptyValue: CloseSessionResponse()
        )
    }

    public func deleteSession(sessionId: SessionId) async throws -> DeleteSessionResponse {
        let request = DeleteSessionRequest(sessionId: sessionId)
        let response = try await sendRequest(method: "session/delete", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        return try decodeEmptyTolerantResponse(
            DeleteSessionResponse.self,
            from: response,
            emptyValue: DeleteSessionResponse()
        )
    }

    public func logout() async throws -> LogoutResponse {
        let response = try await sendRequest(method: "logout", params: LogoutRequest())

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        return try decodeEmptyTolerantResponse(
            LogoutResponse.self,
            from: response,
            emptyValue: LogoutResponse()
        )
    }

    public func listProviders() async throws -> ListProvidersResponse {
        let response = try await sendRequest(method: "providers/list", params: ListProvidersRequest())

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        let data = try encoder.encode(result)
        return try decoder.decode(ListProvidersResponse.self, from: data)
    }

    public func setProvider(
        providerId: ProviderId,
        apiType: LlmProtocol,
        baseUrl: String,
        headers: [String: String]? = nil
    ) async throws -> SetProviderResponse {
        let request = SetProviderRequest(
            providerId: providerId,
            apiType: apiType,
            baseUrl: baseUrl,
            headers: headers
        )
        let response = try await sendRequest(method: "providers/set", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        return try decodeEmptyTolerantResponse(
            SetProviderResponse.self,
            from: response,
            emptyValue: SetProviderResponse()
        )
    }

    public func disableProvider(providerId: ProviderId) async throws -> DisableProviderResponse {
        let request = DisableProviderRequest(providerId: providerId)
        let response = try await sendRequest(method: "providers/disable", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        return try decodeEmptyTolerantResponse(
            DisableProviderResponse.self,
            from: response,
            emptyValue: DisableProviderResponse()
        )
    }

    public func startNes(
        workspaceUri: String? = nil,
        workspaceFolders: [WorkspaceFolder]? = nil,
        repository: NesRepository? = nil
    ) async throws -> StartNesResponse {
        let request = StartNesRequest(
            workspaceUri: workspaceUri,
            workspaceFolders: workspaceFolders,
            repository: repository
        )
        let response = try await sendRequest(method: "nes/start", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        let data = try encoder.encode(result)
        return try decoder.decode(StartNesResponse.self, from: data)
    }

    public func suggestNes(
        sessionId: SessionId,
        uri: String,
        version: Int64,
        position: TextPosition,
        selection: ACPModel.TextRange? = nil,
        triggerKind: NesTriggerKind,
        context: NesSuggestContext? = nil
    ) async throws -> SuggestNesResponse {
        let request = SuggestNesRequest(
            sessionId: sessionId,
            uri: uri,
            version: version,
            position: position,
            selection: selection,
            triggerKind: triggerKind,
            context: context
        )
        let response = try await sendRequest(method: "nes/suggest", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        let data = try encoder.encode(result)
        return try decoder.decode(SuggestNesResponse.self, from: data)
    }

    public func acceptNesSuggestion(sessionId: SessionId, id: String) async throws {
        try await sendNotification(
            method: "nes/accept",
            params: AcceptNesNotification(sessionId: sessionId, id: id)
        )
    }

    public func rejectNesSuggestion(
        sessionId: SessionId, id: String, reason: NesRejectReason? = nil
    ) async throws {
        try await sendNotification(
            method: "nes/reject",
            params: RejectNesNotification(sessionId: sessionId, id: id, reason: reason)
        )
    }

    public func closeNes(sessionId: SessionId) async throws -> CloseNesResponse {
        let request = CloseNesRequest(sessionId: sessionId)
        let response = try await sendRequest(method: "nes/close", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        return try decodeEmptyTolerantResponse(
            CloseNesResponse.self,
            from: response,
            emptyValue: CloseNesResponse()
        )
    }

    public func sendMcpMessage(
        connectionId: McpConnectionId,
        method: String,
        params: AnyCodable? = nil
    ) async throws -> MessageMcpResponse {
        let request = MessageMcpRequest(connectionId: connectionId, method: method, params: params)
        let response = try await sendRequest(method: "mcp/message", params: request)

        if let error = response.error {
            throw ClientError.agentError(error)
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        return result
    }

    public func sendMcpMessageNotification(
        connectionId: McpConnectionId,
        method: String,
        params: AnyCodable? = nil
    ) async throws {
        try await sendNotification(
            method: "mcp/message",
            params: MessageMcpNotification(connectionId: connectionId, method: method, params: params)
        )
    }

    public func didOpenDocument(
        sessionId: SessionId,
        uri: String,
        languageId: String,
        version: Int64,
        text: String
    ) async throws {
        try await sendNotification(
            method: "document/didOpen",
            params: DidOpenDocumentNotification(
                sessionId: sessionId,
                uri: uri,
                languageId: languageId,
                version: version,
                text: text
            )
        )
    }

    public func didChangeDocument(
        sessionId: SessionId,
        uri: String,
        version: Int64,
        contentChanges: [TextDocumentContentChangeEvent]
    ) async throws {
        try await sendNotification(
            method: "document/didChange",
            params: DidChangeDocumentNotification(
                sessionId: sessionId,
                uri: uri,
                version: version,
                contentChanges: contentChanges
            )
        )
    }

    public func didCloseDocument(sessionId: SessionId, uri: String) async throws {
        try await sendNotification(
            method: "document/didClose",
            params: DidCloseDocumentNotification(sessionId: sessionId, uri: uri)
        )
    }

    public func didSaveDocument(sessionId: SessionId, uri: String) async throws {
        try await sendNotification(
            method: "document/didSave",
            params: DidSaveDocumentNotification(sessionId: sessionId, uri: uri)
        )
    }

    public func didFocusDocument(
        sessionId: SessionId,
        uri: String,
        version: Int64,
        position: TextPosition,
        visibleRange: ACPModel.TextRange
    ) async throws {
        try await sendNotification(
            method: "document/didFocus",
            params: DidFocusDocumentNotification(
                sessionId: sessionId,
                uri: uri,
                version: version,
                position: position,
                visibleRange: visibleRange
            )
        )
    }

    private struct LoadSessionResponsePayload: Decodable {
        let sessionId: SessionId?
        let modes: ModesInfo?
        let models: ModelsInfo?
        let configOptions: [SessionConfigOption]?
    }

    private func extractSessionId(from result: AnyCodable?) -> SessionId? {
        guard let value = result?.value else { return nil }

        if let dict = value as? [String: Any] {
            if let id = dict["sessionId"] as? String ?? dict["session_id"] as? String {
                return SessionId(id)
            }
        }

        if let dict = value as? [String: AnyCodable] {
            if let id = dict["sessionId"]?.value as? String ?? dict["session_id"]?.value as? String {
                return SessionId(id)
            }
        }

        return nil
    }

    private func decodeEmptyTolerantResponse<T: Decodable>(
        _ type: T.Type,
        from response: JSONRPCResponse,
        emptyValue: @autoclosure () -> T
    ) throws -> T {
        if response.result == nil || (response.result?.value is NSNull) {
            return emptyValue()
        }

        if let dict = response.result?.value as? [String: Any], dict.isEmpty {
            return emptyValue()
        }

        guard let result = response.result else {
            throw ClientError.invalidResponse
        }

        let data = try encoder.encode(result)
        return try decoder.decode(type, from: data)
    }

    private func isSessionAlreadyActive(_ error: JSONRPCError) -> Bool {
        let message = error.message.lowercased()
        if message.contains("already active") || message.contains("already started")
            || message.contains("already exists")
        {
            return true
        }

        if let dataString = error.data?.value as? String {
            let lower = dataString.lowercased()
            if lower.contains("already active") || lower.contains("already started")
                || lower.contains("already exists")
            {
                return true
            }
        }

        if let data = error.data?.value as? [String: Any],
            let details = data["details"] as? String
        {
            let lower = details.lowercased()
            if lower.contains("already active") || lower.contains("already started")
                || lower.contains("already exists")
            {
                return true
            }
        }

        return false
    }

    public func sendRequest<T: Encodable>(
        method: String,
        params: T,
        timeout: TimeInterval? = nil
    ) async throws -> JSONRPCResponse {
        guard await transport.isConnected else {
            throw ClientError.processNotRunning
        }

        let requestId = RequestId.number(nextRequestId)
        nextRequestId += 1

        let paramsData = try encoder.encode(params)
        let paramsValue = try decoder.decode(AnyCodable.self, from: paramsData)

        let request = JSONRPCRequest(
            id: requestId,
            method: method,
            params: paramsValue
        )
        return try await withRequestTimeout(seconds: timeout, requestId: requestId) {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await self.registerRequest(id: requestId, continuation: continuation)

                    do {
                        try await self.writeMessageWithDebug(request, method: method)
                    } catch {
                        await self.failRequest(id: requestId, error: error)
                    }
                }
            }
        }
    }

    private func withRequestTimeout<T: Sendable>(
        seconds: TimeInterval?,
        requestId: RequestId,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let seconds = seconds else {
            return try await operation()
        }

        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await operation()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw TimeoutError.requestTimedOut
                }

                guard let result = try await group.next() else {
                    throw TimeoutError.requestTimedOut
                }
                group.cancelAll()
                return result
            }
        } catch is TimeoutError {
            pendingRequests.removeValue(forKey: requestId)
            throw ClientError.requestTimeout
        }
    }

    public func sendCancelNotification(sessionId: SessionId) async throws {
        guard await transport.isConnected else {
            throw ClientError.processNotRunning
        }

        struct CancelParams: Encodable {
            let sessionId: SessionId
        }

        let params = CancelParams(sessionId: sessionId)
        let paramsData = try encoder.encode(params)
        let paramsValue = try decoder.decode(AnyCodable.self, from: paramsData)

        let notification = JSONRPCNotification(
            method: "session/cancel",
            params: paramsValue
        )

        try await writeMessageWithDebug(notification, method: "session/cancel")
    }

    public func sendCancelRequest(requestId: RequestId) async throws {
        guard await transport.isConnected else {
            throw ClientError.processNotRunning
        }

        let params = CancelRequestNotification(requestId: requestId)
        let paramsData = try encoder.encode(params)
        let paramsValue = try decoder.decode(AnyCodable.self, from: paramsData)

        let notification = JSONRPCNotification(
            method: "$/cancel_request",
            params: paramsValue
        )

        try await writeMessageWithDebug(notification, method: "$/cancel_request")
    }

    private func sendNotification<T: Encodable>(method: String, params: T) async throws {
        guard await transport.isConnected else {
            throw ClientError.processNotRunning
        }

        let paramsData = try encoder.encode(params)
        let paramsValue = try decoder.decode(AnyCodable.self, from: paramsData)

        let notification = JSONRPCNotification(
            method: method,
            params: paramsValue
        )

        try await writeMessageWithDebug(notification, method: method)
    }

    public func terminate() async {
        isTerminated = true

        // ⛔ The escalation is ARMED BEFORE the wait, and disarmed by the wait succeeding —
        // never raced against it inside a task group.
        //
        // The obvious shape is `withTaskGroup { await readLoop.value } vs { sleep(flushGrace) }`
        // and it is a **deadlock in exactly the case this method exists for**. `withTaskGroup`
        // cannot return until every child has completed; `group.cancelAll()` asks and does not
        // evict; and `Task<Void, Never>.value` observes no cancellation at all. So for an agent
        // that ignores its stdin closing and keeps stdout open — the deaf agent, the only
        // reason there is an escalation — `messages` never finishes, `readLoop` never ends, the
        // group never returns, and `transport.terminate(...)` on the line after it is never
        // reached. `terminate()` hangs for ever instead of killing anything.
        //
        // `armKiller`'s doc comment (`ACPSessionTests.swift:50-56`) states the same three facts
        // about `withTimeout`, one layer up. This is the same trap wearing a task group.
        let deadline = Task { [transport, escalationGrace, flushGrace] in
            do { try await Task.sleep(for: flushGrace) } catch { return }
            // `do`/`catch`, never `try?`: `try?` swallows `CancellationError` and falls through,
            // which is how #380's killer fired instead of standing down.
            transport.terminate(hardKillAfter: escalationGrace)
        }

        // 1. Ask. A well-behaved agent exits when its stdin closes, having flushed whatever it
        //    still owed — `ACPTransport.close()`'s own doc comment says that is what closing
        //    exists to permit.
        await transport.close()

        // 2. Let the flush arrive. Upstream called `readLoop?.cancel()` in the very next
        //    statement and threw away exactly that flush (#381, criterion 2). The loop ends on
        //    its own when `messages` finishes, which is when the child's stdout closes, which
        //    is when the child exits — and when it does, the deadline above stands down.
        if let readLoop {
            await readLoop.value
            deadline.cancel()
        } else {
            // No loop ever started, so nothing can observe the close: escalate now rather than
            // wait out a grace window for a flush nobody is reading.
            deadline.cancel()
            transport.terminate(hardKillAfter: escalationGrace)
        }
        readLoop?.cancel()
        readLoop = nil

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ClientError.processNotRunning)
        }
        pendingRequests.removeAll()

        notificationContinuation.finish()
        debugContinuation?.finish()
        debugContinuation = nil
        debugStream = nil
    }

    // MARK: - Private Methods

    private func handleMessage(data: Data) async {
        guard let text = String(data: data, encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        if let continuation = debugContinuation {
            let method = extractMethod(from: data)
            continuation.yield(
                DebugMessage(
                    direction: .incoming,
                    timestamp: Date(),
                    rawData: data,
                    method: method
                ))
        }

        do {
            let message = try decoder.decode(Message.self, from: data)

            switch message {
            case .response(let response):
                await handleResponse(response)

            case .notification(let notification):
                notificationContinuation.yield(notification)
                await handleIncomingNotification(notification)

            case .request(let request):
                Task { [weak self] in
                    await self?.handleIncomingRequest(request)
                }
            }
        } catch {
            if let text = String(data: data, encoding: .utf8) {
                logger.warning(
                    "Failed to parse message: \(error.localizedDescription)\nData: \(text.prefix(500))")
            } else {
                logger.warning("Failed to parse message: \(error.localizedDescription)")
            }
        }
    }

    private func handleResponse(_ response: JSONRPCResponse) async {
        guard let continuation = pendingRequests.removeValue(forKey: response.id) else {
            let stillPending = pendingRequests.keys.map { String(describing: $0) }
            logger.warning(
                "Received response for unknown request id=\(response.id), no pending request found. Pending: \(stillPending)"
            )
            return
        }
        continuation.resume(returning: response)
    }

    private func handleIncomingRequest(_ request: JSONRPCRequest) async {
        do {
            let response = try await requestRouter.routeRequest(request)
            try await sendSuccessResponse(requestId: request.id, result: response)
        } catch {
            logger.error("Error handling request \(request.method): \(error.localizedDescription)")

            if let clientError = error as? ClientError, case .invalidResponse = clientError {
                try? await sendErrorResponse(
                    requestId: request.id,
                    code: -32601,
                    message: "Method not found: \(request.method)"
                )
            } else {
                try? await sendErrorResponse(
                    requestId: request.id,
                    code: -32603,
                    message: "Internal error: \(error.localizedDescription)"
                )
            }
        }
    }

    private func handleIncomingNotification(_ notification: JSONRPCNotification) async {
        do {
            try await requestRouter.routeNotification(notification)
        } catch {
            logger.warning(
                "Error handling notification \(notification.method): \(error.localizedDescription)")
        }
    }

    private func sendSuccessResponse(requestId: RequestId, result: AnyCodable) async throws {
        let response = JSONRPCResponse(id: requestId, result: result, error: nil)
        try await writeMessageWithDebug(response, method: nil)
    }

    private func sendErrorResponse(requestId: RequestId, code: Int, message: String) async throws {
        let errorResponse = try await errorHandler.createErrorResponse(
            requestId: requestId,
            code: code,
            message: message
        )
        try await writeMessageWithDebug(errorResponse, method: nil)
    }

    /// Fails every pending request and closes the notification stream, because the connection to
    /// the agent is gone — `transport.messages` finished, whether the agent exited or the transport
    /// was closed out from under a live request. No real exit code reaches this layer (the
    /// transport owns the child, and `.messages` finishing carries no payload saying why), so this
    /// resumes with `ClientError.connectionClosed` rather than inventing one: `.processFailed` and
    /// its `Int32` would report a fabricated "exit code 0" through `LocalizedError`, reading as a
    /// clean exit for an agent that may have crashed. The real code, when there is a child at all,
    /// reaches whoever owns the transport through `ACPTransport.waitForExit()`.
    private func handleTermination() async {
        logger.info("Agent connection closed")

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ClientError.connectionClosed)
        }
        pendingRequests.removeAll()

        notificationContinuation.finish()
    }

    private func registerRequest(
        id: RequestId,
        continuation: CheckedContinuation<JSONRPCResponse, Error>
    ) async {
        pendingRequests[id] = continuation
    }

    private func failRequest(id: RequestId, error: Error) async {
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func extractMethod(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["method"] as? String
    }

    private func writeMessageWithDebug<T: Encodable & Sendable>(
        _ message: T, method: String? = nil
    )
        async throws
    {
        if let continuation = debugContinuation {
            if let data = try? encoder.encode(message) {
                continuation.yield(
                    DebugMessage(
                        direction: .outgoing,
                        timestamp: Date(),
                        rawData: data,
                        method: method
                    ))
            }
        }
        // `writeMessage` took a model object and encoded it itself; `transport.send` takes `Data`,
        // so the encode moves here, onto the encoder the client already holds.
        try await transport.send(encoder.encode(message))
    }
}

// MARK: - Typealiases for backward compatibility

@available(*, deprecated, renamed: "Client")
public typealias ACPClient = Client
