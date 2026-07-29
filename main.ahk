#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent()

#Include TrackpadLib.ahk
global TP := TrackpadManager()

; ===================================================================
; 1. SMART ALT-TAB NAVIGATION (4-FINGER SWIPES)
; ===================================================================

IsAltTabOpen() {
    return WinActive("ahk_class MultitaskingViewFrame") || WinActive("ahk_class TaskSwitcherWnd") || WinActive("ahk_class XamlExplorerHostIslandWindow")
}

; When Alt-Tab IS open -> Navigate the menu grid
TP.OnSwipe(4, "Left",  () => Send("{Left}"),  "*", IsAltTabOpen)
TP.OnSwipe(4, "Right", () => Send("{Right}"), "*", IsAltTabOpen)
TP.OnSwipe(4, "Up",    () => Send("{Up}"),    "*", IsAltTabOpen)
TP.OnSwipe(4, "Down",  () => Send("{Down}"),  "*", IsAltTabOpen)

; When Alt-Tab IS NOT open -> Open it (Left/Right) or trigger Windows commands (Up/Down)
TP.OnSwipe(4, "Left",  () => Send("^!{Tab}" ), "*", () => !IsAltTabOpen())
TP.OnSwipe(4, "Right", () => Send("^!{Tab}" ), "*", () => !IsAltTabOpen())
TP.OnSwipe(4, "Up",    () => Send("{LWin}"  ), "*", () => !IsAltTabOpen())
;TP.OnSwipe(4, "Down",  () => Send("{Escape}"), "*", () => !IsAltTabOpen())

; 4-Finger Tap -> Press Enter (to select the window you swiped to)
TP.OnTap(4, 1, () => Send("{Enter}"), "*", IsAltTabOpen)

; 4-Finger Double Tap -> Press Escape (to cancel Alt-Tab)
;TP.OnTap(4, 2, () => Send("{Esc}"), "*", IsAltTabOpen)


; ===================================================================
; 2. TAPS & HOLDS (MIDDLE CLICK & MULTI-TAPS)
; ===================================================================

; 3-Finger Single Tap -> Middle Click (Opens links instantly in new tabs)
TP.OnTap(3, 1, () => Send("{MButton}"))

; 3-Finger Double Tap -> Closes current tab
; TP.OnTap(3, 2, () => Send("^w"))

; 4-Finger Single Tap (when Alt-Tab isn't open) -> Play / Pause music
TP.OnTap(4, 1, () => Send("{Media_Play_Pause}"), "*", () => !IsAltTabOpen())

; 4-Finger Hold (0.6 seconds) -> Opens Task Manager
TP.OnHold(4, () => Send("^+{Esc}"), 600)


; ===================================================================
; 3. BROWSER & MEDIA (3-FINGER SWIPES)
; ===================================================================

; Browser Navigation (Forward/Backwards)
Browsers := ["chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "vivaldi.exe"]
TP.OnSwipe(3, "Left",  () => Send("!{Left}"), Browsers)
TP.OnSwipe(3, "Right", () => Send("!{Right}"), Browsers)

; Global Volume Control (Up / Down)
TP.OnSwipe(3, "Up",   () => Send("{Volume_Up 2}"))
TP.OnSwipe(3, "Down", () => Send("{Volume_Down 2}"))


; ===================================================================
; 4. ADVANCED PANNING & SCROLLING
; ===================================================================

; 3-Finger Pan -> Middle-Click Drag
; This is extremely useful for CAD, Blender, or navigating large canvases.
PanApps := ["acad.exe", "cadmate.exe", "gcad.exe", "blender.exe", "figma.exe"]
TP.OnMiddlePan(3, PanApps, "", 6) 

; ===================================================================
; 4. PINCH TO ZOOM OVERRIDES
; ===================================================================

ZoomIn() {
    Send("^{NumpadAdd}")
}

ZoomOut() {
    Send("^{NumpadSub}")
}

; Force standard Ctrl+ / Ctrl- in specific apps instead of Ctrl+ScrollWheel
PinchApps := ["notepad.exe", "notepad++.exe"]
TP.OnPinch(ZoomIn, ZoomOut, PinchApps)
