import SwiftUI
import AppKit

struct StyledTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)?
    
    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = placeholder
        textField.stringValue = text
        textField.bezelStyle = .roundedBezel
        textField.isBezeled = true
        textField.drawsBackground = true
        textField.focusRingType = .exterior
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submitAction(_:))
        return textField
    }
    
    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
            nsView.needsDisplay = true
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    @MainActor
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: StyledTextField
        
        init(_ parent: StyledTextField) {
            self.parent = parent
        }
        
        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }
        
        @objc func submitAction(_ sender: NSTextField) {
            parent.onSubmit?()
        }
    }
}