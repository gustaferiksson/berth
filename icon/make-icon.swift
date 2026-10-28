import AppKit
import SwiftUI

let hues = [
    "rose": "d9708a",
    "sand": "d6b072",
    "peach": "e58f7b",
    "gold": "d9b44a",
    "mocha": "8c6a5a",
    "stone": "a69b8f",
]
let arguments = CommandLine.arguments.dropFirst()
let hueName = arguments.count == 2 ? arguments.first! : "mocha"
guard (1...2).contains(arguments.count), let hex = hues[hueName], let rgb = UInt32(hex, radix: 16) else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift [\(hues.keys.sorted().joined(separator: "|"))] <out.icon>\n".utf8))
    exit(1)
}
let bundle = URL(fileURLWithPath: arguments.last!)
let canvas: CGFloat = 1024
let hue = [rgb >> 16, rgb >> 8 & 0xff, rgb & 0xff].map { Double($0) / 255 }

func color(_ scale: Double) -> String {
    "display-p3:" + hue.map { String(format: "%.3f", $0 * scale) }.joined(separator: ",") + ",1.00000"
}

let white = "display-p3:1.000,1.000,1.000,1.00000"

struct Layer {
    let name: String
    let shape: Path
    let light: String
    let dark: String
}

struct Group {
    let layer: Layer
    let opacity: Double
    let translucency: Double
}

func card(scale: CGFloat, top: CGFloat) -> Path {
    let width = 624 * scale
    return Path(roundedRect: CGRect(x: (canvas - width) / 2, y: top, width: width, height: 416 * scale), cornerRadius: 104 * scale, style: .continuous)
}

let prompt: Path = {
    var chevron = Path()
    chevron.move(to: CGPoint(x: 344, y: 484))
    chevron.addLine(to: CGPoint(x: 412, y: 552))
    chevron.addLine(to: CGPoint(x: 344, y: 620))
    let stroke = chevron.strokedPath(StrokeStyle(lineWidth: 64, lineCap: .round, lineJoin: .round))
    let cursor = Path(roundedRect: CGRect(x: 468, y: 590, width: 212, height: 60), cornerRadius: 30)
    return Path(stroke.cgPath.union(cursor.cgPath))
}()

let groups = [
    Group(layer: Layer(name: "prompt", shape: prompt, light: color(0.42), dark: color(1)), opacity: 1, translucency: 0),
    Group(layer: Layer(name: "front", shape: card(scale: 1, top: 344), light: white, dark: color(0.44)), opacity: 1, translucency: 0),
    Group(layer: Layer(name: "middle", shape: card(scale: 0.92, top: 296), light: white, dark: color(0.36)), opacity: 0.75, translucency: 0.3),
    Group(layer: Layer(name: "back", shape: card(scale: 0.84, top: 248), light: white, dark: color(0.30)), opacity: 0.5, translucency: 0.5),
]

@MainActor
func writePNG(_ shape: Path, to url: URL) throws {
    let renderer = ImageRenderer(content: shape.fill(Color.white).frame(width: canvas, height: canvas))
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let assets = bundle.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: bundle)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

try MainActor.assumeIsolated {
    for group in groups {
        try writePNG(group.layer.shape, to: assets.appendingPathComponent("\(group.layer.name).png"))
    }
}

let background = ["automatic-gradient": color(1)]
let icon: [String: Any] = [
    "fill": background,
    "fill-specializations": [
        ["value": background],
        ["appearance": "dark", "value": ["automatic-gradient": color(0.16)]],
    ],
    "groups": groups.map { group in
        [
            "name": group.layer.name.capitalized,
            "layers": [
                [
                    "name": group.layer.name,
                    "image-name": "\(group.layer.name).png",
                    "fill-specializations": [
                        ["value": ["solid": group.layer.light]],
                        ["appearance": "dark", "value": ["solid": group.layer.dark]],
                    ],
                ] as [String: Any],
            ],
            "opacity": group.opacity,
            "shadow": ["kind": "layer-color", "opacity": 0.5],
            "translucency": ["enabled": group.translucency > 0, "value": group.translucency],
            "specular": true,
        ] as [String: Any]
    },
    "supported-platforms": ["squares": "shared"],
]
let json = try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
try json.write(to: bundle.appendingPathComponent("icon.json"))
print("wrote \(bundle.path)")
