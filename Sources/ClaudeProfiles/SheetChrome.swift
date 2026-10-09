import SwiftUI

/// Shared layout for command sheets: title, scrolling form, inline progress log, error, and buttons.
struct CommandSheet<Content: View, Buttons: View>: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let subtitle: String
    let logStart: Int?
    let error: String?
    var width: CGFloat = 620
    var height: CGFloat = 640
    @ViewBuilder var content: () -> Content
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)
            Form {
                content()
            }
            .formStyle(.grouped)
            .disabled(model.isBusy)
            if let logStart {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if model.isBusy {
                            ProgressView().controlSize(.small)
                            Text(model.activeCommand ?? "Working…")
                                .font(.callout.weight(.medium))
                            Text("This can take a minute.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LogLinesView(lines: model.log.filter { $0.id >= logStart })
                        .frame(height: 120)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
            if let error {
                Label {
                    Text(error)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            Divider().padding(.top, 12)
            HStack {
                Spacer()
                buttons()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: width, height: height)
    }
}
