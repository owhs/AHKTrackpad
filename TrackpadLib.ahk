#Requires AutoHotkey v2.0
; ============================================================================
; TrackpadLib.ahk - Universal Windows Precision Touchpad (PTP) gesture engine
; ----------------------------------------------------------------------------
; v2 hardware engine. The original version of this file parsed raw HID
; touchpad packets using byte offsets that were hand-reverse-engineered from
; ONE specific laptop's touchpad (report ID 0x04, finger count at byte 8,
; X/Y as signed shorts at bytes 2/4, a "state" nibble at byte 1). Those
; offsets are not part of any standard - every vendor's HID report
; descriptor packs fields differently, so the old code only worked on the
; exact hardware it was written against.
;
; This version instead reads each device's own HID report descriptor at
; runtime (via GetRawInputDeviceInfo + HidP_GetCaps/HidP_GetValueCaps) to
; discover, per physical device:
;   - which Report ID carries touch data
;   - which byte(s)/bits carry Contact Count (Digitizer usage 0x0D/0x54)
;   - which byte(s)/bits carry the first finger's X/Y (Generic Desktop
;     usage 0x01/0x30 and 0x01/0x31), and that axis's native logical range
; and then uses HidP_GetUsageValue to pull the actual values out of every
; incoming report, instead of guessing byte offsets ourselves. Coordinates
; are normalized to a fixed 0-1000 range (NormRange) so gesture thresholds
; behave consistently regardless of a given trackpad's native resolution.
;
; This works on any Windows Precision Touchpad (the certified touchpad
; class virtually all Windows laptops sold since ~2015-2016 use). Older
; laptops with legacy Synaptics/ELAN "OEM" touchpad drivers (pre-PTP) do
; not expose multitouch data this way at all - no software trick in Raw
; Input can universally support them, that limitation is fundamental to
; how Windows treats those touchpads (mouse-emulation only). If your
; laptop predates ~2015 and isn't advertised as "Precision Touchpad" in
; Device Manager, this library (and the old version) simply cannot see
; multi-finger data.
;
; See TrackpadCalibrator.ahk (companion script) to inspect what this
; library auto-detects on your specific machine and to tune gesture
; thresholds interactively.
; ============================================================================
class TrackpadManager {
    ; quiet: for a host app (Reach) -- failures throw instead of a message box and
    ; ExitApp, and there's no tray warning when no touchpad is found
    __New(quiet := false) {
        this.Quiet := quiet
        this.Handlers := []
        this.ActiveHandlers := []
        this.IsTracking := false

        this.CurrentFingers := 0
        this.MaxFingers := 0
        this.LastFingers := 0
        this.LastX := 0
        this.LastY := 0
        this.StartX := 0
        this.StartMinX := 0, this.StartMaxX := 0, this.StartMinY := 0, this.StartMaxY := 0
        this.StartY := 0

        this.StartTime := 0
        this.MaxDist := 0
        this.HasMoved := false
        this.HasTriggeredSwipe := false

        this.TapFingers := 0
        this.TapCount := 0
        this.LastTapTime := 0
        this.LastTapLift := 0

        this.States := Map()
        this.ActiveHoldHandler := ""

        this.MiddleLastDown := 0
        this.MiddleLastUp := 0
        this.MiddlePending := false
        this.ExecuteMiddleDownObj := ObjBindMethod(this, "ExecuteMiddleDown")

        this.HoldTimerObj := ObjBindMethod(this, "ExecuteHold")
        this.DebounceTimer := ObjBindMethod(this, "ReleaseFingers")
        this.TapTimerObj := ObjBindMethod(this, "ExecuteTap")

        ; Coordinates from every device are rescaled into 0..NormRange
        ; (think "permille of full pad travel") so Threshold/Divisor
        ; defaults mean roughly the same thing on a tiny ultrabook pad
        ; and a huge 17" laptop pad.
        this.NormRange := 1000

        ; Off by default. If HID auto-detection fails for a device, the
        ; engine disables gestures for it and warns, rather than guessing.
        ; Set TP.AllowLegacyFallback := true (after construction, before
        ; anything else) to instead fall back to the original hand-coded
        ; report layout (report ID 0x04, fixed byte offsets) as a last
        ; resort - only useful if you know your exact device matches that
        ; original layout. Note: the glitch-rejection guard in
        ; UpdateTracking() assumes normalized (0..NormRange) coordinates, so
        ; it's a no-op in practice under legacy mode (raw device units).
        this.AllowLegacyFallback := false

        ; How the reported point is computed each report, when a device
        ; passed HID auto-detection ("hid" mode). Three options in total,
        ; counting AllowLegacyFallback above as the third:
        ;   "multi"  (default) - average every currently-touching finger's
        ;             position. Smooths out a single glitchy/lifting finger.
        ;   "single" - just use the first finger position found each report
        ;             and ignore the rest. Simpler, slightly more "raw" feel
        ;             for panning; more exposed to a single finger's noise.
        this.TrackingMode := "multi"

        ; --- Tunables (safe to change from main.ahk right after construction) ---
        ; A touch sequence counts as a Tap only if released within this many ms.
        ; Bump this up if fast finger counts (3-4+) routinely feel "too slow" to
        ; register as taps for you - see the note on OnHold() below.
        this.MaxTapDuration := 400
        ; While a Hold handler is armed, moving more than this (0..NormRange
        ; units) cancels the hold instead of firing it.
        this.HoldCancelDistance := 25
        ; A touch sequence counts as a Tap only if its recorded movement
        ; stays under (finger count * this value). More fingers naturally
        ; drift a little more (each one lands/lifts at a slightly different
        ; instant), so the allowance scales with finger count. This MUST
        ; stay comfortably below OnSwipe's default `threshold` - Swipe is
        ; checked continuously while a touch is down and fires the instant
        ; it's crossed, so if the two ranges overlap, ordinary tap jitter
        ; gets hijacked into a Swipe before you've even released, and the
        ; Tap can never fire for that touch.
        this.TapDistancePerFinger := 55
        ; Double (and triple) taps: the next tap has to touch down within this many ms
        ; of the previous one lifting. Measured lift to touch-down, so how long the pad
        ; takes to go quiet (WatchdogMs) doesn't eat into it. A lone tap waits this long
        ; before it fires, but only when a double-tap is set up for that finger count.
        this.DoubleTapMs := 350
        ; Edge swipes: how close to the edge (0..NormRange) the outermost finger has to start.
        this.EdgeZone := 110
        ; Precision touchpads stop sending reports once every finger is up, and many
        ; never send a report that says "0 contacts". So a touch also ends when no
        ; report has arrived for WatchdogMs. Raise it (250-300) if a Hold ever ends early.
        this.WatchdogMs := 150
        this.WatchdogObj := ObjBindMethod(this, "OnWatchdog")
        this.LastActiveTick := 0
        ; Every finger on the pad, by Contact ID: {x, y, t}. A finger that hasn't been
        ; reported for ContactStaleMs has lifted (pads report every touching finger in
        ; every frame, ~8 ms apart). FrameLeft: how many contacts the current frame
        ; still has to deliver (a frame can be split over several reports).
        ; false = gestures paused (the touchpad keeps working as normal). See Pause().
        this.Enabled := true
        this.ReportCount := 0
        this.Contacts := Map()
        this.ContactStaleMs := 60
        this.FrameLeft := 0

        this.Devices := Map()          ; hDevice -> detected layout info
        this.WarnedDevices := Map()    ; hDevice -> true once we've warned about it
        this.Diagnostics := []         ; log of what was detected, for GetDiagnosticsText()

        this.RegisterTrackpad()
    }
    ; ===================================================================
    ; EXPOSED API  (unchanged - existing scripts keep working as-is)
    ; ===================================================================
    ; threshold's default is kept well above TapDistancePerFinger * a
    ; realistic finger count so ordinary tap jitter can never cross into
    ; swipe territory (see the comment on TapDistancePerFinger above).
    ; from = "edge": only a swipe that starts at the edge it moves away from (a swipe right that starts
    ; at the pad's left edge...). It wins over an ordinary swipe the same way, which then skips it.
    OnSwipe(fingers, direction, onTrigger, targetApps := "*", condition := "", threshold := 320, from := "") {
        this.Handlers.Push({Type: "Swipe", Fingers: fingers, Direction: StrLower(direction), OnTrigger: onTrigger, Apps: targetApps, Condition: condition, Threshold: threshold, From: from})
    }
    ; did this touch start at the edge a swipe in dir moves away from? (the outermost finger, within EdgeZone)
    StartsAtEdge(dir) {
        z := this.EdgeZone, r := this.NormRange
        switch dir {
            case "right": return this.StartMinX <= z
            case "left": return this.StartMaxX >= r - z
            case "down": return this.StartMinY <= z
            case "up": return this.StartMaxY >= r - z
        }
        return false
    }
    OnPan(fingers, onDown, onMove, onUp, targetApps := "*", condition := "", divisor := 4) {
        this.Handlers.Push({Type: "Pan", Fingers: fingers, OnDown: onDown, OnMove: onMove, OnUp: onUp, Apps: targetApps, Condition: condition, Divisor: divisor})
    }
    ; NOTE: a Tap only fires if you release within this.MaxTapDuration (350ms
    ; by default). If you also register OnHold() for the *same* finger count,
    ; keep timeMs comfortably above MaxTapDuration (e.g. 700+) - otherwise a
    ; tap that's just a bit slow can fall into a dead zone (duration passed
    ; MaxTapDuration but hasn't reached timeMs yet -> nothing fires), and a
    ; slower one still can trigger the Hold before you've even lifted your
    ; fingers, instead of the Tap you were going for.
    OnTap(fingers, clicks, onTrigger, targetApps := "*", condition := "", maxDist := 0) {
        this.Handlers.Push({Type: "Tap", Fingers: fingers, Clicks: clicks, OnTrigger: onTrigger, Apps: targetApps, Condition: condition, MaxDist: maxDist})
    }
    OnHold(fingers, onTrigger, timeMs := 500, targetApps := "*", condition := "") {
        this.Handlers.Push({Type: "Hold", Fingers: fingers, OnTrigger: onTrigger, Time: timeMs, Apps: targetApps, Condition: condition})
    }
    OnPinch(onIn, onOut, targetApps := "*", condition := "") {
        this.OnPinchDir("in", onIn, targetApps, condition)
        this.OnPinchDir("out", onOut, targetApps, condition)
    }
    ; A pinch reaches Windows as Ctrl + wheel. Any number of these can be set up (per app, per
    ; condition); a pinch none of them wants, and a real Ctrl + wheel (Ctrl physically held),
    ; goes through untouched, so zooming keeps working everywhere else.
    OnPinchDir(dir, onTrigger, targetApps := "*", condition := "") {
        this.Handlers.Push({Type: "Pinch", Direction: dir, OnTrigger: onTrigger, Apps: targetApps, Condition: condition})
        if !this.HasOwnProp("_pinchHooked") {
            this._pinchHooked := true
            Hotkey("^WheelUp",   (*) => this.CheckPinchDir("out"), "On")     ; fingers apart: zoom in = wheel up
            Hotkey("^WheelDown", (*) => this.CheckPinchDir("in"), "On")
        }
    }
    CheckPinchDir(dir) {
        if !GetKeyState("Ctrl", "P") {
            activeExe := ""
            try activeExe := StrLower(WinGetProcessName("A"))
            for h in this.Handlers
                if h.Type == "Pinch" && h.Direction == dir && this.MatchesApp(h.Apps, activeExe) && this.EvaluateCondition(h.Condition)
                    return h.OnTrigger.Call()
        }
        Send("{Ctrl down}" (dir == "in" ? "{WheelDown}" : "{WheelUp}") "{Ctrl up}")
    }
    OnMiddlePan(fingers, targetApps := "*", condition := "", divisor := 4) {
        this.OnPan(fingers, ObjBindMethod(this, "MiddlePanDown"), ObjBindMethod(this, "MiddlePanMove"), ObjBindMethod(this, "MiddlePanUp"), targetApps, condition, divisor)
    }
    OnScroll(fingers, targetApps := "*", condition := "", divisor := 10) {
        this.OnPan(fingers, () => "", ObjBindMethod(this, "ScrollMove"), () => "", targetApps, condition, divisor)
    }
    CheckPinch(callback, targetApps, condition) {
        activeExe := ""
        try {
            activeExe := StrLower(WinGetProcessName("A"))
        }

        if (this.MatchesApp(targetApps, activeExe) && this.EvaluateCondition(condition)) {
            callback.Call()
        } else {
            Send("{Ctrl down}" (A_ThisHotkey == "^WheelDown" ? "{WheelDown}" : "{WheelUp}") "{Ctrl up}")
        }
    }
    SetState(name, value) {
        this.States[name] := value
    }
    ToggleState(name) {
        this.States[name] := !(this.States.Has(name) ? this.States[name] : false)
    }
    GetState(name) {
        return this.States.Has(name) ? this.States[name] : false
    }
    ; Human-readable summary of every touchpad device seen so far and what
    ; layout (if any) was auto-detected for it. Handy for a tray menu item
    ; or MsgBox. See also TrackpadCalibrator.ahk for a live/interactive view.
    GetDiagnosticsText() {
        if (this.Diagnostics.Length == 0) {
            return "No touchpad HID activity received yet. Touch the trackpad, then check again."
        }
        out := ""
        for d in this.Diagnostics {
            out .= Format("VID_{1:04X}&PID_{2:04X}  Mode={3}  ReportID={4}  FingerSlots={5}  X[{6}..{7}]  Y[{8}..{9}]`n"
                , d.VendorId, d.ProductId, d.Mode, d.ReportID, d.FingerSlots, d.LogicalMinX, d.LogicalMaxX, d.LogicalMinY, d.LogicalMaxY)
        }
        return out
    }
    ; ===================================================================
    ; HARDWARE ENGINE - device discovery & HID descriptor parsing
    ; ===================================================================
    ; Pause(true) stops gestures (the pad keeps working as a pad); Pause(false) resumes;
    ; Pause() toggles. Returns true while paused.
    Pause(on := "") {
        this.Enabled := on = "" ? !this.Enabled : !on
        if !this.Enabled
            this.OnWatchdog()
        return !this.Enabled
    }
    RegisterTrackpad() {
        rid := Buffer(16, 0)
        NumPut("UShort", 0x0D, rid, 0)          ; UsagePage = Digitizer
        NumPut("UShort", 0x05, rid, 2)          ; Usage = Touch Pad
        NumPut("UInt", 0x00000100, rid, 4)      ; RIDEV_INPUTSINK
        NumPut("UPtr", A_ScriptHwnd, rid, 8)

        if (!DllCall("RegisterRawInputDevices", "Ptr", rid.Ptr, "UInt", 1, "UInt", 16)) {
            if this.Quiet
                throw Error("Windows refused to share the touchpad's input")
            MsgBox("Failed to register for touchpad raw input. This script cannot continue.", "TrackpadLib", "IconX")
            ExitApp
        }
        OnMessage(0x00FF, ObjBindMethod(this, "OnRawInput"))

        ; Windows 11 slows the timers of background processes on battery ("power
        ; throttling"). Taps and holds are decided by timers, so opt this script out.
        try {
            st := Buffer(12, 0)
            NumPut("UInt", 1, st, 0), NumPut("UInt", 1, st, 4), NumPut("UInt", 0, st, 8)   ; version 1, control EXECUTION_SPEED, state off
            DllCall("SetProcessInformation", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "Int", 4, "Ptr", st, "UInt", 12)
        }

        ; One-off startup check: is there even a PTP-class touchpad here?
        if !this.Quiet
            SetTimer(ObjBindMethod(this, "CheckForTouchpad"), -1500)
    }
    CheckForTouchpad() {
        try {
            found := this.EnumerateTouchpadDevices()
        } catch {
            return
        }
        if (found.Length == 0) {
            TrayTip("Trackpad Gestures", "No Windows Precision Touchpad (PTP) device was detected on this "
                . "machine. This script needs a PTP-certified touchpad (Device Manager > Human Interface "
                . "Devices should list one) to read multi-finger gestures - older/legacy touchpad drivers "
                . "are not supported.", 0x30)
        }
    }
    ; Enumerate every raw HID device and return hDevice handles that identify
    ; as Digitizer/Touch Pad (usage page 0x0D, usage 0x05).
    EnumerateTouchpadDevices() {
        list := []
        itemSize := A_PtrSize = 8 ? 16 : 8      ; sizeof(RAWINPUTDEVICELIST)
        cnt := 0
        ret := DllCall("GetRawInputDeviceList", "Ptr", 0, "UIntP", &cnt, "UInt", itemSize, "Int")
        if (ret < 0 || cnt = 0) {
            return list
        }
        buf := Buffer(itemSize * cnt, 0)
        got := DllCall("GetRawInputDeviceList", "Ptr", buf.Ptr, "UIntP", &cnt, "UInt", itemSize, "Int")
        if (got < 0) {
            return list
        }
        Loop got {
            base := (A_Index - 1) * itemSize
            hDevice := NumGet(buf, base, "UPtr")
            dwType := NumGet(buf, base + A_PtrSize, "UInt")
            if (dwType != 2) {                  ; RIM_TYPEHID
                continue
            }
            info := this.GetDeviceInfo(hDevice)
            if (info.UsagePage = 0x0D && info.Usage = 0x05) {
                list.Push(hDevice)
            }
        }
        return list
    }
    GetDeviceInfo(hDevice) {
        result := {UsagePage: 0, Usage: 0, VendorId: 0, ProductId: 0}
        size := 0
        DllCall("GetRawInputDeviceInfoW", "Ptr", hDevice, "UInt", 0x2000000B, "Ptr", 0, "UIntP", &size, "Int")
        if (size = 0) {
            return result
        }
        buf := Buffer(size, 0)
        NumPut("UInt", size, buf, 0)            ; RID_DEVICE_INFO.cbSize must be preset
        r := DllCall("GetRawInputDeviceInfoW", "Ptr", hDevice, "UInt", 0x2000000B, "Ptr", buf.Ptr, "UIntP", &size, "Int")
        if (r < 0) {
            return result
        }
        result.VendorId  := NumGet(buf, 8,  "UInt")
        result.ProductId := NumGet(buf, 12, "UInt")
        result.UsagePage := NumGet(buf, 20, "UShort")
        result.Usage     := NumGet(buf, 22, "UShort")
        return result
    }
    ; Read the device's HID report descriptor (via its preparsed data) and
    ; work out where Contact Count lives, and where every finger's X/Y live.
    ; Two different real-world descriptor styles are handled:
    ;   "single"  - one X/Y pair per finger, each in its own Link Collection
    ;               (multiple HIDP_VALUE_CAPS entries, one per finger).
    ;   "array"   - ONE X field and ONE Y field, each with ReportCount > 1,
    ;               packing every finger's coordinate back-to-back in the
    ;               same field (one HIDP_VALUE_CAPS entry covers all
    ;               fingers). This is what your Elan pad turned out to use -
    ;               reading it with plain HidP_GetUsageValue only ever
    ;               returns element 0, which is why tracking looked like it
    ;               was randomly jumping between fingers.
    ; See FingerCollections below - each entry records which style it is.
    DetectLayout(hDevice) {
        layout := {Mode: "none", ReportID: 0, CountLinkCollection: 0, XYLinkCollection: 0xFFFF
            , LogicalMinX: 0, LogicalMaxX: 0, LogicalMinY: 0, LogicalMaxY: 0
            , InputReportByteLength: 0, PreparsedData: "", FingerCollections: []}
        try {
            size := 0
            DllCall("GetRawInputDeviceInfoW", "Ptr", hDevice, "UInt", 0x20000005, "Ptr", 0, "UIntP", &size, "Int")
            if (size = 0) {
                return this.MaybeLegacy(layout)
            }
            ppd := Buffer(size, 0)
            if (DllCall("GetRawInputDeviceInfoW", "Ptr", hDevice, "UInt", 0x20000005, "Ptr", ppd.Ptr, "UIntP", &size, "Int") < 0) {
                return this.MaybeLegacy(layout)
            }

            capsBuf := Buffer(64, 0)
            if (DllCall("hid.dll\HidP_GetCaps", "Ptr", ppd.Ptr, "Ptr", capsBuf.Ptr, "Int") != 0x00110000) {
                return this.MaybeLegacy(layout)
            }
            layout.InputReportByteLength := NumGet(capsBuf, 4, "UShort")
            numValueCaps := NumGet(capsBuf, 48, "UShort")
            if (numValueCaps = 0) {
                return this.MaybeLegacy(layout)
            }

            vcSize := 72                        ; sizeof(HIDP_VALUE_CAPS)
            vcBuf := Buffer(vcSize * numValueCaps, 0)
            vcLen := numValueCaps
            status := DllCall("hid.dll\HidP_GetValueCaps", "Int", 0, "Ptr", vcBuf.Ptr, "UShortP", &vcLen, "Ptr", ppd.Ptr, "Int")
            if (status != 0x00110000 || vcLen = 0) {
                return this.MaybeLegacy(layout)
            }

            ; Collect Contact Count, plus every X and every Y field
            ; (including their BitSize/ReportCount, needed to tell a plain
            ; single value apart from a packed array of them).
            foundCount := false
            xEntries := []
            yEntries := Map()   ; LinkCollection -> {LogicalMinY, LogicalMaxY, BitSize, ReportCount}
            idEntries := Map()  ; LinkCollection -> BitSize of its Contact ID field
            Loop vcLen {
                base := (A_Index - 1) * vcSize
                usagePage   := NumGet(vcBuf, base + 0,  "UShort")
                reportId    := NumGet(vcBuf, base + 2,  "UChar")
                linkColl    := NumGet(vcBuf, base + 6,  "UShort")
                bitSize     := NumGet(vcBuf, base + 18, "UShort")
                reportCount := NumGet(vcBuf, base + 20, "UShort")
                logMin      := NumGet(vcBuf, base + 40, "Int")
                logMax      := NumGet(vcBuf, base + 44, "Int")
                usage       := NumGet(vcBuf, base + 56, "UShort")   ; Range.UsageMin == NotRange.Usage offset

                if (!foundCount && usagePage = 0x0D && usage = 0x54) {         ; Digitizer / Contact Count
                    layout.ReportID := reportId
                    layout.CountLinkCollection := linkColl
                    foundCount := true
                } else if (usagePage = 0x01 && usage = 0x30) {                 ; Generic Desktop / X
                    xEntries.Push({LinkCollection: linkColl, LogicalMinX: logMin, LogicalMaxX: logMax
                        , BitSize: bitSize, ReportCount: Max(reportCount, 1), ReportID: reportId})
                } else if (usagePage = 0x0D && usage = 0x51) {                 ; Digitizer / Contact ID
                    idEntries[linkColl] := bitSize
                } else if (usagePage = 0x01 && usage = 0x31) {                 ; Generic Desktop / Y
                    yEntries[linkColl] := {LogicalMinY: logMin, LogicalMaxY: logMax
                        , BitSize: bitSize, ReportCount: Max(reportCount, 1)}
                }
            }

            fingerCollections := []
            for xe in xEntries {
                if (!yEntries.Has(xe.LinkCollection)) {
                    continue
                }
                ye := yEntries[xe.LinkCollection]
                if (xe.LogicalMaxX <= xe.LogicalMinX || ye.LogicalMaxY <= ye.LogicalMinY) {
                    continue
                }
                count := Max(xe.ReportCount, ye.ReportCount)
                fingerCollections.Push({Mode: (count > 1 ? "array" : "single"), LinkCollection: xe.LinkCollection
                    , Count: count, BitSizeX: xe.BitSize, BitSizeY: ye.BitSize
                    , LogicalMinX: xe.LogicalMinX, LogicalMaxX: xe.LogicalMaxX
                    , LogicalMinY: ye.LogicalMinY, LogicalMaxY: ye.LogicalMaxY
                    , IdBits: idEntries.Has(xe.LinkCollection) ? idEntries[xe.LinkCollection] : 0})
                if (layout.ReportID = 0) {
                    layout.ReportID := xe.ReportID
                }
            }

            if (foundCount && fingerCollections.Length > 0) {
                layout.Mode := "hid"
                layout.PreparsedData := ppd     ; keep the Buffer object alive for the life of this layout
                layout.FingerCollections := fingerCollections
                first := fingerCollections[1]
                layout.XYLinkCollection := first.LinkCollection   ; kept for diagnostics/back-compat only
                layout.LogicalMinX := first.LogicalMinX
                layout.LogicalMaxX := first.LogicalMaxX
                layout.LogicalMinY := first.LogicalMinY
                layout.LogicalMaxY := first.LogicalMaxY
                return layout
            }
        } catch {
            ; fall through to legacy/none below
        }
        return this.MaybeLegacy(layout)
    }
    ; Extract the `index`-th (0-based) value from a tightly bit-packed array
    ; buffer as filled in by HidP_GetUsageValueArray - per Microsoft's docs,
    ; elements are packed back-to-back with NO byte alignment between them,
    ; least-significant-bit first.
    ExtractPackedValue(buf, index, bitSize) {
        bitOffset := index * bitSize
        byteStart := bitOffset // 8
        bitShift := Mod(bitOffset, 8)
        needBytes := (bitShift + bitSize + 7) // 8
        chunk := 0
        Loop needBytes {
            b := byteStart + A_Index - 1
            if (b < buf.Size) {
                chunk |= NumGet(buf, b, "UChar") << (8 * (A_Index - 1))
            }
        }
        return (chunk >> bitShift) & ((1 << bitSize) - 1)
    }
    ; Wrapper around HidP_GetUsageValueArray - returns a Buffer on success,
    ; "" on failure (usage not present as an array on this device/field).
    TryReadUsageArray(preparsedPtr, usagePage, linkCollection, usage, subPtr, dwSizeHid, bitSize, count) {
        byteLen := (bitSize * count + 7) // 8
        if (byteLen <= 0) {
            return ""
        }
        buf := Buffer(byteLen, 0)
        status := DllCall("hid.dll\HidP_GetUsageValueArray", "Int", 0, "UShort", usagePage, "UShort", linkCollection
            , "UShort", usage, "Ptr", buf.Ptr, "UShort", byteLen, "Ptr", preparsedPtr, "Ptr", subPtr, "UInt", dwSizeHid, "Int")
        return (status = 0x00110000) ? buf : ""
    }
    MaybeLegacy(layout) {
        if (this.AllowLegacyFallback) {
            layout.Mode := "legacy"
        }
        return layout
    }
    LogDiagnostic(hDevice, layout) {
        try {
            devInfo := this.GetDeviceInfo(hDevice)
        } catch {
            devInfo := {VendorId: 0, ProductId: 0}
        }
        this.Diagnostics.Push({VendorId: devInfo.VendorId, ProductId: devInfo.ProductId, Mode: layout.Mode
            , ReportID: layout.ReportID, LogicalMinX: layout.LogicalMinX, LogicalMaxX: layout.LogicalMaxX
            , LogicalMinY: layout.LogicalMinY, LogicalMaxY: layout.LogicalMaxY
            , FingerSlots: layout.FingerCollections.Length})
    }
    ; ===================================================================
    ; HARDWARE ENGINE - live parsing
    ; ===================================================================
    OnRawInput(wParam, lParam, msg, hwnd) {
        Critical
        if !this.Enabled
            return
        this.ReportCount += 1               ; for a reports-per-second readout (the calibrator, Reach)
        static headerSize := A_PtrSize = 8 ? 24 : 16
        size := 0
        DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", 0, "UIntP", &size, "UInt", headerSize)

        if (!size) {
            return
        }
        rawBuf := Buffer(size, 0)
        if (DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", rawBuf, "UIntP", &size, "UInt", headerSize) != size) {
            return
        }

        if (NumGet(rawBuf, 0, "UInt") != 2) {   ; RIM_TYPEHID
            return
        }
        hDevice := NumGet(rawBuf, 8, "UPtr")

        if (!this.Devices.Has(hDevice)) {
            layout := this.DetectLayout(hDevice)
            this.Devices[hDevice] := layout
            this.LogDiagnostic(hDevice, layout)
        }
        layout := this.Devices[hDevice]

        if (layout.Mode = "none") {
            if (!this.WarnedDevices.Has(hDevice)) {
                this.WarnedDevices[hDevice] := true
                if !this.Quiet
                TrayTip("Trackpad Gestures", "A touchpad HID device was found, but its report layout could "
                    . "not be auto-detected (non-standard / non-PTP descriptor). Gestures are disabled for "
                    . "it. Run TrackpadCalibrator.ahk to inspect it, or set TP.AllowLegacyFallback := true "
                    . "to try the old hard-coded layout.", 0x30)
            }
            return
        }

        dwSizeHid := NumGet(rawBuf, headerSize, "UInt")
        dwCount    := NumGet(rawBuf, headerSize + 4, "UInt")
        if (!dwSizeHid || !dwCount) {
            return
        }
        pRawData := rawBuf.Ptr + headerSize + 8
        SetTimer(this.WatchdogObj, -this.WatchdogMs)

        if (layout.Mode = "legacy") {
            this.ProcessLegacyReport(pRawData, dwSizeHid, dwCount)
            return
        }

        ; --- Universal HID-descriptor-driven path ---
        ; Each report updates the fingers it carries, tracked by Contact ID. The hand is
        ; then reported as one: how many fingers are down and the middle of them. That
        ; works whether the pad sends a frame as one report or one report per finger
        ; (only the first of those carries Contact Count), and the position no longer
        ; jumps when a different finger happens to come first.
        Loop dwCount {
            subPtr := pRawData + (A_Index - 1) * dwSizeHid
            if (layout.ReportID != 0 && NumGet(subPtr, 0, "UChar") != layout.ReportID)
                continue
            this.ReadContacts(layout, subPtr, dwSizeHid)
        }
        this.ReportContacts()
    }
    ReadContacts(layout, subPtr, len) {
        ppd := layout.PreparsedData.Ptr, now := A_TickCount
        cVal := 0
        DllCall("hid.dll\HidP_GetUsageValue", "Int", 0, "UShort", 0x0D, "UShort", layout.CountLinkCollection
            , "UShort", 0x54, "UIntP", &cVal, "Ptr", ppd, "Ptr", subPtr, "UInt", len, "Int")
        if (cVal > 0) {
            this.FrameLeft := cVal              ; a new frame: this many contacts follow
        } else if (this.FrameLeft <= 0) {
            this.Contacts.Clear()               ; a frame of its own saying "no contacts"
            return
        }
        for fc in layout.FingerCollections {
            if (this.FrameLeft <= 0)
                break
            if (fc.Mode = "array") {
                xBuf := this.TryReadUsageArray(ppd, 0x01, fc.LinkCollection, 0x30, subPtr, len, fc.BitSizeX, fc.Count)
                yBuf := this.TryReadUsageArray(ppd, 0x01, fc.LinkCollection, 0x31, subPtr, len, fc.BitSizeY, fc.Count)
                idBuf := fc.IdBits ? this.TryReadUsageArray(ppd, 0x0D, fc.LinkCollection, 0x51, subPtr, len, fc.IdBits, fc.Count) : ""
                if (xBuf = "" || yBuf = "")
                    continue
                Loop fc.Count {
                    if (this.FrameLeft <= 0)
                        break
                    this.FrameLeft--
                    idx := A_Index - 1
                    id := idBuf != "" ? this.ExtractPackedValue(idBuf, idx, fc.IdBits) : "slot" idx
                    this.SetContact(fc, id, this.ExtractPackedValue(xBuf, idx, fc.BitSizeX), this.ExtractPackedValue(yBuf, idx, fc.BitSizeY), now)
                }
            } else {
                this.FrameLeft--
                xVal := 0, yVal := 0, idVal := 0
                sx := DllCall("hid.dll\HidP_GetUsageValue", "Int", 0, "UShort", 0x01, "UShort", fc.LinkCollection
                    , "UShort", 0x30, "UIntP", &xVal, "Ptr", ppd, "Ptr", subPtr, "UInt", len, "Int")
                sy := DllCall("hid.dll\HidP_GetUsageValue", "Int", 0, "UShort", 0x01, "UShort", fc.LinkCollection
                    , "UShort", 0x31, "UIntP", &yVal, "Ptr", ppd, "Ptr", subPtr, "UInt", len, "Int")
                id := "lc" fc.LinkCollection
                if (fc.IdBits && DllCall("hid.dll\HidP_GetUsageValue", "Int", 0, "UShort", 0x0D, "UShort", fc.LinkCollection
                        , "UShort", 0x51, "UIntP", &idVal, "Ptr", ppd, "Ptr", subPtr, "UInt", len, "Int") = 0x00110000)
                    id := idVal
                if (sx = 0x00110000 && sy = 0x00110000)
                    this.SetContact(fc, id, xVal, yVal, now)
            }
        }
    }
    SetContact(fc, id, xVal, yVal, now) {
        this.Contacts[id] := {x: (xVal - fc.LogicalMinX) / (fc.LogicalMaxX - fc.LogicalMinX) * this.NormRange
            , y: (yVal - fc.LogicalMinY) / (fc.LogicalMaxY - fc.LogicalMinY) * this.NormRange, t: now}
    }
    ; the fingers still down (reported within ContactStaleMs), as one hand
    ReportContacts() {
        now := A_TickCount, gone := []
        for id, c in this.Contacts
            if (now - c.t > this.ContactStaleMs)
                gone.Push(id)
        for id in gone
            this.Contacts.Delete(id)
        n := this.Contacts.Count
        if (n = 0) {
            this.ProcessData(1, 0, this.LastX, this.LastY)
            return
        }
        x := 0.0, y := 0.0
        for id, c in this.Contacts {
            if (this.TrackingMode = "single")
                return this.ProcessData(3, n, c.x, c.y)     ; the lowest contact id: always the same finger
            x += c.x, y += c.y
        }
        this.ProcessData(3, n, x / n, y / n)
    }
    ; Original hard-coded layout (Report ID 0x04, fixed byte offsets), kept
    ; only as an explicit opt-in fallback (TP.AllowLegacyFallback := true)
    ; for the exact device the original script was reverse-engineered from.
    ProcessLegacyReport(pRawData, dwSizeHid, dwCount) {
        if (dwSizeHid * dwCount < 12) {
            return
        }
        if (NumGet(pRawData, 0, "UChar") != 0x04) {
            return
        }
        contactAndState := NumGet(pRawData, 1, "UChar")
        if (((contactAndState & 0xF0) >> 4) != 0) {
            return
        }
        this.ProcessData(contactAndState & 0x0F, NumGet(pRawData, 8, "UChar"), NumGet(pRawData, 2, "Short"), NumGet(pRawData, 4, "Short"))
    }
    ProcessData(state, countByte, x, y) {
        if (countByte > 0 && state == 3) {
            SetTimer(this.DebounceTimer, 0)
            this.LastActiveTick := A_TickCount
            if (this.IsTracking && countByte > this.MaxFingers) {
                this.MaxFingers := countByte
            }
            if (!this.IsTracking) {
                if (countByte >= this.LastFingers) {
                    this.CurrentFingers := countByte
                    this.StartTracking(x, y)
                }
            }
            else {
                if (countByte > this.CurrentFingers) {
                    this.CurrentFingers := countByte
                    this.StartTracking(x, y)
                }
                else if (countByte == this.CurrentFingers) {
                    this.UpdateTracking(x, y)
                }
                ; else: countByte < CurrentFingers - one or more fingers have
                ; started lifting off while others are still down. Ignore
                ; position samples until either the full set is back down or
                ; the touch fully releases: a partially-lifted contact's
                ; coordinate is unreliable (it can jump/zero out) and would
                ; otherwise spike MaxDist right as a tap/hold is ending,
                ; making it register as a swipe or missing Tap eligibility
                ; entirely.
            }

            this.LastFingers := countByte
        }
        else if (countByte == 0 || state == 1) {
            this.LastFingers := countByte
            if (this.IsTracking) {
                SetTimer(this.DebounceTimer, -80)
            }
        }
    }
    StartTracking(x, y) {
        for handler in this.ActiveHandlers {
            if (handler.Type == "Pan") {
                handler.OnUp.Call()
            }
        }
        this.ActiveHandlers := this.FindMatchingHandlers(this.CurrentFingers)

        ; Priority System: If a Pan/Scroll matched the current app, suppress Swipes.
        hasPan := false
        for handler in this.ActiveHandlers {
            if (handler.Type == "Pan") {
                hasPan := true
                break
            }
        }

        if (hasPan) {
            filteredHandlers := []
            for handler in this.ActiveHandlers {
                if (handler.Type != "Swipe") {
                    filteredHandlers.Push(handler)
                }
            }
            this.ActiveHandlers := filteredHandlers
        }
        if (this.TapCount > 0) {
            SetTimer(this.TapTimerObj, 0)
        }
        this.IsTracking := true
        this.MaxFingers := this.CurrentFingers
        this.StartMinX := x, this.StartMaxX := x, this.StartMinY := y, this.StartMaxY := y
        for id, c in this.Contacts
            this.StartMinX := Min(this.StartMinX, c.x), this.StartMaxX := Max(this.StartMaxX, c.x),
            this.StartMinY := Min(this.StartMinY, c.y), this.StartMaxY := Max(this.StartMaxY, c.y)
        this.LastX := x
        this.LastY := y
        this.StartX := x
        this.StartY := y
        this.StartTime := A_TickCount
        this.MaxDist := 0
        this.HasMoved := false
        this.HasTriggeredSwipe := false
        this.ActiveHoldHandler := ""
        if (GetKeyState("Alt", "P")) {
            Send("{Blind}{vkE8}")
        }
        if (this.ActiveHandlers.Length == 0) {
            this.IsTracking := false
            return
        }
        for handler in this.ActiveHandlers {
            if (handler.Type == "Pan") {
                handler.AccumX := 0.0
                handler.AccumY := 0.0
                handler.OnDown.Call()
            } else if (handler.HasProp("HasTriggered")) {
                handler.HasTriggered := false
            } else if (handler.Type == "Hold") {
                this.ActiveHoldHandler := handler
                SetTimer(this.HoldTimerObj, -handler.Time)
            }
        }
    }
    UpdateTracking(x, y) {
        ; Guard against single-sample sensor glitches (e.g. a contact slot
        ; briefly reporting 0,0 or a stale value). A real human motion can't
        ; jump across half the pad between two consecutive HID reports -
        ; treat anything that large as noise and just ignore that sample.
        step := Sqrt((x - this.LastX)**2 + (y - this.LastY)**2)
        if (step > this.NormRange * 0.5) {
            return
        }

        dx := x - this.StartX
        dy := y - this.StartY
        dist := Sqrt(dx**2 + dy**2)

        if (dist > this.MaxDist) {
            this.MaxDist := dist
        }
        if (this.ActiveHoldHandler != "" && dist > this.HoldCancelDistance) {
            SetTimer(this.HoldTimerObj, 0)
            this.ActiveHoldHandler := ""
        }
        for handler in this.ActiveHandlers {
            if (handler.Type == "Pan") {
                moveX := Integer((handler.AccumX += (x - this.LastX) / handler.Divisor))
                moveY := Integer((handler.AccumY += (y - this.LastY) / handler.Divisor))

                if (moveX != 0 || moveY != 0) {
                    handler.OnMove.Call(moveX, moveY)
                    handler.AccumX -= moveX
                    handler.AccumY -= moveY
                    this.HasMoved := true
                }
            }
            else if (handler.Type == "Swipe" && !this.HasTriggeredSwipe && dist > handler.Threshold) {
                isMatch := false
                if (Abs(dx) > Abs(dy)) {
                    if ((handler.Direction == "right" && dx > 0) || (handler.Direction == "left" && dx < 0)) {
                        isMatch := true
                    }
                } else {
                    if ((handler.Direction == "down" && dy > 0) || (handler.Direction == "up" && dy < 0)) {
                        isMatch := true
                    }
                }

                if (isMatch && handler.HasOwnProp("From") && handler.From == "edge") {
                    isMatch := this.StartsAtEdge(handler.Direction)
                } else if (isMatch && this.StartsAtEdge(handler.Direction)) {
                    for other in this.ActiveHandlers
                        if (other.Type == "Swipe" && other.HasOwnProp("From") && other.From == "edge" && other.Direction == handler.Direction) {
                            isMatch := false
                            break
                        }
                }
                if (isMatch) {
                    handler.HasTriggered := true
                    handler.OnTrigger.Call()
                    this.HasTriggeredSwipe := true
                    this.HasMoved := true
                }
            }
        }

        this.LastX := x
        this.LastY := y

        if (this.HasTriggeredSwipe) {
            this.ActiveHandlers := []
        }
    }
    ; No report for WatchdogMs: every finger is up. Clears the finger state even when
    ; no gesture was being tracked, so a later touch with fewer fingers isn't ignored.
    OnWatchdog() {
        this.Contacts.Clear(), this.FrameLeft := 0
        SetTimer(this.DebounceTimer, 0)
        this.LastFingers := 0
        if (this.IsTracking)
            this.ReleaseFingers()
        this.CurrentFingers := 0, this.MaxFingers := 0
    }
    ReleaseFingers() {
        if (!this.IsTracking) {
            return
        }

        SetTimer(this.HoldTimerObj, 0)
        this.IsTracking := false
        duration := Max(0, (this.LastActiveTick ? this.LastActiveTick : A_TickCount) - this.StartTime)

        for handler in this.ActiveHandlers {
            if (handler.Type == "Pan") {
                handler.OnUp.Call()
            }
        }
        isTap := false
        maxD := this.MaxFingers * this.TapDistancePerFinger

        if (!this.HasTriggeredSwipe && duration < this.MaxTapDuration && this.MaxDist < maxD) {
            isTap := true
        }
        if (isTap) {
            maxClicksBound := 0
            for handler in this.Handlers {
                if (handler.Type == "Tap" && handler.Fingers == this.MaxFingers) {
                    if (handler.Clicks > maxClicksBound) {
                        maxClicksBound := handler.Clicks
                    }
                }
            }

            lift := this.LastActiveTick ? this.LastActiveTick : A_TickCount
            ; a tap still waiting from before that this one can't add to: it happens now
            if (this.TapCount > 0 && (this.MaxFingers != this.TapFingers || this.StartTime - this.LastTapLift >= this.DoubleTapMs)) {
                this.ExecuteTap()
            }
            if (maxClicksBound > 0) {
                if (maxClicksBound == 1) {
                    this.TapFingers := this.MaxFingers
                    this.TapCount := 1
                    this.ExecuteTap()
                } else {
                    if (this.TapCount > 0 && this.MaxFingers == this.TapFingers) {
                        this.TapCount++
                    } else {
                        this.TapFingers := this.MaxFingers
                        this.TapCount := 1
                    }

                    this.LastTapTime := A_TickCount, this.LastTapLift := lift

                    if (this.TapCount == maxClicksBound) {
                        SetTimer(this.TapTimerObj, 0)
                        this.ExecuteTap()
                    } else {
                        ; wait for another tap: DoubleTapMs from the lift, some of which has passed already
                        SetTimer(this.TapTimerObj, -Max(30, this.DoubleTapMs - (A_TickCount - lift)))
                    }
                }
            }
        } else if (this.TapCount > 0) {
            this.ExecuteTap()          ; a swipe or hold after a tap: the tap still counts
        }
        this.ActiveHandlers := []
        this.CurrentFingers := 0
    }

    ExecuteTap() {
        f := this.TapFingers
        c := this.TapCount
        this.TapFingers := 0
        this.TapCount := 0
        activeExe := ""
        try {
            activeExe := StrLower(WinGetProcessName("A"))
        }
        matched := false
        for handler in this.Handlers {
            if (handler.Type == "Tap" && handler.Fingers == f && handler.Clicks == c) {
                if (this.MatchesApp(handler.Apps, activeExe) && this.EvaluateCondition(handler.Condition)) {
                    handler.OnTrigger.Call()
                    matched := true
                    break
                }
            }
        }

        if (!matched && c > 1) {
            for handler in this.Handlers {
                if (handler.Type == "Tap" && handler.Fingers == f && handler.Clicks == 1) {
                    if (this.MatchesApp(handler.Apps, activeExe) && this.EvaluateCondition(handler.Condition)) {
                        loop c {
                            handler.OnTrigger.Call()
                        }
                        break
                    }
                }
            }
        }
    }
    ExecuteHold() {
        if (this.ActiveHoldHandler != "") {
            this.ActiveHoldHandler.OnTrigger.Call()
            this.ActiveHoldHandler := ""
            this.HasMoved := true
            this.HasTriggeredSwipe := true
        }
    }
    ; ===================================================================
    ; MATCHING & BUILT-IN ACTIONS
    ; ===================================================================
    FindMatchingHandlers(fingers) {
        activeExe := ""
        try {
            activeExe := StrLower(WinGetProcessName("A"))
        }

        matches := []
        for handler in this.Handlers {
            if (handler.HasOwnProp("Fingers") && handler.Fingers == fingers && this.MatchesApp(handler.Apps, activeExe) && this.EvaluateCondition(handler.Condition)) {
                matches.Push(handler)
            }
        }
        return matches
    }
    MatchesApp(targetApps, currentExe) {
        if (Type(targetApps) == "String") {
            if (targetApps == "*" || targetApps == "") {
                return true
            }
            targetApps := [targetApps]
        }

        for app in targetApps {
            if (StrLower(app) == currentExe) {
                return true
            }
        }
        return false
    }
    EvaluateCondition(cond) {
        if (cond == "") {
            return true
        }

        if (Type(cond) == "Func" || Type(cond) == "Closure" || Type(cond) == "BoundFunc") {
            return cond.Call()
        }

        if (Type(cond) == "String") {
            terms := StrSplit(cond, A_Space)
            for term in terms {
                if (term == "") {
                    continue
                }

                if (InStr(term, "State:") && !this.GetState(SubStr(term, 7))) {
                    return false
                }

                if (InStr(term, "Alt") && !GetKeyState("Alt", "P")) {
                    return false
                }

                if (InStr(term, "Shift") && !GetKeyState("Shift", "P")) {
                    return false
                }

                if (InStr(term, "Ctrl") && !GetKeyState("Ctrl", "P")) {
                    return false
                }

                if (InStr(term, "Win") && !(GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))) {
                    return false
                }

                if (InStr(term, "Caps") && !GetKeyState("CapsLock", "T")) {
                    return false
                }
            }
        }
        return true
    }
    MiddlePanDown() {
        now := A_TickCount
        dblTime := DllCall("GetDoubleClickTime", "UInt")

        if ((now - this.MiddleLastUp) <= dblTime || (now - this.MiddleLastDown) <= dblTime) {
            delay := Max(dblTime - (now - this.MiddleLastUp), dblTime - (now - this.MiddleLastDown)) + 20
            this.MiddlePending := true
            SetTimer(this.ExecuteMiddleDownObj, -Max(delay, 10))
        } else {
            this.ExecuteMiddleDown()
        }
    }

    ExecuteMiddleDown() {
        this.MiddlePending := false
        DllCall("mouse_event", "UInt", 0x0020, "Int", 0, "Int", 0, "UInt", 0, "UPtr", 0)
        this.MiddleLastDown := A_TickCount
    }

    MiddlePanMove(dx, dy) {
        if (!this.MiddlePending) {
            DllCall("mouse_event", "UInt", 0x0001, "Int", dx, "Int", dy, "UInt", 0, "UPtr", 0)
        }
    }

    MiddlePanUp() {
        if (this.MiddlePending) {
            SetTimer(this.ExecuteMiddleDownObj, 0)
            this.MiddlePending := false
        } else {
            DllCall("mouse_event", "UInt", 0x0040, "Int", 0, "Int", 0, "UInt", 0, "UPtr", 0)
            this.MiddleLastUp := A_TickCount
        }
    }

    ScrollMove(dx, dy) {
        if (Abs(dx) > Abs(dy)) {
            Send(dx > 0 ? "{WheelRight}" : "{WheelLeft}")
        } else {
            Send(dy > 0 ? "{WheelDown}" : "{WheelUp}")
        }
    }
}