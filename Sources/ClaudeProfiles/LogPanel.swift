import SwiftUI

struct LogLinesView: View {
    let lines: [LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, weight: line.isCommand ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: lines.last?.id) { lastID in
                if let lastID {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private func color(for line: LogLine) -> Color {
        if line.isCommand { return .accentColor }
        if line.isError { return .orange }
        return .primary
    }
}

struct LogPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            header
            if model.logVisible {
                Divider()
                Group {
                    if model.log.isEmpty {
                        Text("Output of the commands you run appears here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        LogLinesView(lines: model.log)
                    }
                }
                .frame(height: 170)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.logVisible.toggle() }
            } label: {
                Image(systemName: model.logVisible ? "chevron.down" : "chevron.up")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(model.logVisible ? "Hide log (⌘L)" : "Show log (⌘L)")
            if let command = model.activeCommand {
                ProgressView().controlSize(.small)
                Text(command)
                    .font(.callout.weight(.medium))
                Text("running…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let status = model.lastExitStatus {
                Image(systemName: status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(status == 0 ? .green : .red)
                Text(status == 0 ? "Last command finished" : "Last command failed (exit \(status))")
                    .font(.callout)
            } else {
                Text("Log")
                    .font(.callout.weight(.medium))
                Text("Nothing has run yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.log.isEmpty {
                Button {
                    SystemActions.copyToPasteboard(model.log.map(\.text).joined(separator: "\n"))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the log")
                Button {
                    model.clearLog()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
                .help("Clear the log")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}
