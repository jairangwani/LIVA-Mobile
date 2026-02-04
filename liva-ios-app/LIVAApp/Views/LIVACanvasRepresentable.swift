import SwiftUI
import LIVAAnimation

struct LIVACanvasRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> LIVACanvasView {
        let view = LIVACanvasView()
        view.backgroundColor = .black
        LIVAClient.shared.attachView(view)
        return view
    }

    func updateUIView(_ uiView: LIVACanvasView, context: Context) {
        // No dynamic updates needed — SDK drives rendering internally
    }
}
