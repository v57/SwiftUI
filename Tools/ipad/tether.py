# lldb command `tether <udid> <pid>`: attaches to an app launched stopped on a device, lets it run
# past startup, reads UTM's Main.jitAvailable and detaches. A process that a debugger attached to at
# launch keeps CS_DEBUGGED, which is what lets UTM map JIT pages (no hypervisor on iPadOS).
import lldb, time

def _wait(target_getter, ok, secs):
    end = time.time() + secs
    while time.time() < end:
        if ok(target_getter()):
            return True
        time.sleep(0.25)
    return False

def tether(debugger, command, result, internal_dict):
    udid, pid = command.split()
    debugger.SetAsync(True)
    debugger.HandleCommand("device select " + udid)
    debugger.HandleCommand("device process attach -p " + pid)
    target = debugger.GetSelectedTarget
    if not _wait(target, lambda t: t.IsValid() and t.GetProcess().GetState() == lldb.eStateStopped, 60):
        print("tether: attach timed out")
        return
    t = target()
    p = t.GetProcess()
    p.Continue()
    time.sleep(10)
    p.Stop()
    _wait(target, lambda t: t.GetProcess().GetState() == lldb.eStateStopped, 20)
    jit = None
    for m in t.module_iter():
        if m.GetFileSpec().GetFilename() != "UTM":
            continue
        for s in m:
            if s.GetType() == lldb.eSymbolTypeData and "jitAvailable" in (s.GetName() or ""):
                err = lldb.SBError()
                b = p.ReadMemory(s.GetStartAddress().GetLoadAddress(t), 1, err)
                if b:
                    jit = b[0]
        break
    p.Continue()
    time.sleep(1)
    p.Detach()
    print("tether: JIT %s" % ({1: "on", 0: "off"}.get(jit, "unknown")))

def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f tether.tether tether")
