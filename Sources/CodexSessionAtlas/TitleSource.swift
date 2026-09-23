import Foundation
import SessionAtlasCore

final class CodexAppServerTitleSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codex-agent-monitor.app-server")
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var initialized = false
    private var cursor: String?
    private var collectedTitles: [String: String] = [:]
    private var requestState = AppServerRequestState()
    private var timeoutWorkItem: DispatchWorkItem?
    private var initializeRequestID: Int?
    private var refreshPending = false
    private var completion: (@Sendable ([String: String]) -> Void)?

    func refresh(completion: @escaping @Sendable ([String: String]) -> Void) {
        queue.async {
            self.completion = completion
            self.cursor = nil
            self.collectedTitles = [:]
            self.refreshPending = true
            self.startIfNeeded()
            self.requestTitlesIfReady()
        }
    }

    deinit {
        timeoutWorkItem?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
    }

    private func startIfNeeded() {
        guard process?.isRunning != true, let executable = executableURL() else {
            if process?.isRunning != true { finish(with: [:]) }
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [
            "app-server", "--listen", "stdio://",
            "--disable", "plugins", "--disable", "remote_plugin", "--disable", "apps",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.queue.async { self.consume(data) }
        }
        let processIdentifier = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.process.map({ ObjectIdentifier($0) }) == processIdentifier else { return }
                self.failCurrentProcess(terminate: false)
            }
        }

        do {
            self.process = process
            self.input = input
            self.output = output
            try process.run()
            guard let requestID = requestState.startNext() else {
                failCurrentProcess()
                return
            }
            initializeRequestID = requestID
            armTimeout(for: requestID)
            send([
                "id": requestID,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-session-atlas",
                        "title": "Codex Session Atlas",
                        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.8.0",
                    ],
                    "capabilities": ["experimentalApi": true],
                ],
            ])
        } catch {
            failCurrentProcess(terminate: false)
        }
    }

    private func requestTitlesIfReady() {
        guard initialized, refreshPending, requestState.requestID == nil else { return }
        refreshPending = false
        guard let requestID = requestState.startNext() else { return }
        armTimeout(for: requestID)
        send([
            "id": requestID,
            "method": "thread/list",
            "params": [
                "archived": false,
                "limit": 200,
                "cursor": cursor as Any? ?? NSNull(),
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "useStateDbOnly": true,
                "sourceKinds": [
                    "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
                    "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown",
                ],
            ],
        ])
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let id = object["id"] as? Int
            else { continue }

            if id == initializeRequestID {
                guard requestState.finish(id) else { continue }
                initializeRequestID = nil
                cancelTimeout()
                guard object["result"] != nil else {
                    failCurrentProcess()
                    continue
                }
                initialized = true
                send(["method": "initialized"])
                requestTitlesIfReady()
                continue
            }

            guard requestState.finish(id) else { continue }
            cancelTimeout()
            refreshPending = false
            let threads = (object["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            var titles = collectedTitles
            for thread in threads {
                guard let id = thread["id"] as? String else { continue }
                titles[id] = CodexRuntimeTitle.resolve(
                    threadID: id,
                    name: thread["name"] as? String,
                    preview: thread["preview"] as? String
                )
            }
            collectedTitles = titles
            if let next = (object["result"] as? [String: Any])?["nextCursor"] as? String {
                cursor = next; refreshPending = true; requestTitlesIfReady()
            } else {
                cursor = nil; finish(with: titles)
            }
        }
    }

    private func armTimeout(for requestID: Int) {
        cancelTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.requestState.expire(requestID) else { return }
            self.timeoutWorkItem = nil
            self.failCurrentProcess()
        }
        timeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    private func failCurrentProcess(terminate: Bool = true) {
        cancelTimeout()
        requestState.reset()
        initializeRequestID = nil
        initialized = false
        refreshPending = false
        buffer.removeAll(keepingCapacity: true)
        output?.fileHandleForReading.readabilityHandler = nil
        let process = process
        self.process = nil
        input = nil
        output = nil
        finish(with: [:])
        if terminate, process?.isRunning == true { process?.terminate() }
    }

    private func finish(with titles: [String: String]) {
        let completion = completion
        self.completion = nil
        completion?(titles)
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        try? input?.fileHandleForWriting.write(contentsOf: data)
    }

    private func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map(URL.init(fileURLWithPath:))
    }
}

