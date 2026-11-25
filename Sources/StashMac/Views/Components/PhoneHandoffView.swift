import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Models

struct PhoneHandoffPayload: Equatable, Sendable {
    let itemType: String
    let itemID: String
    let title: String
    let subtitle: String
    let webURL: String?
    let body: String?
    let metadata: [String: String]

    static func from(item: StashItem) -> PhoneHandoffPayload {
        var meta: [String: String] = [
            "Type": item.isRecipe ? "Recipe" : item.type.label,
            "ID": item.shortID,
        ]
        if let from = item.fromName, !from.isEmpty {
            meta["Source"] = from
        }
        if let size = item.humanFileSize {
            meta["Size"] = size
        }
        if let tags = item.tags, !tags.isEmpty {
            meta["Tags"] = tags.map { "#\($0.name)" }.joined(separator: " ")
        }
        if let cols = item.collections, !cols.isEmpty {
            meta["Collections"] = cols.map(\.name).joined(separator: ", ")
        }

        let sub: String = {
            if let tags = item.tags, !tags.isEmpty {
                return "\(item.isRecipe ? "Recipe" : item.type.label) • " + tags.map { "#\($0.name)" }.joined(separator: " ")
            }
            if let url = item.url, !url.isEmpty {
                return url
            }
            return "\(item.isRecipe ? "Recipe" : item.type.label) • \(item.shortID)"
        }()

        let bodyText = (item.notes?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (item.extractedText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

        return PhoneHandoffPayload(
            itemType: item.isRecipe ? "recipe" : item.type.rawValue,
            itemID: item.id,
            title: item.title,
            subtitle: sub,
            webURL: item.url,
            body: bodyText,
            metadata: meta
        )
    }
}

struct PhoneHandoffResponse: Codable, Equatable, Sendable {
    let handoffID: String
    let token: String
    let itemType: String
    let itemID: String
    let title: String
    let subtitle: String?
    let webURL: String?
    let deepLink: String
    let lanReaderURL: String
    let tailscaleReaderURL: String?
    let preferredReaderURL: String
    let pushSent: Bool
    let pushTarget: String?
    let pushError: String?
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case handoffID = "handoff_id"
        case token
        case itemType = "item_type"
        case itemID = "item_id"
        case title
        case subtitle
        case webURL = "web_url"
        case deepLink = "deep_link"
        case lanReaderURL = "lan_reader_url"
        case tailscaleReaderURL = "tailscale_reader_url"
        case preferredReaderURL = "preferred_reader_url"
        case pushSent = "push_sent"
        case pushTarget = "push_target"
        case pushError = "push_error"
        case expiresAt = "expires_at"
    }
}

// MARK: - Service

@MainActor
final class PhoneHandoffService {
    static let shared = PhoneHandoffService()

    private struct RequestBody: Encodable {
        let itemType: String
        let itemID: String
        let title: String
        let subtitle: String
        let webURL: String?
        let body: String?
        let metadata: [String: String]
        let push: Bool

        enum CodingKeys: String, CodingKey {
            case itemType = "item_type"
            case itemID = "item_id"
            case title
            case subtitle
            case webURL = "web_url"
            case body
            case metadata
            case push
        }
    }

    private var serverPort: Int {
        if let raw = ProcessInfo.processInfo.environment["STASH_PORT"], let p = Int(raw), p > 0 {
            return p
        }
        return 9999
    }

    func send(payload: PhoneHandoffPayload, push: Bool = true) async -> PhoneHandoffResponse {
        let endpoint = URL(string: "http://127.0.0.1:\(serverPort)/api/v1/handoff")!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8

        let body = RequestBody(
            itemType: payload.itemType,
            itemID: payload.itemID,
            title: payload.title,
            subtitle: payload.subtitle,
            webURL: payload.webURL,
            body: payload.body,
            metadata: payload.metadata,
            push: push
        )

        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return try JSONDecoder().decode(PhoneHandoffResponse.self, from: data)
            }
        } catch {
            // Fall through to local fallback below.
        }

        // Fallback if local daemon is temporarily unreachable
        var comps = URLComponents()
        comps.scheme = "stash"
        comps.host = "handoff"
        var queryItems = [
            URLQueryItem(name: "type", value: payload.itemType),
            URLQueryItem(name: "id", value: payload.itemID),
            URLQueryItem(name: "title", value: payload.title),
        ]
        if let web = payload.webURL, !web.isEmpty {
            queryItems.append(URLQueryItem(name: "url", value: web))
        }
        comps.queryItems = queryItems
        let deepLink = comps.string ?? "stash://handoff?id=\(payload.itemID)"
        let fallbackURL = payload.webURL ?? deepLink

        return PhoneHandoffResponse(
            handoffID: UUID().uuidString,
            token: "",
            itemType: payload.itemType,
            itemID: payload.itemID,
            title: payload.title,
            subtitle: payload.subtitle,
            webURL: payload.webURL,
            deepLink: deepLink,
            lanReaderURL: fallbackURL,
            tailscaleReaderURL: nil,
            preferredReaderURL: fallbackURL,
            pushSent: false,
            pushTarget: nil,
            pushError: "Local Stash server (port \(serverPort)) not responding; using direct link.",
            expiresAt: ""
        )
    }
}

// MARK: - QR Generator

enum PhoneQRCodeGenerator {
    static func image(for string: String, size: CGFloat = 180) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let extent = outputImage.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scaleX = size / extent.width
        let scaleY = size / extent.height
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

// MARK: - Button & Popover

struct PhoneHandoffButton: View {
    let payload: PhoneHandoffPayload
    var label: String? = nil
    var controlSize: ControlSize = .small
    var externalIsPresented: Binding<Bool>? = nil

    @State private var internalIsPresented = false

    private var isPresentedBinding: Binding<Bool> {
        externalIsPresented ?? $internalIsPresented
    }

    var body: some View {
        Button {
            isPresentedBinding.wrappedValue.toggle()
        } label: {
            Image(systemName: "iphone.and.arrow.forward")
        }
        .buttonStyle(.bordered)
        .controlSize(controlSize)
        .focusable(false)
        .pointingHandCursor()
        .accessibilityLabel("Send to Phone")
        .help("Send to Phone — push notification, mobile reader & QR code (⌘⇧O)")
        .background(
            PersistentPopoverHost(
                isPresented: isPresentedBinding,
                preferredEdge: .minY
            ) {
                PhoneHandoffPopoverView(payload: payload)
            }
        )
    }
}

struct PhoneHandoffPopoverView: View {
    let payload: PhoneHandoffPayload

    enum LinkMode: String, CaseIterable, Identifiable {
        case reader = "Reader View"
        case app = "Companion App"
        case web = "Web Link"
        var id: String { rawValue }
    }

    enum NetworkRoute: String, CaseIterable, Identifiable {
        case lan = "LAN Wi-Fi"
        case tailscale = "Tailscale"
        var id: String { rawValue }
    }

    @State private var response: PhoneHandoffResponse?
    @State private var isLoading = true
    @State private var linkMode: LinkMode = .reader
    @State private var networkRoute: NetworkRoute = .lan
    @State private var copiedFeedback = false

    private var availableModes: [LinkMode] {
        if let web = payload.webURL, !web.isEmpty {
            return [.reader, .app, .web]
        }
        return [.reader, .app]
    }

    private var activeURLString: String {
        guard let response else {
            return payload.webURL ?? "stash://handoff?id=\(payload.itemID)"
        }
        switch linkMode {
        case .reader:
            if networkRoute == .tailscale, let ts = response.tailscaleReaderURL, !ts.isEmpty {
                return ts
            }
            return response.lanReaderURL
        case .app:
            return response.deepLink
        case .web:
            return response.webURL ?? response.lanReaderURL
        }
    }

    private var qrPayloadString: String {
        guard let response else { return activeURLString }
        if linkMode == .app {
            let base = (networkRoute == .tailscale && !(response.tailscaleReaderURL ?? "").isEmpty)
                ? (response.tailscaleReaderURL ?? response.preferredReaderURL)
                : response.preferredReaderURL
            if base.hasPrefix("http") {
                return base + "?open=app"
            }
        }
        return activeURLString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to Phone")
                        .font(.headline)
                    Text(payload.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            // Status Banner
            statusBanner

            // Mode Picker
            Picker("", selection: $linkMode) {
                ForEach(availableModes) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if linkMode == .reader,
               let ts = response?.tailscaleReaderURL, !ts.isEmpty {
                HStack(spacing: 6) {
                    Text("Network:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $networkRoute) {
                        ForEach(NetworkRoute.allCases) { route in
                            Text(route.rawValue).tag(route)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .labelsHidden()
                }
            }

            // QR Code Card
            VStack(spacing: 8) {
                if let qrImage = PhoneQRCodeGenerator.image(for: qrPayloadString, size: 176) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 176, height: 176)
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                }

                Text(modeHintText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(activeURLString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 250)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            Divider()

            // Action Buttons
            HStack(spacing: 8) {
                Button {
                    Task { await triggerHandoff(push: true) }
                } label: {
                    Label(isLoading ? "Sending…" : "Push Again", systemImage: "bell.badge")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isLoading)
                .focusable(false)
                .pointingHandCursor()

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(activeURLString, forType: .string)
                    copiedFeedback = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedFeedback = false
                    }
                } label: {
                    Label(copiedFeedback ? "Copied!" : "Copy", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusable(false)
                .pointingHandCursor()

                if let url = URL(string: activeURLString), url.scheme?.hasPrefix("http") == true {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusable(false)
                    .pointingHandCursor()
                    .help("Preview mobile reader in browser")
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .task(id: payload.itemID) {
            await triggerHandoff(push: true)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Pushing to phone & minting reader link…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        } else if let response {
            if response.pushSent {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sent to \(prettyTargetName(response.pushTarget))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Tap notification on phone or scan QR code")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mobile Reader Ready (30m TTL)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Scan QR with phone camera or open Companion App")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var modeHintText: String {
        switch linkMode {
        case .reader:
            return "Zero-login dark reader view with full text, media & attachments"
        case .app:
            return "Opens directly inside the Stash Android companion app"
        case .web:
            return "Opens the original web URL directly in your phone browser"
        }
    }

    private func prettyTargetName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Phone" }
        let suffix = raw.replacingOccurrences(of: "notify.mobile_app_", with: "")
        return suffix
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func triggerHandoff(push: Bool) async {
        isLoading = true
        let res = await PhoneHandoffService.shared.send(payload: payload, push: push)
        response = res
        isLoading = false
    }
}
