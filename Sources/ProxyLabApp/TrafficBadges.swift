import SwiftUI

struct MethodBadge: View {
    let method: String

    private var color: Color {
        switch method.uppercased() {
        case "GET": .blue
        case "POST": .green
        case "PUT": .orange
        case "PATCH": .purple
        case "DELETE": .red
        case "HEAD": .teal
        case "OPTIONS": .indigo
        case "CONNECT": .gray
        case "TRACE": .pink
        default: .secondary
        }
    }

    var body: some View {
        Text(method.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .frame(minWidth: 58)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Method \(method)")
    }
}

struct StatusBadge: View {
    let status: Int?

    private var color: Color {
        switch status ?? 0 {
        case 100..<200: .teal
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .orange
        case 500..<600: .red
        default: .secondary
        }
    }

    var body: some View {
        Text(status.map(String.init) ?? "…")
            .font(.caption.monospacedDigit().bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(status.map { "HTTP status \($0)" } ?? "Pending response")
    }
}
