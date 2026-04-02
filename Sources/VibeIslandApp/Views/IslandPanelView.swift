import SwiftUI
import VibeIslandCore

struct IslandPanelView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ONE GLANCE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.state.attentionCount) attention")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let session = model.focusedSession {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(session.title)
                            .font(.headline)
                        Spacer(minLength: 16)
                        Text(session.tool.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(session.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

                    if let request = session.permissionRequest {
                        HStack(spacing: 10) {
                            Button(request.secondaryActionTitle) {
                                model.approveFocusedPermission(false)
                            }
                            .buttonStyle(.bordered)

                            Button(request.primaryActionTitle) {
                                model.approveFocusedPermission(true)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if let prompt = session.questionPrompt {
                        HStack(spacing: 10) {
                            ForEach(prompt.options.prefix(2), id: \.self) { option in
                                Button(option) {
                                    model.answerFocusedQuestion(option)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        HStack {
                            Label(session.phase.displayName, systemImage: "bolt.horizontal.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Jump") {
                                model.jumpToFocusedSession()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            } else {
                Text("Waiting for Codex hook events.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460, height: 210, alignment: .topLeading)
        .background(panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.92),
                        Color(red: 0.11, green: 0.13, blue: 0.18).opacity(0.96),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

struct MenuBarContentView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vibe Island OSS")
                .font(.headline)
            Text("\(model.state.runningCount) running · \(model.state.attentionCount) attention")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Button(model.isOverlayVisible ? "Hide Island Overlay" : "Show Island Overlay") {
                model.toggleOverlay()
            }

            Button("Restart Demo") {
                model.resetDemo()
            }

            if let session = model.focusedSession {
                Divider()
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                Text(session.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
