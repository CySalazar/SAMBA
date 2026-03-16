import Testing
@testable import SMBMountManager

struct MountDiagnosticsTests {
    @Test
    func redactsPasswordInDoubleSlashSMBMountTarget() {
        let rawValue = "mount failed for //alice:secret123@nas.local/Share"

        let redactedValue = MountDiagnostics.redactSensitiveValue(in: rawValue)

        #expect(redactedValue == "mount failed for //alice:<redacted>@nas.local/Share")
    }

    @Test
    func redactsPasswordInSMBURL() {
        let rawValue = "mount failed for smb://alice:secret123@nas.local/Share"

        let redactedValue = MountDiagnostics.redactSensitiveValue(in: rawValue)

        #expect(redactedValue == "mount failed for smb://alice:<redacted>@nas.local/Share")
    }

    @Test
    func leavesNonSensitiveErrorsUnchanged() {
        let rawValue = "Authentication failed"

        let redactedValue = MountDiagnostics.redactSensitiveValue(in: rawValue)

        #expect(redactedValue == rawValue)
    }

    @Test
    func mapsAuthenticationFailureToUserFacingMessage() {
        let message = MountDiagnostics.userFacingMountError(from: "session setup failed: AUTHENTICATION ERROR", exitCode: 77)

        #expect(message == "Authentication failed. Check username and password.")
    }

    @Test
    func fallsBackToExitCodeWhenErrorMessageIsMissing() {
        let message = MountDiagnostics.userFacingMountError(from: nil, exitCode: 13)

        #expect(message == "Mount failed (exit code 13).")
    }
}
