import SwiftUI

struct ShootingStylePicker: UIViewRepresentable {
    struct Option: Equatable {
        let id: UUID?
        let name: String
        let scene: String
    }

    let options: [Option]
    @Binding var selection: UUID?

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.delegate = context.coordinator
        picker.dataSource = context.coordinator
        picker.accessibilityIdentifier = "shootingStyleWheel"
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        let changed = context.coordinator.parent.options != options
        context.coordinator.parent = self
        if changed { picker.reloadAllComponents() }
        if let row = options.firstIndex(where: { $0.id == selection }), picker.selectedRow(inComponent: 0) != row {
            picker.selectRow(row, inComponent: 0, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: ShootingStylePicker
        init(_ parent: ShootingStylePicker) { self.parent = parent }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int { parent.options.count }
        func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat { 58 }

        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
            let label = view as? UILabel ?? UILabel()
            let option = parent.options[row]
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = 2
            let title = NSMutableAttributedString(string: option.name, attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ])
            title.append(NSAttributedString(string: "\n\(option.scene)", attributes: [
                .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.lightGray,
                .paragraphStyle: paragraph
            ]))
            label.attributedText = title
            label.numberOfLines = 3
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.85
            label.accessibilityLabel = "\(option.name) · \(option.scene)"
            return label
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            parent.selection = parent.options[row].id
        }
    }
}
