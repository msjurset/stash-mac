import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings tab that surfaces the `stash serve` daemon's current
/// pairing payload — QR for the Android app to scan plus the raw
/// URI / host / token for manual entry. Renders the QR locally via
/// CIQRCodeGenerator so the user doesn't have to look at the
/// daemon log or run the CLI in a terminal.
///
/// Reads the daemon's payload by shelling out to `stash serve
/// pair --json`. Rotation is exposed inline with a confirmation
/// prompt since it invalidates every paired device.
struct PairingPrefsView: View {
    @State private var pair: StashCLI.PairInfo?
    @State private var status: Status = .loading
    @State private var showingRotateConfirm = false
    @State private var rotating = false

    private enum Status: Equatable {
        case loading
        case ok
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                qrBlock
            } header: {
                Text("Pair a phone")
            } footer: {
                Text("Open the Stash app on your phone and scan this QR. The phone needs to reach this Mac on the same Wi-Fi (or via WireGuard / Tailscale).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let pair {
                Section {
                    LabeledContent("Server") {
                        Text("\(pair.host):\(pair.port)")
                            .font(.body.monospacedDigit())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Token") {
                        Text(pair.token)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("URI") {
                        Text(pair.uri)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("Manual entry")
                } footer: {
                    Text("Use these values if the phone can't scan the QR (debug build, screen glare, etc.).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 12) {
                    Button("Refresh") {
                        Task { await load() }
                    }
                    .disabled(status == .loading)
                    Button("Rotate Token…", role: .destructive) {
                        showingRotateConfirm = true
                    }
                    .disabled(rotating || pair == nil)
                    Spacer()
                    statusLine
                }
            } footer: {
                Text("Rotating the token invalidates every paired device. They'll need to scan the new QR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task { await load() }
        .confirmationDialog(
            "Rotate the server token?",
            isPresented: $showingRotateConfirm,
            titleVisibility: .visible,
        ) {
            Button("Rotate", role: .destructive) {
                Task { await rotateToken() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every paired device will be disconnected and will need to scan the new QR before syncing again.")
        }
    }

    @ViewBuilder
    private var qrBlock: some View {
        HStack(spacing: 16) {
            ZStack {
                if let pair, let img = renderQR(from: pair.uri) {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 200, height: 200)
                } else if status == .loading {
                    ProgressView()
                        .frame(width: 200, height: 200)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.15))
                        .frame(width: 200, height: 200)
                        .overlay {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Stash on your phone")
                    .font(.headline)
                Text("Settings → Pair with Mac → Scan")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Stash serve must be running. (It's installed as a launchd daemon by `make deploy` — restart your Mac and it auto-starts.)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading pairing info…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ok:
            EmptyView()
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func load() async {
        status = .loading
        do {
            let info = try await StashCLI.shared.pairInfo()
            await MainActor.run {
                pair = info
                status = .ok
            }
        } catch {
            await MainActor.run {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                status = .failed(msg)
            }
        }
    }

    private func rotateToken() async {
        rotating = true
        defer { Task { @MainActor in rotating = false } }
        do {
            try await StashCLI.shared.rotateServeToken()
            await load()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            await MainActor.run { status = .failed("Rotate failed: \(msg)") }
        }
    }

    /// Render a QR image for the given string via Core Image's
    /// CIQRCodeGenerator. M-correction-level keeps the QR readable
    /// at small sizes; the .none interpolation on the SwiftUI Image
    /// avoids blurring when the 200dp tile upscales the native
    /// ~30dp QR raster.
    private func renderQR(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: outputImage)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
