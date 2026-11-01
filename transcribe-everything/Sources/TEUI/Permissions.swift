import AVFoundation
import CoreGraphics

public enum Permission: String, CaseIterable, Sendable { case microphone = "Microphone", screenRecording = "Screen Recording" }

@MainActor public protocol Permissions {
    func granted(_ p: Permission) -> Bool
    func request(_ p: Permission) async
}

/// System Audio Recording has no request API and no preflight (DECISIONS); Screen Recording is what per-app capture needs.
public struct SystemPermissions: Permissions {
    public nonisolated init() {}
    public func granted(_ p: Permission) -> Bool {
        switch p {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }
    public func request(_ p: Permission) async {
        switch p {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        }
    }
}
