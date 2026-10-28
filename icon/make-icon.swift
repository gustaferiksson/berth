import AppKit
import SwiftUI

let designs = ["window", "cards", "slip"]
let arguments = CommandLine.arguments
guard arguments.count == 3, designs.contains(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <\(designs.joined(separator: "|"))> <out.icon>\n".utf8))
    exit(1)
}
let design = arguments[1]
let bundle = URL(fileURLWithPath: arguments[2])
let canvas: CGFloat = 1024

struct Palette {
    let hue: String
    let deep: String
    let night: String
    let dusk: String
}

let palettes = [
    "window": Palette(hue: "0.839,0.690,0.447", deep: "0.380,0.255,0.090", night: "0.130,0.095,0.045", dusk: "0.300,0.250,0.180"),
    "cards": Palette(hue: "0.851,0.439,0.541", deep: "0.400,0.102,0.200", night: "0.150,0.045,0.075", dusk: "0.310,0.200,0.230"),
    "slip": Palette(hue: "0.118,0.561,0.847", deep: "0.035,0.220,0.380", night: "0.035,0.090,0.150", dusk: "0.180,0.250,0.320"),
]

struct Layer {
    let name: String
    let shape: Path
    let light: String
    let dark: String
    let opacity: Double
}

struct Group {
    let name: String
    let layers: [Layer]
    let translucency: Double
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
    Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
}

func chevron(x: CGFloat, y: CGFloat, size: CGFloat, weight: CGFloat) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: x, y: y - size))
    path.addLine(to: CGPoint(x: x + size * 0.8, y: y))
    path.addLine(to: CGPoint(x: x, y: y + size))
    return path.strokedPath(StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
}

func union(_ paths: [Path]) -> Path {
    paths.dropFirst().reduce(paths[0]) { Path($0.cgPath.union($1.cgPath)) }
}

let white = "1.000,1.000,1.000"
let palette = palettes[design]!

let groups: [Group] = {
    if design == "window" {
        return [
            Group(name: "Sessions", layers: [
                Layer(name: "active", shape: union([roundedRect(264, 476, 168, 72, 36), chevron(x: 568, y: 512, size: 80, weight: 56)]), light: palette.deep, dark: palette.hue, opacity: 1),
                Layer(name: "docked", shape: union([roundedRect(264, 364, 168, 72, 36), roundedRect(264, 588, 168, 72, 36)]), light: palette.deep, dark: palette.hue, opacity: 0.45),
            ], translucency: 0),
            Group(name: "Window", layers: [
                Layer(name: "window", shape: roundedRect(200, 220, 624, 584, 112), light: white, dark: palette.dusk, opacity: 1),
            ], translucency: 0.25),
        ]
    }
    if design == "cards" {
        return [
            Group(name: "Prompt", layers: [
                Layer(name: "prompt", shape: union([chevron(x: 312, y: 560, size: 80, weight: 60), roundedRect(456, 608, 200, 56, 28)]), light: palette.deep, dark: palette.hue, opacity: 1),
            ], translucency: 0),
            Group(name: "Front", layers: [
                Layer(name: "front", shape: roundedRect(200, 384, 624, 416, 96), light: white, dark: palette.dusk, opacity: 1),
            ], translucency: 0.2),
            Group(name: "Behind", layers: [
                Layer(name: "behind", shape: union([roundedRect(248, 304, 528, 416, 88), roundedRect(296, 224, 432, 416, 80)]), light: white, dark: palette.dusk, opacity: 0.5),
            ], translucency: 0.4),
        ]
    }
    var slip = Path()
    slip.addLines([CGPoint(x: 264, y: 216), CGPoint(x: 264, y: 760), CGPoint(x: 760, y: 760), CGPoint(x: 760, y: 216)])
    return [
        Group(name: "Session", layers: [
            Layer(name: "session", shape: Path(roundedRect: CGRect(x: 408, y: 248, width: 208, height: 432), cornerRadius: 104), light: palette.deep, dark: palette.hue, opacity: 1),
        ], translucency: 0),
        Group(name: "Berth", layers: [
            Layer(name: "berth", shape: slip.strokedPath(StrokeStyle(lineWidth: 96, lineCap: .round, lineJoin: .round)), light: white, dark: palette.dusk, opacity: 1),
        ], translucency: 0.2),
    ]
}()

@MainActor
func writePNG(_ shape: Path, to url: URL) throws {
    let renderer = ImageRenderer(content: shape.fill(Color.white).frame(width: canvas, height: canvas))
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

func solid(_ rgb: String) -> [String: String] { ["solid": "display-p3:\(rgb),1.00000"] }

let assets = bundle.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: bundle)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

try MainActor.assumeIsolated {
    for layer in groups.flatMap(\.layers) {
        try writePNG(layer.shape, to: assets.appendingPathComponent("\(layer.name).png"))
    }
}

let background = ["automatic-gradient": "display-p3:\(palette.hue),1.00000"]
let icon: [String: Any] = [
    "fill": background,
    "fill-specializations": [
        ["value": background],
        ["appearance": "dark", "value": ["automatic-gradient": "display-p3:\(palette.night),1.00000"]],
    ],
    "groups": groups.map { group in
        [
            "name": group.name,
            "layers": group.layers.map { layer in
                [
                    "name": layer.name,
                    "image-name": "\(layer.name).png",
                    "opacity": layer.opacity,
                    "fill-specializations": [
                        ["value": solid(layer.light)],
                        ["appearance": "dark", "value": solid(layer.dark)],
                    ],
                ] as [String: Any]
            },
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": group.translucency > 0, "value": group.translucency],
            "specular": true,
        ] as [String: Any]
    },
    "supported-platforms": ["squares": "shared"],
]
let json = try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
try json.write(to: bundle.appendingPathComponent("icon.json"))
print("wrote \(bundle.path)")
