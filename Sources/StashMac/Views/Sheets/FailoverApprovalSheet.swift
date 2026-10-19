import SwiftUI

/// Modal sheet presented when Gemini free-tier quota is exhausted
/// and a paid-tier API key is available. Allows the user to authorize
/// paid failover for 24 hours, for the current request only, or cancel.
struct FailoverApprovalSheet: View {
    let failover: PendingFailover
    @Environment(StashStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.badge.clock.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemini Quota Reached")
                        .font(.headline)
                    Text("Failover authorization required")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Your daily free-tier quota (20 requests/day) has been reached. A paid API key is configured for failover.")
                    .font(.body)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Operation:")
                            .fontWeight(.medium)
                        Text(failover.operation.capitalized)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "dollarsign.circle")
                            .foregroundStyle(.secondary)
                        Text("Estimated cost:")
                            .fontWeight(.medium)
                        Text("~$0.0016 for this request ($0.25 in / $1.50 out per 1M tokens)")
                    }
                }
                .font(.caption)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()

            VStack(spacing: 8) {
                Button {
                    Task {
                        await store.approveFailover(hours: failover.durationHours)
                        dismiss()
                    }
                } label: {
                    Text("Approve for \(failover.durationHours) Hours")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        await store.approveFailover(hours: 8760) // 1 year
                        dismiss()
                    }
                } label: {
                    Text("Approve for 1 Year (Scheduled Jobs & Daemons)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await store.approveFailoverOnce()
                        dismiss()
                    }
                } label: {
                    Text("Approve This Request Only")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button("Cancel") {
                    store.dismissFailover()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: 420, height: 360)
    }
}
