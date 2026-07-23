import SwiftUI

struct HUDPreviewView: View {
    let chunk: HUDDisplayChunk
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header Status Line
            HStack {
                Text(chunk.headerText)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.1, green: 0.95, blue: 0.3))
                Spacer()
                Image(systemName: "glasses")
                    .foregroundColor(Color(red: 0.1, green: 0.95, blue: 0.3))
            }
            Divider()
                .background(Color(red: 0.1, green: 0.95, blue: 0.3).opacity(0.4))
            
            // Highlighted Line (Current Spoken)
            Text("> \(chunk.highlightedLine)")
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                .foregroundColor(Color(red: 0.2, green: 1.0, blue: 0.4))
                .lineLimit(1)
                .padding(.vertical, 2)
            
            // Next Line Preview
            Text("  \(chunk.nextLinePreview)")
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(Color(red: 0.1, green: 0.7, blue: 0.2).opacity(0.8))
                .lineLimit(1)
            
            Spacer().frame(height: 4)
            
            // Footer Control Line
            HStack {
                Spacer()
                Text(chunk.footerStatus)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(red: 0.1, green: 0.8, blue: 0.3).opacity(0.7))
                Spacer()
            }
        }
        .padding(14)
        .background(Color.black)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.1, green: 0.9, blue: 0.3).opacity(0.5), lineWidth: 1.5)
        )
        .shadow(color: Color(red: 0.1, green: 0.9, blue: 0.3).opacity(0.3), radius: 8, x: 0, y: 0)
    }
}
