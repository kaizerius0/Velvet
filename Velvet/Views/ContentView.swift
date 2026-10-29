import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var queue: QueueViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            if queue.hasRun {
                QueueScreen()
            } else {
                InputScreen()
            }
        }
        .frame(minWidth: 960, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct HeaderBar: View {
    var body: some View {
        HStack(spacing: 12) {
            LogoMark()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Velvet")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    #if DEBUG
                    Text("DEV")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .help("Entwicklungsversion aus Xcode – die normale App liegt unter /Programme.")
                    #endif
                }
                Text("Liste rein, Videos raus – als MP4 oder MP3.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ToolStatusBadge()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
