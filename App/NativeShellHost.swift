#if DEBUG && SHELL_NATIVE_HOST
import SwiftUI
import UIKit

// Ordinary UIKit editor only. It never creates a keyboard, inputView or model.
// Keyboard UI and runtime identity must come from the installed .appex.
struct NativeShellHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .secondarySystemBackground
        let title = UILabel()
        title.text = "Native editor · installed extension"
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let editor = UITextView()
        editor.accessibilityIdentifier = "shell.host.input"
        editor.accessibilityLabel = "Native shell test editor"
        editor.font = .systemFont(ofSize: 24)
        editor.backgroundColor = .systemBackground
        editor.keyboardType = .default
        editor.autocorrectionType = .no
        editor.spellCheckingType = .no
        editor.autocapitalizationType = .sentences
        editor.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(title)
        controller.view.addSubview(editor)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 30),
            title.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 20),
            editor.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 24),
            editor.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 20),
            editor.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -20),
            editor.heightAnchor.constraint(equalToConstant: 130)
        ])
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
#endif
