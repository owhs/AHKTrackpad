#Requires AutoHotkey v2.0

class TrackpadManager {
    __New() {
        this.Handlers := []
        this.ActiveHandlers := []
        this.IsTracking := false
        
        this.CurrentFingers := 0
        this.MaxFingers := 0
        this.LastFingers := 0
        this.LastX := 0
        this.LastY := 0
        this.StartX := 0
        this.StartY := 0
        
        this.StartTime := 0
        this.MaxDist := 0
        this.HasMoved := false
        this.HasTriggeredSwipe := false
        
        this.TapFingers := 0
        this.TapCount := 0
        this.LastTapTime := 0
        
        this.States := Map()
        this.ActiveHoldHandler := ""
        
        this.MiddleLastDown := 0
        this.MiddleLastUp := 0
        this.MiddlePending := false
        this.ExecuteMiddleDownObj := ObjBindMethod(this, "ExecuteMiddleDown")
        
        this.HoldTimerObj := ObjBindMethod(this, "ExecuteHold")
        this.DebounceTimer := ObjBindMethod(this, "ReleaseFingers")
        this.TapTimerObj := ObjBindMethod(this, "ExecuteTap")
        
        this.RegisterTrackpad()
    }

    ; ===================================================================
    ; EXPOSED API
    ; ===================================================================

    OnSwipe(fingers, direction, onTrigger, targetApps := "*", condition := "", threshold := 100) {
        this.Handlers.Push({Type: "Swipe", Fingers: fingers, Direction: StrLower(direction), OnTrigger: onTrigger, Apps: targetApps, Condition: condition, Threshold: threshold})
    }

    OnPan(fingers, onDown, onMove, onUp, targetApps := "*", condition := "", divisor := 6) {
        this.Handlers.Push({Type: "Pan", Fingers: fingers, OnDown: onDown, OnMove: onMove, OnUp: onUp, Apps: targetApps, Condition: condition, Divisor: divisor})
    }

    ; [NEW] 'clicks' parameter added. 1 = Single Tap, 2 = Double Tap, etc.
    OnTap(fingers, clicks, onTrigger, targetApps := "*", condition := "") {
        this.Handlers.Push({Type: "Tap", Fingers: fingers, Clicks: clicks, OnTrigger: onTrigger, Apps: targetApps, Condition: condition})
    }

    OnHold(fingers, onTrigger, timeMs := 500, targetApps := "*", condition := "") {
        this.Handlers.Push({Type: "Hold", Fingers: fingers, OnTrigger: onTrigger, Time: timeMs, Apps: targetApps, Condition: condition})
    }

    OnPinch(onIn, onOut, targetApps := "*", condition := "") {
        Hotkey("^WheelUp",   (*) => this.CheckPinch(onIn, targetApps, condition), "On")
        Hotkey("^WheelDown", (*) => this.CheckPinch(onOut, targetApps, condition), "On")
    }

    OnMiddlePan(fingers, targetApps := "*", condition := "", divisor := 6) {
        this.OnPan(fingers, ObjBindMethod(this, "MiddlePanDown"), ObjBindMethod(this, "MiddlePanMove"), ObjBindMethod(this, "MiddlePanUp"), targetApps, condition, divisor)
    }

    OnScroll(fingers, targetApps := "*", condition := "", divisor := 15) {
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

    ; ===================================================================
    ; HARDWARE ENGINE
    ; ===================================================================

    RegisterTrackpad() {
        rid := Buffer(16, 0)
        NumPut("UShort", 0x0D, rid, 0)
        NumPut("UShort", 0x05, rid, 2)
        NumPut("UInt", 0x00000100, rid, 4)
        NumPut("UPtr", A_ScriptHwnd, rid, 8)
        
        if (!DllCall("RegisterRawInputDevices", "Ptr", rid.Ptr, "UInt", 1, "UInt", 16)) {
            ExitApp
        }
        OnMessage(0x00FF, ObjBindMethod(this, "OnRawInput"))
    }

    OnRawInput(wParam, lParam, msg, hwnd) {
        Critical
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
        
        if (NumGet(rawBuf, 0, "UInt") != 2) { 
            return 
        }

        dwSizeHid := NumGet(rawBuf, headerSize, "UInt")
        dwCount := NumGet(rawBuf, headerSize + 4, "UInt")
        
        if (dwSizeHid * dwCount >= 12) {
            pRawData := rawBuf.Ptr + headerSize + 8
            if (NumGet(pRawData, 0, "UChar") == 0x04) {
                contactAndState := NumGet(pRawData, 1, "UChar")
                if (((contactAndState & 0xF0) >> 4) == 0) {
                    this.ProcessData(contactAndState & 0x0F, NumGet(pRawData, 8, "UChar"), NumGet(pRawData, 2, "Short"), NumGet(pRawData, 4, "Short"))
                }
            }
        }
    }

    ProcessData(state, countByte, x, y) {
        if (countByte > 0 && state == 3) {
            SetTimer(this.DebounceTimer, 0)

            if (this.IsTracking && countByte > this.MaxFingers) {
                this.MaxFingers := countByte
            }

            if (!this.IsTracking) {
                if (countByte >= this.LastFingers) {
                    this.CurrentFingers := countByte
                    this.StartTracking(x, y)
                }
            }
            else if (countByte != this.CurrentFingers) {
                this.CurrentFingers := countByte
                this.StartTracking(x, y)
            } 
            else {
                this.UpdateTracking(x, y)
            }
            
            this.LastFingers := countByte
        } 
        else if (countByte == 0 || state == 1) {
            this.LastFingers := countByte
            if (this.IsTracking) {
                SetTimer(this.DebounceTimer, -60)
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

        this.IsTracking := true
        this.MaxFingers := this.CurrentFingers
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
        dx := x - this.StartX
        dy := y - this.StartY
        dist := Sqrt(dx**2 + dy**2)
        
        if (dist > this.MaxDist) {
            this.MaxDist := dist
        }

        if (this.ActiveHoldHandler != "" && dist > 15) {
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

    ReleaseFingers() {
        if (!this.IsTracking) {
            return
        }
        
        SetTimer(this.HoldTimerObj, 0)
        this.IsTracking := false
        duration := A_TickCount - this.StartTime
        
        for handler in this.ActiveHandlers {
            if (handler.Type == "Pan") {
                handler.OnUp.Call()
            }
        }

        isTap := false
        ; Very forgiving distance threshold so firm taps don't fail as swipes
        maxD := this.MaxFingers * 20 
        
        if (!this.HasMoved && duration < 250 && this.MaxDist < maxD) {
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
            
            if (maxClicksBound > 0) {
                ; Zero lag for single taps
                if (maxClicksBound == 1) {
                    this.TapFingers := this.MaxFingers
                    this.TapCount := 1
                    this.ExecuteTap()
                } else {
                    ; Wait for potential multi-taps
                    if (this.MaxFingers == this.TapFingers && (A_TickCount - this.LastTapTime) < 350) {
                        this.TapCount++
                    } else {
                        this.TapFingers := this.MaxFingers
                        this.TapCount := 1
                    }
                    
                    this.LastTapTime := A_TickCount
                    
                    if (this.TapCount == maxClicksBound) {
                        SetTimer(this.TapTimerObj, 0)
                        this.ExecuteTap()
                    } else {
                        SetTimer(this.TapTimerObj, -350)
                    }
                }
            }
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
        ; Prioritize exact matches (e.g. they bound a Double Tap)
        for handler in this.Handlers {
            if (handler.Type == "Tap" && handler.Fingers == f && handler.Clicks == c) {
                if (this.MatchesApp(handler.Apps, activeExe) && this.EvaluateCondition(handler.Condition)) {
                    handler.OnTrigger.Call()
                    matched := true
                    break
                }
            }
        }
        
        ; Fallback: If they double tapped but only a single tap is bound, fire the single tap twice.
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
            if (handler.Fingers == fingers && this.MatchesApp(handler.Apps, activeExe) && this.EvaluateCondition(handler.Condition)) {
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
