import SwiftUI
import LIVAAnimation

struct ChatView: View {
    @ObservedObject var authVM: AuthViewModel
    @ObservedObject var agentVM: AgentViewModel
    @StateObject private var chatVM = ChatViewModel()
    @State private var inputText = ""

    var body: some View {
        ZStack {
            // Full-screen avatar canvas
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                LIVACanvasRepresentable()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()

            // Floating input at bottom
            VStack(spacing: 0) {
                Spacer()
                floatingInput
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .onAppear {
            chatVM.configure()
            chatVM.connect()
        }
        .onDisappear {
            chatVM.disconnect()
        }
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
