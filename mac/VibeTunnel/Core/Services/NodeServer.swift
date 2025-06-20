//
//  NodeServer.swift
//  VibeTunnel
//
//  Created by Claude on 2025-06-20.
//

import Foundation
import OSLog

/// Node.js vibetunnel server implementation.
///
/// Manages the Node.js-based vibetunnel server as a subprocess. This implementation
/// provides feature parity with the original VibeTunnel implementation by using the
/// same Node.js codebase. It handles process lifecycle, log streaming, and error recovery.
@MainActor
final class NodeServer: BaseProcessServer {
    override var serverType: ServerType { .node }
    
    init() {
        super.init(loggerCategory: "NodeServer")
    }
    
    override func start() async throws {
        guard !isRunning else {
            logger.warning("Node server already running")
            return
        }
        
        guard !port.isEmpty else {
            let error = ServerError.invalidConfiguration("Port not configured")
            logger.error("Port not configured")
            logContinuation?.yield(ServerLogEntry(level: .error, message: error.localizedDescription))
            throw error
        }
        
        logger.info("Starting Node.js vibetunnel server on port \(self.port)")
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Initializing Node.js vibetunnel server..."
        ))
        
        // Check for Bun executable first
        if let bunExecutablePath = getBunExecutablePath() {
            // Use Bun executable
            logger.info("Using Bun executable")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bunExecutablePath)
            
            // No arguments needed for the standalone Bun executable
            process.arguments = []
            
            // Set working directory to server directory if available
            if let serverPath = getNodeServerPath() {
                process.currentDirectoryURL = URL(fileURLWithPath: serverPath)
                logger.info("Working directory: \(serverPath)")
            }
            
            setupProcessEnvironment(process)
            setupProcessPipes(process)
            
            try await launchProcess(process)
            return
        }
        
        // Fallback to Node.js
        guard let nodePath = getNodePath() else {
            let error = ServerError.binaryNotFound("Node.js runtime or Bun executable")
            logger.error("Neither Bun executable nor Node.js runtime found")
            logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Server runtime not available. Please ensure Node.js support is installed."
            ))
            throw error
        }
        
        guard let serverPath = getNodeServerPath() else {
            let error = ServerError.binaryNotFound("Node.js server bundle")
            logger.error("Node.js server bundle not found")
            logContinuation?.yield(ServerLogEntry(level: .error, message: error.localizedDescription))
            throw error
        }
        
        // Create the process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        
        // Set working directory to server directory
        process.currentDirectoryURL = URL(fileURLWithPath: serverPath)
        logger.info("Working directory: \(serverPath)")
        
        // Set arguments: node server.js (top-level launcher script)
        let serverScript = URL(fileURLWithPath: serverPath).appendingPathComponent("server.js").path
        process.arguments = [serverScript]
        
        setupProcessEnvironment(process)
        setupProcessPipes(process)
        
        try await launchProcess(process)
    }
    
    override func getStaticFilesPath() -> String? {
        guard let serverPath = getNodeServerPath() else { return nil }
        return URL(fileURLWithPath: serverPath).appendingPathComponent("public").path
    }
    
    // MARK: - Private Methods
    
    private func getBunExecutablePath() -> String? {
        // Check for bundled Bun executable
        if let bundledPath = Bundle.main.path(forResource: "vibetunnel", ofType: nil) {
            // Check if native modules are in the same directory
            let executableDir = URL(fileURLWithPath: bundledPath).deletingLastPathComponent()
            let ptyPath = executableDir.appendingPathComponent("pty.node").path
            let spawnHelperPath = executableDir.appendingPathComponent("spawn-helper").path
            
            if FileManager.default.fileExists(atPath: ptyPath) &&
               FileManager.default.fileExists(atPath: spawnHelperPath) {
                return bundledPath
            } else {
                logger.warning("Bun executable found but native modules missing")
                // Native modules might need to be copied or we fall back to Node.js
                return nil
            }
        }
        return nil
    }
    
    private func getNodePath() -> String? {
        // First check for bundled Node.js runtime
        if let bundledPath = Bundle.main.path(forResource: "node", ofType: nil, inDirectory: "node") {
            return bundledPath
        }
        
        return nil
    }
    
    private func getNodeServerPath() -> String? {
        // Check for bundled server
        guard let resourcesPath = Bundle.main.resourcePath else { return nil }
        let serverPath = URL(fileURLWithPath: resourcesPath).appendingPathComponent("node-server").path
        
        if FileManager.default.fileExists(atPath: serverPath) {
            return serverPath
        }
        
        return nil
    }
    
    private func setupProcessEnvironment(_ process: Process) {
        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = port
        environment["HOST"] = bindAddress
        environment["NODE_ENV"] = "production"
        
        // Add node modules path if we have a server directory
        if let serverPath = getNodeServerPath() {
            let nodeModulesPath = URL(fileURLWithPath: serverPath).appendingPathComponent("node_modules").path
            environment["NODE_PATH"] = nodeModulesPath
        }
        
        // For node-pty support
        if let resourcesPath = Bundle.main.resourcePath {
            environment["VIBETUNNEL_RESOURCES_PATH"] = resourcesPath
        }
        
        process.environment = environment
    }
    
    private func setupProcessPipes(_ process: Process) {
        // Setup stdout pipe
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        self.stdoutPipe = stdoutPipe
        
        // Setup stderr pipe
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        self.stderrPipe = stderrPipe
        
        // Start output monitoring before launching process
        super.startOutputMonitoring()
    }
    
    private func launchProcess(_ process: Process) async throws {
        do {
            try await processHandler.runProcess(process)
            self.process = process
            
            isRunning = true
            logger.info("Node.js server started successfully on port \(self.port)")
            logContinuation?.yield(ServerLogEntry(
                level: .info,
                message: "Node.js vibetunnel server ready on port \(self.port)"
            ))
            
            // Monitor process termination
            Task {
                await monitorProcessTermination()
            }
        } catch {
            // Clean up pipes on error
            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            outputTask?.cancel()
            errorTask?.cancel()
            
            logger.error("Failed to start Node.js server: \(error)")
            logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Failed to start Node.js server: \(error.localizedDescription)"
            ))
            throw error
        }
    }
    
    private func monitorProcessTermination() async {
        guard let process else { return }

        // Wait for process exit on background thread
        await processHandler.waitForExit(process)

        if self.isRunning {
            // Unexpected termination
            let exitCode = process.terminationStatus
            self.logger.error("Node.js server terminated unexpectedly with exit code: \(exitCode)")
            self.logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Server terminated unexpectedly with exit code: \(exitCode)"
            ))

            self.isRunning = false

            // Auto-restart on unexpected termination
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.process == nil { // Only restart if not manually stopped
                    self.logger.info("Auto-restarting Node.js server after crash")
                    self.logContinuation?.yield(ServerLogEntry(
                        level: .info,
                        message: "Auto-restarting server after crash"
                    ))
                    try? await self.start()
                }
            }
        }
    }
    
}

// MARK: - Node.js Server Errors

enum NodeServerError: LocalizedError {
    case nodeNotInstalled
    case serverBundleNotFound
    case invalidPort
    
    var errorDescription: String? {
        switch self {
        case .nodeNotInstalled:
            return "Node.js runtime is not installed or not found"
        case .serverBundleNotFound:
            return "Node.js server bundle not found in app resources"
        case .invalidPort:
            return "Invalid or missing port configuration"
        }
    }
}
