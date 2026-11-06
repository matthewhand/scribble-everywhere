import Foundation
import WinSDK
import PalimpsestCore

// oleacc.h's MSAAMENUINFO is not re-exported by Swift's WinSDK. This frozen
// layout matches its two DWORDs followed by LPWSTR (verified by native tests).
@frozen @usableFromInline
struct WinMenuAccessibilityInfo {
    var dwMSAASignature: DWORD = 0xAA0DF00D
    var cchWText: DWORD = 0
    var pszWText: UnsafeMutablePointer<WCHAR>? = nil
}

/// Owner-draw tray menu renderer.
/// Mirrors the macOS/Linux tray menu: color swatches, checkmarks, submenus,
/// disabled items, section separators, and inline add/remove colour.
final class WinTrayMenu {
    /// A single menu item with all state needed for owner-draw.
    struct Item {
        let id: Int
        let title: String
        let checked: Bool
        let enabled: Bool
        let isSeparator: Bool
        let isSubmenu: Bool
        let submenu: WinTrayMenu?
        /// For color swatch items: the RGBA to show.
        let swatchColor: RGBA?
        /// For "Paste into" section header: shows the resolved target.
        let isSectionHeader: Bool

        init(id: Int, title: String, checked: Bool = false, enabled: Bool = true,
             isSeparator: Bool = false, isSubmenu: Bool = false, submenu: WinTrayMenu? = nil,
             swatchColor: RGBA? = nil, isSectionHeader: Bool = false) {
            self.id = id
            self.title = title
            self.checked = checked
            self.enabled = enabled
            self.isSeparator = isSeparator
            self.isSubmenu = isSubmenu
            self.submenu = submenu
            self.swatchColor = swatchColor
            self.isSectionHeader = isSectionHeader
        }
    }

    let items: [Item]
    private let onSelect: (Int) -> Void
    private var nativeData: [MenuData] = []

    /// The native structure is allocated separately from the Swift object so
    /// MSAA sees its signature at byte zero, rather than a Swift object header.
    private final class MenuData {
        let info: UnsafeMutablePointer<WinMenuAccessibilityInfo>
        private let text: UnsafeMutablePointer<WCHAR>
        let value: ULONG_PTR
        init(title: String, index: Int) {
            let units = title.wide
            let buffer = UnsafeMutablePointer<WCHAR>.allocate(capacity: units.count)
            units.withUnsafeBufferPointer { buffer.initialize(from: $0.baseAddress!, count: units.count) }
            text = buffer
            var metadata = WinMenuAccessibilityInfo()
            metadata.cchWText = DWORD(units.count - 1)
            metadata.pszWText = buffer
            info = .allocate(capacity: 1)
            info.initialize(to: metadata)
            value = ULONG_PTR(UInt(bitPattern: info))
            WinTrayMenu.itemIndexes[value] = index
        }
        deinit {
            WinTrayMenu.itemIndexes.removeValue(forKey: value)
            text.deinitialize(count: Int(info.pointee.cchWText) + 1)
            text.deallocate()
            info.deinitialize(count: 1)
            info.deallocate()
        }
    }
    nonisolated(unsafe) private static var itemIndexes: [ULONG_PTR: Int] = [:]
    nonisolated static func index(for data: ULONG_PTR, count: Int) -> Int? {
        guard let index = itemIndexes[data], index >= 0, index < count else { return nil }
        return index
    }

    init(items: [Item], onSelect: @escaping (Int) -> Void) {
        self.items = items
        self.onSelect = onSelect
    }

    /// Build the HMENU with MF_OWNERDRAW items.
    lazy var drawingItems: [Item] = items.flatMap { [$0] + ($0.submenu?.drawingItems ?? []) }

    func buildMenu() -> HMENU? {
        var nextIndex = 0
        return buildMenu(nextIndex: &nextIndex)
    }

    private func buildMenu(nextIndex: inout Int) -> HMENU? {
        guard let menu = CreatePopupMenu() else {
            WinLog.log("CreatePopupMenu failed \(GetLastError())")
            return nil
        }
        for item in items {
            let index = nextIndex
            nextIndex += 1
            var flags = UINT(MF_OWNERDRAW | MF_STRING)
            if !item.enabled { flags |= UINT(MF_GRAYED) }
            if item.checked { flags |= UINT(MF_CHECKED) }
            if item.isSeparator { flags = UINT(MF_SEPARATOR) }
            // Accessible names and rendering data share stable native metadata;
            // command IDs remain independent of these item-data addresses.
            let data = MenuData(title: item.title, index: index)
            nativeData.append(data)
            let itemData = UINT_PTR(data.value)
            if item.isSubmenu, let sub = item.submenu {
                guard let subMenu = sub.buildMenu(nextIndex: &nextIndex) else {
                    _ = DestroyMenu(menu)
                    return nil
                }
                flags |= UINT(MF_POPUP)
                let subHandle = UINT_PTR(UInt(bitPattern: subMenu))
                if !AppendMenuW(menu, flags, subHandle, UnsafePointer<WCHAR>(bitPattern: UInt(itemData))) {
                    _ = DestroyMenu(subMenu)
                    _ = DestroyMenu(menu)
                    return nil
                }
            } else if item.isSeparator {
                guard AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil) else {
                    _ = DestroyMenu(menu)
                    return nil
                }
            } else {
                guard AppendMenuW(menu, flags, UINT_PTR(UInt(item.id)), UnsafePointer<WCHAR>(bitPattern: UInt(itemData))) else {
                    _ = DestroyMenu(menu)
                    return nil
                }
            }
        }
        return menu
    }

    /// Draw a single owner-draw menu item.
    nonisolated static func drawItem(_ drawItem: inout DRAWITEMSTRUCT, items: [Item]) {
        guard drawItem.CtlType == ODT_MENU else { return }
        guard let index = index(for: drawItem.itemData, count: items.count) else { return }
        let item = items[index]

        let hdc = drawItem.hDC
        let saved = SaveDC(hdc)
        defer { if saved != 0 { _ = RestoreDC(hdc, saved) } }
        var rc = drawItem.rcItem

        // Follow the system menu palette. Windows draws submenu arrows and
        // standard separators itself, so forcing dark rows makes those illegible.
        let selected = (drawItem.itemState & UINT(ODS_SELECTED)) != 0 && item.enabled
        let textColor = GetSysColor(Int32(!item.enabled ? COLOR_GRAYTEXT : (selected ? COLOR_HIGHLIGHTTEXT : COLOR_MENUTEXT)))
        let backColor: COLORREF
        if (drawItem.itemState & UINT(ODS_SELECTED)) != 0 {
            backColor = GetSysColor(Int32(item.enabled ? COLOR_HIGHLIGHT : COLOR_MENU))
        } else {
            backColor = GetSysColor(Int32(COLOR_MENU))
        }
        let checkColor = textColor
        let separatorColor = GetSysColor(Int32(COLOR_3DSHADOW))

        // Fill background
        let brush = CreateSolidBrush(backColor)
        FillRect(hdc, &rc, brush)
        DeleteObject(brush)

        // Separator
        if item.isSeparator {
            let sepY = rc.top + (rc.bottom - rc.top) / 2
            let pen = CreatePen(Int32(PS_SOLID), 1, separatorColor)
            let oldPen = SelectObject(hdc, pen)
            MoveToEx(hdc, rc.left + 24, sepY, nil)
            LineTo(hdc, rc.right - 4, sepY)
            SelectObject(hdc, oldPen)
            DeleteObject(pen)
            return
        }

        // Layout constants
        let checkWidth: Int32 = 24
        let textLeft = rc.left + checkWidth + 4
        let paddingV: Int32 = 2

        // Draw checkmark / radio dot for checked items (top-level, not submenu)
        if item.checked && !item.isSubmenu && item.swatchColor == nil {
            let cx = rc.left + checkWidth / 2
            let cy = rc.top + (rc.bottom - rc.top) / 2
            if item.title.contains("window") || item.title.contains("Paste") || item.title.contains("Previous") || item.title.contains("Frontmost") {
                // Radio dot for mutually exclusive paste targets
                let pen = CreatePen(Int32(PS_SOLID), 2, checkColor)
                let oldPen = SelectObject(hdc, pen)
                let brush = CreateSolidBrush(checkColor)
                let oldBrush = SelectObject(hdc, brush)
                Ellipse(hdc, cx - 5, cy - 5, cx + 5, cy + 5)
                SelectObject(hdc, oldBrush)
                SelectObject(hdc, oldPen)
                DeleteObject(brush)
                DeleteObject(pen)
            } else {
                // Checkmark for toggles
                let pen = CreatePen(Int32(PS_SOLID), 2, checkColor)
                let oldPen = SelectObject(hdc, pen)
                MoveToEx(hdc, cx - 4, cy, nil)
                LineTo(hdc, cx - 1, cy + 3)
                LineTo(hdc, cx + 4, cy - 3)
                SelectObject(hdc, oldPen)
                DeleteObject(pen)
            }
        }

        // Draw color swatch if present
        if let swatch = item.swatchColor {
            let swatchSize: Int32 = 14
            let swatchY = rc.top + (rc.bottom - rc.top - swatchSize) / 2
            let swatchX = rc.left + 4
            let brush = CreateSolidBrush(makeColorref(swatch))
            let oldBrush = SelectObject(hdc, brush)
            let pen = CreatePen(Int32(PS_SOLID), 1, COLORREF(0x808080))
            let oldPen = SelectObject(hdc, pen)
            Ellipse(hdc, swatchX, swatchY, swatchX + swatchSize, swatchY + swatchSize)
            if item.checked {
                // Selected ring
                let selPen = CreatePen(Int32(PS_SOLID), 2, checkColor)
                let oldSelPen = SelectObject(hdc, selPen)
                Ellipse(hdc, swatchX - 1, swatchY - 1, swatchX + swatchSize + 1, swatchY + swatchSize + 1)
                SelectObject(hdc, oldSelPen)
                DeleteObject(selPen)
            }
            SelectObject(hdc, oldBrush)
            SelectObject(hdc, oldPen)
            DeleteObject(brush)
            DeleteObject(pen)
        }

        // Draw text
        var textRect = RECT(
            left: textLeft,
            top: rc.top + paddingV,
            right: rc.right - 24, // leave room for submenu arrow
            bottom: rc.bottom - paddingV
        )
        let text = item.title.wide
        let format = UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX)
        SetTextColor(hdc, textColor)
        SetBkMode(hdc, TRANSPARENT)
        let font = getMenuFont()
        let oldFont = SelectObject(hdc, font)
        DrawTextW(hdc, text, -1, &textRect, format)
        SelectObject(hdc, oldFont)

        // Windows supplies the native submenu arrow outside the owner-draw area.
    }

    /// Measure item height/width.
    nonisolated static func measureItem(_ measureItem: inout MEASUREITEMSTRUCT, items: [Item]) {
        guard measureItem.CtlType == ODT_MENU else { return }
        guard let index = index(for: measureItem.itemData, count: items.count) else { return }
        let item = items[index]

        if item.isSeparator {
            measureItem.itemHeight = 8
            measureItem.itemWidth = 0
        } else {
            // Estimate width from text length
            let font = getMenuFont()
            var size = SIZE()
            let hdc = GetDC(nil)
            let oldFont = SelectObject(hdc, font)
            GetTextExtentPoint32W(hdc, item.title.wide, Int32(item.title.utf16.count), &size)
            var metrics = TEXTMETRICW()
            _ = GetTextMetricsW(hdc, &metrics)
            measureItem.itemHeight = UINT(max(metrics.tmHeight + 8, 28))
            SelectObject(hdc, oldFont)
            ReleaseDC(nil, hdc)
            measureItem.itemWidth = UINT(size.cx + 60) // check area + padding + arrow room
        }
    }

    /// System menu font (cached).
    nonisolated static func getMenuFont() -> HFONT? {
        if let f = cachedMenuFont { return f }
        var ncm = NONCLIENTMETRICSW()
        ncm.cbSize = UINT(MemoryLayout<NONCLIENTMETRICSW>.size)
        SystemParametersInfoW(UINT(SPI_GETNONCLIENTMETRICS), UINT(MemoryLayout<NONCLIENTMETRICSW>.size), &ncm, 0)
        let f = CreateFontIndirectW(&ncm.lfMenuFont)
        cachedMenuFont = f
        return f
    }

    /// Handle menu selection (click) - delegate to onSelect.
    func handleCommand(_ id: Int) {
        onSelect(id)
    }
}

/// Cached menu font handle (cleaned up at process exit).
private var cachedMenuFont: HFONT?
