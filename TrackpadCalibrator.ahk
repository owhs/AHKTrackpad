#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent()
#Include TrackpadLib.ahk
; ============================================================================
; TrackpadCalibrator.ahk
; ----------------------------------------------------------------------------
; A standalone diagnostic / training tool for TrackpadLib.ahk. It loads the
; exact same gesture engine your real scripts (e.g. main.ahk) use, so what
; you see here is exactly what will happen for you - it's not a simulation.
;
; What it does:
;   1. "Scan touchpad devices" reads your touchpad's HID report descriptor
;      and shows what TrackpadLib auto-detected (report ID, coordinate
;      ranges, whether it recognized the device at all).
;   2. The live monitor updates in real time as you touch the pad, so you
;      can see finger count / position / distance react immediately.
;   3. "Start Guided Test" walks you through a sequence of taps, holds,
;      swipes and a pan, and tells you which ones were actually recognized
;      - useful for confirming a new laptop works, or for figuring out
;      which gesture types need their Threshold/Time tuned in main.ahk.
;   4. "Copy Report" puts the diagnostics + full event log on the clipboard
;      so you can paste it somewhere (e.g. to ask for help tuning it).
;
; This only requires a Windows Precision Touchpad (PTP). If step 1 reports
; "Could not auto-detect a standard PTP report layout", your touchpad isn't
; PTP-class and no software trick in Raw Input can add multitouch support
; for it - that's a Windows/driver limitation, not something this script
; can work around.
; ============================================================================

TP := TrackpadManager()

; Match main.ahk's tuned feel so what you test here matches what you'll
; actually get - the library ships conservative defaults, but main.ahk
; widens the Tap window and pushes Hold further out to avoid tap/hold
; collisions (see the comment block at the top of main.ahk).
TP.MaxTapDuration := 450
HoldTimeMs := 800

Steps := [
    {Key: "TAP-2-1",       Text: "Do a 2-finger TAP"},
    {Key: "TAP-3-1",       Text: "Do a 3-finger TAP"},
    {Key: "TAP-4-1",       Text: "Do a 4-finger TAP"},
    {Key: "SWIPE-3-LEFT",  Text: "Do a 3-finger SWIPE LEFT"},
    {Key: "SWIPE-3-RIGHT", Text: "Do a 3-finger SWIPE RIGHT"},
    {Key: "SWIPE-3-UP",    Text: "Do a 3-finger SWIPE UP"},
    {Key: "SWIPE-3-DOWN",  Text: "Do a 3-finger SWIPE DOWN"},
    {Key: "SWIPE-4-LEFT",  Text: "Do a 4-finger SWIPE LEFT"},
    {Key: "HOLD-4",        Text: "Hold 4 fingers still for just under a second"},
    {Key: "PAN-2-DOWN",    Text: "Put 2 fingers down and drag them a little"},
]
StepIndex := 0
StepResults := []
RawText := ""
PendingExpectation := ""

; ---------------------------------------------------------------------------
; Wire the engine: every gesture type, across 1-5 fingers, logs to the event
; log; 2-finger Pan is used for the live-drag part of the guided test (kept
; separate from Swipe(2) since a Pan handler on a finger-count suppresses
; Swipe on that same finger-count by design - see TrackpadLib's priority
; system in StartTracking()).
; ---------------------------------------------------------------------------
Loop 5 {
    f := A_Index
    TP.OnTap(f, 1, GestureFired.Bind("TAP-" . f . "-1", f . "-finger tap"))
    TP.OnTap(f, 2, GestureFired.Bind("TAP-" . f . "-2", f . "-finger double-tap"))
    TP.OnHold(f, GestureFired.Bind("HOLD-" . f, f . "-finger hold"), HoldTimeMs)
    if (f != 2) {
        for dir in ["Left", "Right", "Up", "Down"] {
            TP.OnSwipe(f, dir, GestureFired.Bind("SWIPE-" . f . "-" . StrUpper(dir), f . "-finger swipe " . dir))
        }
    }
}
TP.OnPan(2
    , GestureFired.Bind("PAN-2-DOWN", "2-finger pan: touch down")
    , (dx, dy) => 0
    , GestureFired.Bind("PAN-2-UP", "2-finger pan: released")
)

; ---------------------------------------------------------------------------
; GUI
; ---------------------------------------------------------------------------
CalGui := Gui("+AlwaysOnTop +Resize", "Trackpad Calibrator")
CalGui.SetFont("s10", "Segoe UI")

CalGui.AddText("w640", "Uses the same TrackpadLib.ahk engine as your real scripts - this is a live test, not a simulation.")

CalGui.AddText("w640 cBlue", "1) Device detection")
BtnScan := CalGui.AddButton("w220", "Scan touchpad devices")
DiagBox := CalGui.AddEdit("w640 r6 ReadOnly -Wrap")

CalGui.AddText("w640 cBlue", "2) Live monitor - touch the pad and watch the numbers change")
StatusText := CalGui.AddText("w640 r1", "Tracking: no")

CalGui.AddText("w640 cBlue", "3) Guided test")
InstructionText := CalGui.AddText("w640 r1 cGreen", "Click 'Start Guided Test' and follow the prompts below.")
BtnGuided := CalGui.AddButton("w220", "Start Guided Test")
BtnRaw := CalGui.AddButton("w260 x+10", "Record raw touches (5 seconds)")

CalGui.AddText("w640 cBlue", "Event log")
LogEditCtrl := CalGui.AddEdit("xm w640 r12 ReadOnly -Wrap")
BtnClear := CalGui.AddButton("w150", "Clear Log")
BtnCopy := CalGui.AddButton("w150 x+10", "Copy Report")

BtnScan.OnEvent("Click", ShowDeviceInfo)
BtnGuided.OnEvent("Click", StartGuidedTest)
BtnRaw.OnEvent("Click", RecordRaw)
BtnClear.OnEvent("Click", ClearLog)
BtnCopy.OnEvent("Click", CopyReport)
CalGui.OnEvent("Close", (*) => ExitApp())
CalGui.Show()

SetTimer(UpdateStatus, 100)
ShowDeviceInfo()

; ---------------------------------------------------------------------------
; Functions
; ---------------------------------------------------------------------------
UpdateStatus() {
    global TP, StatusText
    txt := "Tracking: " . (TP.IsTracking ? "YES" : "no")
        . "     Fingers (current/max): " . TP.CurrentFingers . "/" . TP.MaxFingers
        . "     Position (0-1000): " . Round(TP.LastX) . ", " . Round(TP.LastY)
        . "     Max distance moved: " . Round(TP.MaxDist)
    StatusText.Text := txt
}

Log(msg) {
    global LogEditCtrl
    ts := FormatTime(A_Now, "HH:mm:ss")
    LogEditCtrl.Text := LogEditCtrl.Text . ts . " - " . msg . "`r`n"
    len := StrLen(LogEditCtrl.Text)
    SendMessage(0x00B1, len, len, LogEditCtrl)  ; EM_SETSEL -> caret to end
    SendMessage(0x00B7, 0, 0, LogEditCtrl)      ; EM_SCROLLCARET -> scroll to caret
}

ClearLog(*) {
    global LogEditCtrl
    LogEditCtrl.Text := ""
}

GestureFired(key, humanText) {
    global PendingExpectation
    Log(humanText)
    if (PendingExpectation != "" && key = PendingExpectation) {
        SetTimer(StepTimeout, 0)
        PendingExpectation := ""
        AdvanceStep(true)
    }
}

ShowDeviceInfo(*) {
    global TP, DiagBox
    out := ""
    try {
        devices := TP.EnumerateTouchpadDevices()
    } catch as e {
        DiagBox.Text := "Error while enumerating devices: " . e.Message
        return
    }
    if (devices.Length == 0) {
        DiagBox.Text := "No Precision Touchpad (Digitizer/Touch Pad, HID usage page 0x0D usage 0x05) device "
            . "was found on this system. Multi-finger gestures cannot work without one."
        return
    }
    for hDevice in devices {
        info := TP.GetDeviceInfo(hDevice)
        layout := TP.DetectLayout(hDevice)
        out .= Format("VID_{:04X}&PID_{:04X}`r`n", info.VendorId, info.ProductId)
        out .= "  Detected mode: " . layout.Mode . "`r`n"
        if (layout.Mode = "hid") {
            out .= "  Report ID: " . layout.ReportID . "`r`n"
            out .= "  Input report length: " . layout.InputReportByteLength . " bytes`r`n"
            out .= "  Tracking mode: " . TP.TrackingMode . "`r`n"
            for fc in layout.FingerCollections {
                if (fc.Mode = "array") {
                    out .= "  Finger field: PACKED ARRAY, " . fc.Count . " contacts in one field (LinkCollection " . fc.LinkCollection . ")`r`n"
                } else {
                    out .= "  Finger field: single contact (LinkCollection " . fc.LinkCollection . (fc.HasTip ? ", tip switch" : "") . (fc.IdBits ? ", contact id" : "") . ")`r`n"
                }
            }
            out .= "  X logical range: " . layout.LogicalMinX . " to " . layout.LogicalMaxX . "`r`n"
            out .= "  Y logical range: " . layout.LogicalMinY . " to " . layout.LogicalMaxY . "`r`n"
            out .= "  --> Gestures should work automatically on this device.`r`n`r`n"
        } else {
            out .= "  --> Could not auto-detect a standard PTP report layout for this device.`r`n"
            out .= "  --> Gestures will NOT fire here unless it's misidentified, or you enable "
                . "TP.AllowLegacyFallback (only meaningful for the exact device the old fixed-offset "
                . "code was written for).`r`n`r`n"
        }
    }
    DiagBox.Text := out
}

StartGuidedTest(*) {
    global StepIndex, StepResults
    StepIndex := 0
    StepResults := []
    Log("--- Guided test started ---")
    RunNextStep()
}

RunNextStep() {
    global Steps, StepIndex, PendingExpectation, InstructionText
    StepIndex += 1
    if (StepIndex > Steps.Length) {
        FinishGuidedTest()
        return
    }
    step := Steps[StepIndex]
    PendingExpectation := step.Key
    InstructionText.Text := "(" . StepIndex . "/" . Steps.Length . ")  " . step.Text . "   -- you have ~4 seconds"
    SetTimer(StepTimeout, -4000)
}

StepTimeout() {
    global PendingExpectation
    if (PendingExpectation != "") {
        PendingExpectation := ""
        AdvanceStep(false)
    }
}

AdvanceStep(passed) {
    global Steps, StepIndex, StepResults
    step := Steps[StepIndex]
    StepResults.Push({Key: step.Key, Text: step.Text, Passed: passed})
    Log((passed ? "PASS: " : "MISSED: ") . step.Text)
    RunNextStep()
}

FinishGuidedTest() {
    global StepResults, InstructionText
    passed := 0
    for r in StepResults {
        if (r.Passed) {
            passed += 1
        }
    }
    InstructionText.Text := "Guided test complete: " . passed . "/" . StepResults.Length . " gestures detected. See log below."
    Log("--- Guided test finished: " . passed . "/" . StepResults.Length . " passed ---")
    for r in StepResults {
        if (!r.Passed) {
            Log("  Not detected: " . r.Text . " - try again slower/faster, or widen Threshold/Time for it in main.ahk")
        }
    }
}

; Every report the pad sends for 5 seconds (count, and each finger's id and position), for
; working out why a gesture isn't recognised on a pad we don't have. Copy Report includes it.
RecordRaw(*) {
    global TP
    TP.RawLog := [], TP.RawStart := A_TickCount
    Log("--- Recording raw touches for 5 seconds: do the gesture that isn't recognised (a 3-finger swipe, say) a few times ---")
    SetTimer(StopRaw, -5000)
}
StopRaw() {
    global TP, RawText
    lines := TP.RawLog, TP.RawLog := ""
    RawText := "`r`n=== Raw touches (" . lines.Length . " reports) ===`r`n"
    for l in lines
        RawText .= l . "`r`n"
    Log("--- Recorded " . lines.Length . " reports. Copy Report includes them ---")
}

CopyReport(*) {
    global TP, DiagBox, LogEditCtrl, RawText
    report := "=== TrackpadCalibrator report ===`r`n`r`n" . DiagBox.Text . "`r`n=== Event log ===`r`n" . LogEditCtrl.Text . RawText
    A_Clipboard := report
    MsgBox("Report copied to clipboard.", "Trackpad Calibrator")
}