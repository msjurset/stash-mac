import Foundation
import Testing

@testable import StashMac

@Suite("Failover and Dual-Key Tests")
struct FailoverTests {

    @Test func testFailoverPolicyEnum() {
        #expect(FailoverPolicy.allCases.count == 3)
        #expect(FailoverPolicy.prompt.rawValue == "prompt")
        #expect(FailoverPolicy.alwaysAllow.rawValue == "alwaysAllow")
        #expect(FailoverPolicy.neverAllow.rawValue == "neverAllow")
        #expect(!FailoverPolicy.prompt.displayName.isEmpty)
        #expect(!FailoverPolicy.alwaysAllow.displayName.isEmpty)
        #expect(!FailoverPolicy.neverAllow.displayName.isEmpty)
    }

    @Test @MainActor func testAIPrefsStorePaidKeyAndApproval() {
        let prefs = AIPrefsStore()
        prefs.setActiveProvider(.gemini)

        // Clean previous test defaults if any
        prefs.setPaidKey("AIzaSyTestPaidKey123")
        #expect(prefs.paidApiKey == "AIzaSyTestPaidKey123")
        #expect(prefs.hasPaidKey)

        // Test policy
        prefs.failoverPolicy = .prompt
        prefs.revokeFailoverApproval()
        #expect(!prefs.isFailoverApproved)
        #expect(prefs.remainingApprovalHours == 0)

        // Approve for 24h
        prefs.approveFailover(hours: 24)
        #expect(prefs.isFailoverApproved)
        #expect(prefs.remainingApprovalHours > 0)

        // Revoke approval
        prefs.revokeFailoverApproval()
        #expect(!prefs.isFailoverApproved)
        #expect(prefs.remainingApprovalHours == 0)

        // Always allow policy
        prefs.failoverPolicy = .alwaysAllow
        #expect(prefs.isFailoverApproved)

        // Never allow policy
        prefs.failoverPolicy = .neverAllow
        #expect(!prefs.isFailoverApproved)

        // Clean up
        prefs.setPaidKey("")
        prefs.failoverPolicy = .prompt
    }

    @Test func testParseFailoverErrorFromJSON() {
        let jsonOutput = """
        {"error":"failover_approval_required","operation":"identify","duration":24}
        """
        let parsed = StashCLI.parseFailoverError(from: jsonOutput)
        #expect(parsed != nil)
        if case .failoverRequired(let op, let dur) = parsed {
            #expect(op == "identify")
            #expect(dur == 24)
        } else {
            #expect(Bool(false), "Expected failoverRequired error")
        }
    }

    @Test func testParseFailoverErrorFromPlainText() {
        let text = "Error: failover approval required for identify, but running non-interactively."
        let parsed = StashCLI.parseFailoverError(from: text)
        #expect(parsed != nil)
        if case .failoverRequired(let op, _) = parsed {
            #expect(op == "identify")
        } else {
            #expect(Bool(false), "Expected failoverRequired error")
        }
    }

    @Test func testIsTransientIdentifyError() {
        // Failover errors are NOT transient — they must not be retried in a backoff loop
        let failoverErr = GeminiFailoverApprovalRequiredError(operation: "identify", durationHours: 24)
        #expect(!isTransientIdentifyError(failoverErr))

        let cliFailoverErr = CLIError.failoverRequired(operation: "identify", durationHours: 24)
        #expect(!isTransientIdentifyError(cliFailoverErr))

        // Quota exhaustion errors are NOT transient
        struct DummyError: LocalizedError {
            let msg: String
            var errorDescription: String? { msg }
        }
        let quota429 = DummyError(msg: "Gemini HTTP 429: Resource has been exhausted (e.g. check quota, free_tier_requests).")
        #expect(!isTransientIdentifyError(quota429))

        // Model overload 503 is transient when not failover
        let overload503 = DummyError(msg: "Gemini HTTP 503: The model is overloaded. Please try again later.")
        #expect(isTransientIdentifyError(overload503))
    }
}
