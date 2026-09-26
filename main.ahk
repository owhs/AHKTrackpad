#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent()
; ============================================================================
;  Touchpad gestures
; ----------------------------------------------------------------------------
;  What your fingers do:
;
;    4 fingers  swipe left / right   open the app switcher, then move through it
;               swipe up             Start menu
;               tap                  pick the app in the switcher (else play / pause)
;               hold                 Task Manager
;    3 fingers  tap                  middle click (open a link in a new tab)
;               swipe left / right   back / forward in a browser
;               swipe up / down      volume
;               drag                 middle-drag in CAD / Blender / Figma
;    pinch                           zoom in Notepad / Notepad++
;
;  The tray icon: pause gestures, open the calibrator, edit this file, reload.
;  Change a gesture below, save, and choose "Reload" from the tray.
; ============================================================================

#Include TrackpadLib.ahk
global TP := TrackpadManager()

; ---------------------------------------------------------------- how it feels
; The same timings the calibrator uses, so what works there works here.
TP.MaxTapDuration := 450        ; a tap is a touch shorter than this (ms)
HoldMs := 800                   ; a hold is a touch still for this long (ms): keep it well above MaxTapDuration
; TP.WatchdogMs := 150          ; raise to 250 if a hold ever ends by itself
; TP.TapDistancePerFinger := 55 ; raise if taps get missed because your fingers drift

; ---------------------------------------------------------------- 4 fingers: app switching
IsAltTabOpen() {
    return WinActive("ahk_class MultitaskingViewFrame") || WinActive("ahk_class TaskSwitcherWnd") || WinActive("ahk_class XamlExplorerHostIslandWindow")
}
NotAltTab() => !IsAltTabOpen()

; in the switcher: move through it, tap to pick
TP.OnSwipe(4, "Left",  () => Send("{Left}"),  "*", IsAltTabOpen)
TP.OnSwipe(4, "Right", () => Send("{Right}"), "*", IsAltTabOpen)
TP.OnSwipe(4, "Up",    () => Send("{Up}"),    "*", IsAltTabOpen)
TP.OnSwipe(4, "Down",  () => Send("{Down}"),  "*", IsAltTabOpen)
TP.OnTap(4, 1, () => Send("{Enter}"), "*", IsAltTabOpen)

; anywhere else: open the switcher, Start menu, play / pause, Task Manager
TP.OnSwipe(4, "Left",  () => Send("^!{Tab}"), "*", NotAltTab)
TP.OnSwipe(4, "Right", () => Send("^!{Tab}"), "*", NotAltTab)
TP.OnSwipe(4, "Up",    () => Send("{LWin}"),  "*", NotAltTab)
TP.OnTap(4, 1, () => Send("{Media_Play_Pause}"), "*", NotAltTab)
TP.OnHold(4, () => Send("^+{Esc}"), HoldMs)

; ---------------------------------------------------------------- 3 fingers
TP.OnTap(3, 1, () => Send("{MButton}"))

Browsers := ["chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "vivaldi.exe"]
TP.OnSwipe(3, "Left",  () => Send("!{Left}"),  Browsers)
TP.OnSwipe(3, "Right", () => Send("!{Right}"), Browsers)

TP.OnSwipe(3, "Up",   () => Send("{Volume_Up 2}"))
TP.OnSwipe(3, "Down", () => Send("{Volume_Down 2}"))

PanApps := ["acad.exe", "cadmate.exe", "gcad.exe", "blender.exe", "figma.exe"]
TP.OnMiddlePan(3, PanApps, "", 5)

; ---------------------------------------------------------------- pinch
PinchApps := ["notepad.exe", "notepad++.exe"]
TP.OnPinch(() => Send("^{NumpadAdd}"), () => Send("^{NumpadSub}"), PinchApps)

; ---------------------------------------------------------------- tray
Tray()
Tray() {
    A_IconTip := "Touchpad gestures"
    m := A_TrayMenu
    m.Delete()
    m.Add("Pause gestures", TogglePause)
    m.Add()
    m.Add("Calibrator (test and tune)", OpenCalibrator)
    m.Add("Edit gestures", (*) => Edit())
    m.Add("Reload", (*) => Reload())
    m.Add()
    m.Add("Quit", (*) => ExitApp())
    m.Default := "Pause gestures"
    m.ClickCount := 1
}
TogglePause(name, *) {
    paused := TP.Pause()
    A_TrayMenu.Rename(name, paused ? "Resume gestures" : "Pause gestures")
    A_IconTip := "Touchpad gestures" (paused ? " (paused)" : "")
    ToolTip(paused ? "Gestures paused" : "Gestures on")
    SetTimer(() => ToolTip(), -1200)
}
; while the calibrator is open these gestures step aside, so testing there doesn't send keys here
OpenCalibrator(*) {
    was := TP.Enabled
    TP.Pause(true)
    Run('"' A_AhkPath '" "' A_ScriptDir '\TrackpadCalibrator.ahk"', , , &pid)
    SetTimer(WaitClosed, 1000)
    WaitClosed() {
        if ProcessExist(pid)
            return
        SetTimer(WaitClosed, 0)
        if was
            TP.Pause(false)
    }
}
