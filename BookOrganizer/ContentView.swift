import SwiftUI

struct ContentView: View {
    @EnvironmentObject var fileMonitor: FileMonitor

    var body: some View {
        VStack(spacing: 10) {
            Text("Book Organizer")
                .font(.headline)
                .padding(.top)

            List {
                ForEach(fileMonitor.detectedFiles) { file in
                    HStack {
                        Text(file.originalFileName)
                            .frame(maxWidth: 150, alignment: .leading)
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                        Text(file.newFileName ?? "N/A")
                            .frame(maxWidth: 150, alignment: .leading)
                            .lineLimit(1)
                        Spacer()
                        statusView(for: file.status)
                        if file.status == .failed {
                            Button(action: {
                                fileMonitor.promptForISBN(file: file)
                            }) {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
            .frame(maxHeight: 400) // Limit the list height

            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .padding([.bottom, .trailing])
            }
        }
        .frame(width: 400, height: 500)
    }

    @ViewBuilder
    private func statusView(for status: FileStatus) -> some View {
        switch status {
        case .processed:
            Text("Processed")
                .foregroundColor(.green)
        case .failed:
            Text("Failed")
                .foregroundColor(.red)
        case .processing:
            Text("Processing")
                .foregroundColor(.orange)
        case .pending:
            Text("Pending")
                .foregroundColor(.gray)
        }
    }
}
