import SwiftUI
import LIVAAnimation

private struct DarkNavBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(Color.black, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}

struct ChatView: View {
    @ObservedObject var authVM: AuthViewModel
    @ObservedObject var agentVM: AgentViewModel
    @StateObject private var chatVM = ChatViewModel()
    @State private var inputText = ""
    @State private var showConversation = false

    var body: some View {
        VStack(spacing: 0) {
            // Black header bar
            headerBar

            // Avatar canvas + floating input
            ZStack {
                Color.black

                GeometryReader { geo in
                    LIVACanvasRepresentable()
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                VStack(spacing: 0) {
                    Spacer()
                    floatingInput
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            chatVM.configure()
            chatVM.connect()
        }
        .onDisappear {
            chatVM.disconnect()
        }
        .sheet(isPresented: $showConversation) {
            conversationPanel
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack {
            Button(action: {
                chatVM.disconnect()
                agentVM.deselectAgent()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                    Text("Back")
                        .font(.body)
                }
                .foregroundColor(.white)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(connectionDotColor)
                    .frame(width: 8, height: 8)
                Text(agentVM.selectedAgent?.name ?? "Chat")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Spacer()

            Button(action: { showConversation = true }) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Color.black)
    }

    // MARK: - Floating Input

    private var floatingInput: some View {
        HStack(spacing: 10) {
            TextField("Message...", text: $inputText)
                .foregroundColor(.white)
                .accentColor(.white)
                .font(.body)
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .onSubmit { send() }

            Button(action: { send() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(canSend ? .white : Color.white.opacity(0.3))
            }
            .disabled(!canSend)
            .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Conversation Panel

    private var conversationPanel: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(chatVM.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: chatVM.messages.count) { _ in
                    if let last = chatVM.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showConversation = false }
                }
            }
            .modifier(DarkNavBarModifier())
        }
        .preferredColorScheme(.dark)
    }

    private func messageBubble(_ message: Message) -> some View {
        HStack {
            if message.isUser { Spacer() }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.isUser ? Color.blue : Color.white.opacity(0.15))
                    )

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(Color.white.opacity(0.5))
            }

            if !message.isUser { Spacer() }
        }
    }

    private var connectionDotColor: Color {
        switch chatVM.connectionState {
        case .connected, .animating:
            return .green
        case .connecting:
            return .yellow
        case .idle, .error:
            return .red
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatVM.isSending
    }

    private func send() {
        guard canSend else { return }
        let text = inputText
        inputText = ""
        chatVM.sendMessage(text)
    }
}
