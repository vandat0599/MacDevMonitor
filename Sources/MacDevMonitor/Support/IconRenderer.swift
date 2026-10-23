import AppKit
import SwiftUI

/// `MacDevMonitor --render-icon <file.png>` draws the 1024×1024 app icon used by scripts/bundle.sh.
@MainActor
enum IconRenderer {
    static func run(outputPath: String) {
        let icon = ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.30), Color(red: 0.03, green: 0.05, blue: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            Image(systemName: "memorychip")
                .font(.system(size: 400, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.35, green: 0.95, blue: 0.65), Color(red: 0.15, green: 0.70, blue: 0.95)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 170, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 230, y: 230)
                .shadow(color: .black.opacity(0.5), radius: 12)
        }
        .frame(width: 1024, height: 1024)

        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { exit(1) }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
            exit(0)
        } catch {
            exit(1)
        }
    }
}
