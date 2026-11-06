import SwiftUI
import AppKit
import PalimpsestCore

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Toggle annotation mode: **\(store.hotkey.displayString)**")
                    HotkeyRecorder(hotkey: $store.hotkey)
                    Text("A modifier key is required. The hotkey is applied immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Global")
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Launch ScribbleEverywhere at login", isOn: $store.launchOnStartup)
            if let message = store.startupMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Action", selection: $store.action) {
                ForEach(DeliveryAction.allCases, id: \.self) { action in
                    Text(action.title).tag(action)
                }
            }
            Toggle("Save annotations to disk", isOn: $store.saveAnnotations)
            Toggle("Soften bright white backgrounds", isOn: $store.paperTone)
            Toggle("Use the pen as a mouse when not annotating", isOn: $store.penMouseMode)
            HStack {
                Text("Save folder")
                Spacer()
                Button(store.annotationFolder.lastPathComponent) {
                    chooseFolder()
                }
                .buttonStyle(.link)
            }
            Picker("Floating swatches", selection: $store.floatingPalettePosition) {
                ForEach(FloatingPalettePosition.allCases, id: \.self) { position in
                    Text(position.title).tag(position)
                }
            }

            GroupBox {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 12) {
                        ForEach(Array(store.palette.colors.enumerated()), id: \.offset) { index, color in
                            SwatchView(store: store, index: index, color: color)
                        }

                        AddSwatchButton(store: store)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .frame(height: 52)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Ink Colours")
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.annotationFolder
        if panel.runModal() == .OK, let url = panel.url {
            store.annotationFolder = url
            AppController.shared.history.setFolder(url)
        }
    }
}

private struct SwatchView: View {
    @ObservedObject var store: SettingsStore
    var index: Int
    var color: RGBA

    @State private var hovering = false
    @State private var showingEditor = false
    @State private var editColor = Color.white
    @State private var draftName = ""

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Color(color))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Circle().strokeBorder(
                            selected ? Color.accentColor : Color.secondary.opacity(0.35),
                            lineWidth: selected ? 3 : 1
                        )
                    )
                    .contentShape(Circle())
                    .onTapGesture { store.selectColour(at: index) }

                if hovering || showingEditor {
                    Button {
                        showingEditor = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit colour or name")
                }
            }

            if canDelete {
                Button {
                    store.removeColour(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .frame(height: 14)
                .help("Remove")
            } else {
                Color.clear.frame(height: 14)
            }
        }
        .frame(maxWidth: 30)
        .onHover { hovering = $0 }
        .accessibilityLabel(store.displayName(for: color))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .popover(isPresented: $showingEditor, arrowEdge: .bottom) {
            VStack(spacing: 12) {
                TextField("Name", text: $draftName, prompt: Text("Name (e.g. Salmon)"))
                    .textFieldStyle(.roundedBorder)
                ColorPicker("Swatch colour", selection: $editColor, supportsOpacity: false)
                Button("Done") { showingEditor = false }
            }
            .padding(14)
            .frame(width: 280)
            .onAppear {
                editColor = Color(color)
                draftName = store.customName(for: color) ?? ""
            }
            .onChange(of: editColor) { _, newValue in
                store.replaceColour(at: index, with: RGBA(newValue))
            }
            .onChange(of: draftName) { _, newName in
                store.setName(newName, for: color)
            }
            .onDisappear {
                if NSColorPanel.shared.isVisible { NSColorPanel.shared.close() }
            }
        }
    }

    private var selected: Bool { index == store.palette.index }
    private var canDelete: Bool { store.palette.colors.count > 1 }
}

/// The dashed "+" circle at the end of the swatch row. Its picker adds a
/// swatch on the first tick of a drag and then replaces that new swatch in
/// place on every following tick, so dragging the picker can never spam
/// duplicates.
private struct AddSwatchButton: View {
    @ObservedObject var store: SettingsStore

    @State private var showing = false
    @State private var addedIndex: Int?
    @State private var draftName = ""

    private var newColor: Binding<Color> {
        Binding(
            get: {
                if let addedIndex, store.palette.colors.indices.contains(addedIndex) {
                    return Color(store.palette.colors[addedIndex])
                }
                return Color(store.palette.current)
            },
            set: { newValue in
                let color = RGBA(newValue)
                var index = addedIndex ?? -1
                if !store.palette.colors.indices.contains(index) {
                    var palette = store.palette
                    palette.add(color)
                    store.palette = palette
                    index = store.palette.index
                    addedIndex = index
                }
                store.replaceColour(at: index, with: color)
                store.setName(draftName, for: color)
                addedIndex = store.palette.index
            }
        )
    }

    var body: some View {
        Button {
            addedIndex = nil
            draftName = ""
            showing = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .overlay(
                    Circle().strokeBorder(
                        Color.secondary.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [3])
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 30, height: 44, alignment: .top)
        .padding(.top, 0)
        .help("Add a colour")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(spacing: 12) {
                TextField("Name", text: $draftName, prompt: Text("Name (e.g. Salmon)"))
                    .textFieldStyle(.roundedBorder)
                ColorPicker("New colour", selection: newColor, supportsOpacity: false)
                Button("Done") { showing = false }
            }
            .padding(14)
            .frame(width: 280)
            .onChange(of: draftName) { _, newName in
                guard let addedIndex, store.palette.colors.indices.contains(addedIndex) else { return }
                store.setName(newName, for: store.palette.colors[addedIndex])
            }
            .onDisappear {
                addedIndex = nil
                if NSColorPanel.shared.isVisible { NSColorPanel.shared.close() }
            }
        }
    }
}

private struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkey: Hotkey

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { code, modifiers in
            let candidate = Hotkey(keyCode: code, modifiers: modifiers)
            guard candidate.isValid else { return }
            hotkey = candidate
        }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {}

    final class RecorderView: NSView {
        var onCapture: ((UInt32, KeyModifiers) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = Self.modifiers(from: event.modifierFlags)
            if KeyCodeNames.isModifier(UInt32(event.keyCode)) { return }
            guard modifiers.hasAny else {
                NSSound.beep()
                return
            }
            onCapture?(UInt32(event.keyCode), modifiers)
        }

        private static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
            var result: KeyModifiers = []
            if flags.contains(.command) { result.insert(.command) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.shift) { result.insert(.shift) }
            return result
        }
    }
}
