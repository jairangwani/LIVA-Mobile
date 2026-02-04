import SwiftUI
import LIVAAnimation

struct ChatView: View {
    @ObservedObject var authVM: AuthViewModel
    @ObservedObject var agentVM: AgentViewModel
    @StateObject private var chatVM = ChatViewModel()
    @State private var inputText = ""
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Animation canvas (top 65%)
            LIVACanvasRepresentable()
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()

            // Status bar
            statusBar

            Divider()

            // Messages + Input (bottom)
            VStack(spacing: 0) {
                messageList
                Divider()
                messageInput
            }
        }
        .navigationTitle(agentVM.selectedAgent?.name ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { agentVM.selectedAgent = nil }) {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showSettings) {
            SettingsView(authVM: authVM)
        }
        .onAppear {
            chatVM.configure()
            chatVM.connect()
        }
        .onDisappear {
            chatVM.disconnect()
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if chatVM.isSending {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }

    private var statusColor: Color {
        switch chatVM.connectionState {
        case .connected: return chatVM.isReady ? .green : .yellow
        case .connecting: return .orange
        case .animating: return .blue
        case .idle: return .gray
        case .error: return .red
        }
    }

    private var statusText: String {
        switch chatVM.connectionState {
        case .connected: return chatVM.isReady ? "Connected" : "Loading animations..."
        case .connecting: return "Connecting..."
        case .animating: return "Speaking..."
        case .idle: return "Idle"
        case .error(let err): return "Error: \(err)"
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chatVM.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: chatVM.messages.count) { _ in
                if let last = chatVM.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Message Input

    private var messageInput: some View {
        HStack(spacing: 8) {
            TextField("Type a message...", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }

            Button(action: { send() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatVM.isSending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = inputText
        inputText = ""
        chatVM.sendMessage(text)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isUser { Spacer() }
            Text(message.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(message.isUser ? Color.blue : Color(.systemGray5))
                .foregroundColor(message.isUser ? .white : .primary)
                .cornerRadius(16)
            if !message.isUser { Spacer() }
        }
    }
}
