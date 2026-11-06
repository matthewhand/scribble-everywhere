import Testing
import WinSDK
import PalimpsestCore
@testable import PalimpsestWin

/// Native menu/GDI checks. These do not replace interactive submenu selection
/// or real pen/touch tests. They require Windows and its Swift toolchain.
@Suite("Windows tray menu", .serialized)
struct TrayMenuTests {
    @Test func nestedMenusKeepDrawingDataSeparateFromCommands() throws {
        let deepest = WinTrayMenu(items: [
            .init(id: WinTrayCommand.addColourBase, title: "Violet", swatchColor: .blue)
        ], onSelect: { _ in })
        let child = WinTrayMenu(items: [
            .init(id: WinTrayCommand.stopClipboard, title: "Clipboard only", checked: true),
            .init(id: 0, title: "", enabled: false, isSeparator: true),
            .init(id: 0, title: "Add", isSubmenu: true, submenu: deepest)
        ], onSelect: { _ in })
        let renderer = WinTrayMenu(items: [
            .init(id: WinTrayCommand.toggle, title: "Start"),
            .init(id: 0, title: "Options", isSubmenu: true, submenu: child),
            .init(id: WinTrayCommand.clear, title: "Clear", enabled: false)
        ], onSelect: { _ in })
        let menu = try #require(renderer.buildMenu())
        defer { _ = DestroyMenu(menu); withExtendedLifetime(renderer) {} }
        let flat = renderer.drawingItems
        var seenData = Set<ULONG_PTR>()
        var seenCommands = Set<UInt32>()

        func inspect(_ handle: HMENU) throws {
            for position in 0..<Int(GetMenuItemCount(handle)) {
                var info = MENUITEMINFOW()
                info.cbSize = UINT(MemoryLayout<MENUITEMINFOW>.size)
                info.fMask = UINT(MIIM_DATA | MIIM_ID | MIIM_SUBMENU | MIIM_STATE | MIIM_FTYPE)
                try #require(GetMenuItemInfoW(handle, UINT(position), true, &info))
                if info.fType & UINT(MFT_SEPARATOR) != 0 { continue }
                let index = try #require(WinTrayMenu.index(for: info.dwItemData, count: flat.count))
                #expect(seenData.insert(info.dwItemData).inserted)
                let item = flat[index]
                #expect(MemoryLayout<WinMenuAccessibilityInfo>.offset(of: \.dwMSAASignature) == 0)
                #expect(MemoryLayout<WinMenuAccessibilityInfo>.offset(of: \.cchWText) == 4)
                #expect(MemoryLayout<WinMenuAccessibilityInfo>.offset(of: \.pszWText) == 8)
                let metadata = try #require(UnsafePointer<WinMenuAccessibilityInfo>(bitPattern: UInt(info.dwItemData)))
                #expect(metadata.pointee.dwMSAASignature == DWORD(0xAA0DF00D))
                let name = try #require(metadata.pointee.pszWText)
                #expect(String(decoding: UnsafeBufferPointer(start: name, count: Int(metadata.pointee.cchWText)), as: UTF16.self) == item.title)
                #expect((info.fState & UINT(MFS_DISABLED) == 0) == item.enabled)
                #expect((info.fState & UINT(MFS_CHECKED) != 0) == item.checked)
                if let submenu = info.hSubMenu {
                    #expect(item.isSubmenu)
                    try inspect(submenu)
                } else {
                    #expect(info.wID == UINT(item.id))
                    #expect(seenCommands.insert(info.wID).inserted)
                }
                var measured = MEASUREITEMSTRUCT()
                measured.CtlType = UINT(ODT_MENU)
                measured.itemData = info.dwItemData
                WinTrayMenu.measureItem(&measured, items: flat)
                #expect(measured.itemWidth > 60)
                #expect(measured.itemHeight >= 28)
            }
        }

        try inspect(menu)
        #expect(seenData.count == flat.filter { !$0.isSeparator }.count)
        #expect(seenCommands == Set<UInt32>([
            UINT(WinTrayCommand.toggle), UINT(WinTrayCommand.clear),
            UINT(WinTrayCommand.stopClipboard), UINT(WinTrayCommand.addColourBase)
        ]))
    }

    @Test func ownerDrawPaintsSelectedBackgroundAndColourSwatch() throws {
        let screen = try #require(GetDC(nil))
        defer { _ = ReleaseDC(nil, screen) }
        let dc = try #require(CreateCompatibleDC(screen))
        let bitmap = try #require(CreateCompatibleBitmap(screen, 400, 80))
        let original = SelectObject(dc, bitmap)
        defer {
            _ = SelectObject(dc, original)
            _ = DeleteObject(bitmap)
            _ = DeleteDC(dc)
        }
        let items: [WinTrayMenu.Item] = [
            .init(id: WinTrayCommand.colourBase, title: "Red", checked: true, swatchColor: .red)
        ]
        let renderer = WinTrayMenu(items: items, onSelect: { _ in })
        let menu = try #require(renderer.buildMenu())
        defer { _ = DestroyMenu(menu); withExtendedLifetime(renderer) {} }
        var info = MENUITEMINFOW()
        info.cbSize = UINT(MemoryLayout<MENUITEMINFOW>.size)
        info.fMask = UINT(MIIM_DATA)
        try #require(GetMenuItemInfoW(menu, 0, true, &info))
        var draw = DRAWITEMSTRUCT()
        draw.CtlType = UINT(ODT_MENU)
        draw.itemData = info.dwItemData
        draw.itemState = UINT(ODS_SELECTED)
        draw.hDC = dc
        draw.rcItem = RECT(left: 0, top: 0, right: 400, bottom: 80)
        WinTrayMenu.drawItem(&draw, items: items)
        #expect(GetPixel(dc, 340, 40) == GetSysColor(Int32(COLOR_HIGHLIGHT)))
        #expect(GetPixel(dc, 11, 40) == makeColorref(.red))
    }

    @Test func invalidDrawingDataDoesNotChangeMeasurements() {
        let items: [WinTrayMenu.Item] = [.init(id: 1001, title: "Start")]
        for invalid in [ULONG_PTR(0), ULONG_PTR(2), ULONG_PTR.max] {
            var measured = MEASUREITEMSTRUCT()
            measured.CtlType = UINT(ODT_MENU)
            measured.itemData = invalid
            measured.itemWidth = 777
            measured.itemHeight = 888
            WinTrayMenu.measureItem(&measured, items: items)
            #expect(measured.itemWidth == 777)
            #expect(measured.itemHeight == 888)
        }
    }
}
