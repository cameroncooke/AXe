#!/usr/bin/env python3
"""One explicit warm simulator, one runtime, one pad tap and one safe button tap.

Run only after coordinator review, under the existing resource guard. No install,
boot, fold, rotation, app-data write, input retry or input-recovery command exists.
"""
import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import time
import uuid

BUNDLE = "com.cameroncooke.AxePlayground"

class NotVisible(ValueError):
    pass

def require(value, message):
    if not value:
        raise ValueError(message)

def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()

def save(file, value):
    file.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")

def walk(nodes):
    for node in nodes:
        yield node
        yield from walk(node.get("children", []))

def rect(value):
    result = tuple(float(value[k]) for k in ("x", "y", "width", "height"))
    require(all(math.isfinite(x) for x in result) and result[2] > 0 and result[3] > 0,
            "Invalid observed rectangle")
    return result

def contains(outer, inner, tolerance=0):
    x, y, w, h = outer
    a, b, c, d = inner
    return a >= x-tolerance and b >= y-tolerance and a+c <= x+w+tolerance and b+d <= y+h+tolerance

class Probe:
    def __init__(self, args):
        self.args = args
        self.cli = args.runtime.resolve()
        self.out = args.output
        self.out.mkdir(parents=True, exist_ok=False)
        self.calls = []
        self.state_file = None
        self.pid = None
        self.cases = []
        self.result = {"status":"STARTED", "udid":args.udid, "runtime":str(self.cli),
                       "helperSHA256":digest(Path(__file__)),
                       "inputRetries":0, "poseChanges":0, "appDataWrites":0}
        save(self.out/"candidate.json", self.result)

    def validate_candidate(self):
        require(self.cli.is_file(), "--runtime must name the exact axe executable")
        self.result["runtimeSHA256"] = digest(self.cli)
        framework = self.cli.parent/"Frameworks/FBSimulatorControl.framework/Versions/A/FBSimulatorControl"
        require(framework.is_file(), "Matched runtime framework is missing")
        self.result["nativeSHA256"] = digest(framework)
        save(self.out/"candidate.json", self.result)

    def command(self, name, argv, expected=(0,), timeout=35, input_attempt=False):
        require(not (self.out/(name+".stdout")).exists(), "A command name was reused")
        save(self.out/(name+"-argv.json"), argv)
        started = time.monotonic()
        signals = []
        child = None
        with (self.out/(name+".stdout")).open("xb") as stdout, (self.out/(name+".stderr")).open("xb") as stderr:
            try:
                child = subprocess.Popen(argv, stdout=stdout, stderr=stderr)
                child.wait(timeout=timeout)
            except BaseException:
                if child:
                    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
                        if child.poll() is not None:
                            break
                        try:
                            child.send_signal(sig)
                        except ProcessLookupError:
                            child.wait()
                            break
                        signals.append(sig.name)
                        try:
                            child.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            pass
                raise
            finally:
                record = {"name":name, "argv":argv, "pid":child.pid if child else None,
                          "exitCode":child.poll() if child else None, "elapsedSeconds":time.monotonic()-started,
                          "signals":signals, "reaped":child is not None and child.poll() is not None,
                          "inputAttempted":input_attempt}
                self.calls.append(record)
                save(self.out/(name+"-process.json"), record)
                save(self.out/"calls.json", self.calls)
        require(child.returncode in expected, name+" failed; input is not replayed")
        return (self.out/(name+".stdout")).read_text()

    def axe(self, name, arguments, **options):
        return self.command(name, [str(self.cli), *arguments, "--udid", self.args.udid], **options)

    def state(self):
        require(self.state_file is not None, "App document was not resolved")
        require(self.state_file.stat().st_size <= 8*1024*1024, "Unexpected oversized fixture document")
        value = json.loads(self.state_file.read_bytes())
        require(value.get("fixtureVersion") == 6 and value.get("traceScope") == "duo-controls-page",
                "Existing fixture v6 is required")
        require(value.get("pid") == self.pid, "Document PID differs from normal launch")
        return value

    def archive_state(self, name):
        require(self.state_file is not None, "No document binding")
        require(self.state_file.stat().st_size <= 8*1024*1024, "Unexpected oversized fixture document")
        raw = self.state_file.read_bytes()
        (self.out/(name+".json")).write_bytes(raw)
        return json.loads(raw)

    def wait_state(self, predicate, label):
        deadline = time.monotonic()+5
        while True:
            value = self.state()
            if predicate(value):
                return value
            require(time.monotonic() < deadline, label+" did not settle; no input retry")
            time.sleep(0.05)

    def wait_launch(self):
        deadline = time.monotonic()+5
        latest = None
        while True:
            try:
                value = self.state()
                if value["activeWindowTouches"] == 0:
                    return value
            except (FileNotFoundError, json.JSONDecodeError, ValueError) as error:
                latest = repr(error)
            require(time.monotonic() < deadline, "Normal launch document did not settle: "+str(latest))
            time.sleep(0.05)

    def catalogue(self, name):
        value = json.loads(self.axe(name, ["displays", "--verbose"]))
        require(uuid.UUID(value["requestedSimulatorUDID"]) == uuid.UUID(self.args.udid), "Wrong display catalogue")
        require(value["activePanel"]["backlightState"] == "activeOn", "Selected display backlight is not activeOn")
        return value

    def fresh(self, name):
        cat = self.catalogue(name+"-catalogue")
        identity = cat["activePanel"]["identity"]
        args = ["describe-ui", "--input-mode", "selected", "--screen-id", str(identity["displayID"]),
                "--screen-uuid", identity["uniqueID"], "--expected-pid", str(self.pid), "--verbose"]
        reply = json.loads(self.axe(name+"-native", args))
        require(type(reply.get("version")) is int and reply["version"] > 0 and reply.get("error") is None
                and reply.get("quarantine") is None and reply.get("enqueuedEventCount") == 0,
                "Fresh native description failed")
        context = reply["context"]
        require(context["bootIdentity"] == cat["bootIdentity"] and context["screenID"] == identity["displayID"]
                and uuid.UUID(context["screenUUID"]) == uuid.UUID(identity["uniqueID"]), "Native/display context mismatch")
        scale = float(context["scale"])
        require(math.isfinite(scale) and scale > 0, "Invalid display scale")
        screen = (0, 0, float(context["logicalWidth"]), float(context["logicalHeight"]))
        require(screen[2] > 0 and screen[3] > 0, "Invalid display size")
        state = self.state()
        require(state["activeWindowTouches"] == 0 and state["windowTraceDropped"] == 0
                and state["recognizerTraceDropped"] == 0, "Fixture input/trace is not clear")
        guest_screen = rect(state["geometry"]["feature.screen"])
        require(contains(screen, guest_screen, 1/scale), "Guest controller window rectangle is outside selected display")
        require(abs(guest_screen[2]-state["width"]) <= 1/scale and abs(guest_screen[3]-state["height"]) <= 1/scale,
                "Guest bounds and window-converted controller geometry differ")
        roots = reply["ax"]["roots"]
        if isinstance(roots, dict):
            roots = [roots]
        save(self.out/(name+"-context.json"), {"context":context,"nativeBrokerID":reply.get("brokerID"),
             "catalogue":cat,"guestControllerWindowRect":guest_screen,
             "note":"Controller bounds are not the whole UIWindow. All target coordinates are window-converted."})
        return {"catalogue":cat, "context":context, "state":state, "nodes":list(walk(roots)),
                "screen":screen, "tolerance":1/scale}

    def target(self, observed, identifier, guest=True):
        hits = [x for x in observed["nodes"] if x.get("AXUniqueId") == identifier]
        require(len(hits) == 1, "Native target is absent or ambiguous: "+identifier)
        node = hits[0]
        require(node.get("pid") == self.pid and node.get("enabled") is True and node.get("hidden") is False,
                "Native target owner/availability changed")
        frame = rect(node["frame"])
        if not contains(observed["screen"], frame, observed["tolerance"]):
            raise NotVisible("Native target is not fully on display")
        if guest:
            actual = rect(observed["state"]["geometry"][identifier])
            require(all(abs(a-b) <= observed["tolerance"] for a,b in zip(frame, actual)),
                    "Native target and guest window geometry differ")
            viewport = rect(observed["state"]["geometry"]["feature.mainScroll"])
            if not contains(viewport, actual, observed["tolerance"]):
                raise NotVisible("Target is clipped by normal scroll view")
        return frame

    def same_context(self, before, after):
        require(before["context"] == after["context"], "Display/boot/rotation/hinge context changed")
        a, z = before["state"], after["state"]
        for key in ("pid","generation","width","height","interfaceOrientation"):
            require(a[key] == z[key], "Guest identity/layout changed: "+key)

    def broker(self, name):
        pattern = " hid-broker --selected --udid "+re.escape(self.args.udid)+"$"
        text = self.command(name+"-pids", ["/usr/bin/pgrep", "-f", pattern], expected=(0,1), timeout=5)
        pids = [int(x) for x in text.split()]
        library = ctypes.CDLL("/usr/lib/libproc.dylib")
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        records = []
        for pid in pids:
            buf = ctypes.create_string_buffer(4096)
            require(library.proc_pidpath(pid, buf, len(buf)) > 0, "Could not read actual broker executable path")
            executable = Path(os.fsdecode(buf.value)).resolve(strict=True)
            native = executable.parent/"Frameworks/FBSimulatorControl.framework/Versions/A/FBSimulatorControl"
            records.append({"pid":pid,"actualExecutable":str(executable),"executableSHA256":digest(executable),
                            "nativeFramework":str(native),"nativeSHA256":digest(native) if native.is_file() else None})
        save(self.out/(name+".json"), records)
        return records

    def one_tap(self, name, identifier, counter, observed):
        frame = self.target(observed, identifier)
        if identifier == "feature.tap":
            node = next(x for x in observed["nodes"] if x.get("AXUniqueId") == identifier)
            require(node.get("type") == "Button", "Button target has a different native type")
        before = observed["state"]
        require(self.archive_state(name+"-before") == before, "App changed after target/geometry read")
        point = (frame[0]+frame[2]/2, frame[1]+frame[3]/2)
        call = ["tap", "-x", str(point[0]), "-y", str(point[1]), "--tap-style", "physical"]
        try:
            self.axe(name+"-input", call, input_attempt=True)
            count = before["counts"].get(counter, 0)
            self.wait_state(lambda v: v["activeWindowTouches"] == 0 and
                            (v["counts"].get(counter,0) != count or
                             v["counts"].get("longPress",0) != before["counts"].get("longPress",0)), name)
        finally:
            after = self.archive_state(name+"-after")
        require(after["windowTouchTrace"][:len(before["windowTouchTrace"])] == before["windowTouchTrace"],
                "Existing contact history changed")
        trace = after["windowTouchTrace"][len(before["windowTouchTrace"]):]
        began = [x for x in trace if x["phase"] == "windowTouchBegan"]
        ended = [x for x in trace if x["phase"] == "windowTouchEnded"]
        record = {"name":name,"target":identifier,"point":point,"counterBefore":before["counts"].get(counter,0),
                  "counterAfter":after["counts"].get(counter,0),"longPressBefore":before["counts"].get("longPress",0),
                  "longPressAfter":after["counts"].get("longPress",0),"trace":trace,
                  "guestDurationSeconds":ended[0]["timestamp"]-began[0]["timestamp"] if len(began)==len(ended)==1 else None,
                  "activeWindowTouches":after["activeWindowTouches"]}
        self.cases.append(record)
        save(self.out/(name+"-measurements.json"), record)
        require(len(began)==len(ended)==1 and len({x["contactID"] for x in trace})==1
                and not any(x["phase"]=="windowTouchCancelled" for x in trace), "Not one complete contact")
        require(after["activeWindowTouches"]==0 and ended[0]["activeTouches"]==0, "Touch remains held")
        require(after["windowTraceDropped"]==before["windowTraceDropped"]==0
                and after["recognizerTraceDropped"]==before["recognizerTraceDropped"]==0, "Observation trace lost events")
        require(0 <= record["guestDurationSeconds"] < 0.5, "Tap reached the fixture long-press duration")
        require(record["counterAfter"]==record["counterBefore"]+1 and record["longPressAfter"]==record["longPressBefore"],
                "One short tap effect was not proved")
        for touch in (began[0],ended[0]):
            require(abs(touch["x"]-point[0])<=observed["tolerance"] and abs(touch["y"]-point[1])<=observed["tolerance"],
                    "Guest contact differs from fresh native/guest joined point")
        for key in ("slider","switchOn","text","textFocused","pageOffsetY","listOffsetY","canvasOffsetX","canvasOffsetY"):
            require(after[key]==before[key], "Unrelated control/layout changed: "+key)
        fresh = self.fresh(name+"-after-check")
        self.same_context(observed, fresh)
        require(fresh["state"] == after, "App changed during final readback")
        return fresh

    def run(self):
        self.validate_candidate()
        self.catalogue("initial-displays")
        launch = self.command("normal-page-launch", ["/usr/bin/xcrun","simctl","launch",
                              self.args.udid,BUNDLE,"--launch-arg","screen=duo-controls"])
        match = re.search(re.escape(BUNDLE)+r":\s*(\d+)",launch)
        require(match is not None, "Normal launch PID missing")
        self.pid = int(match[1])
        container = self.command("document-container", ["/usr/bin/xcrun","simctl","get_app_container",self.args.udid,BUNDLE,"data"]).strip()
        self.state_file = Path(container).resolve(strict=True)/"Documents/state.json"
        app = Path(self.command("installed-app",["/usr/bin/xcrun","simctl","get_app_container",self.args.udid,BUNDLE,"app"]).strip()).resolve(strict=True)
        info = plistlib.loads((app/"Info.plist").read_bytes())
        require(info["CFBundleIdentifier"]==BUNDLE,"Installed fixture identity differs")
        self.result.update(app=str(app),appBinarySHA256=digest(app/info["CFBundleExecutable"]),pid=self.pid,stateFile=str(self.state_file))
        self.wait_launch()
        observed = self.fresh("baseline")
        try:
            self.target(observed,"feature.pad")
            self.target(observed,"feature.tap")
        except NotVisible:
            toolbar = self.target(observed,"feature.showPad",guest=False)
            self.axe("normal-show-pad",["tap","-x",str(toolbar[0]+toolbar[2]/2),"-y",str(toolbar[1]+toolbar[3]/2),
                     "--tap-style","simulator"],input_attempt=True)
            self.wait_state(lambda v:v["activeWindowTouches"]==0,"normal Show pad")
            new = self.fresh("visible-baseline")
            self.same_context(observed,new)
            observed = new
            self.target(observed,"feature.pad")
            self.target(observed,"feature.tap")
        self.archive_state("baseline-app-state")
        self.broker("broker-before")
        after_pad = self.one_tap("pad","feature.pad","padTap",observed)
        self.one_tap("button","feature.tap","tap",after_pad)
        self.result.update(status="PASS",cases=self.cases,scope="One no-flag physical pad tap and button tap on the explicit current simulator; no exact100ms claim")

    def finish(self, error=None):
        if error is not None:
            self.result.update(status="FAIL_OR_UNPROVED",error=repr(error),cases=self.cases)
        try:
            self.archive_state("final-observed-state")
        except BaseException as problem:
            save(self.out/"final-state-unavailable.json",{"error":repr(problem)})
        try:
            self.result["brokerAfter"] = self.broker("broker-after")
        except BaseException as problem:
            self.result["brokerObservationError"] = repr(problem)
        self.result["calls"] = len(self.calls)
        self.result["evidenceHashes"] = {str(p.relative_to(self.out)):digest(p) for p in self.out.iterdir() if p.is_file() and p.name!="result.json"}
        save(self.out/"result.json",self.result)
        print(json.dumps({k:v for k,v in self.result.items() if k in ("status","runtimeSHA256","nativeSHA256","calls","error")}))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid",required=True)
    parser.add_argument("--runtime",required=True,type=Path)
    parser.add_argument("--output",required=True,type=Path)
    args=parser.parse_args()
    args.udid = str(uuid.UUID(args.udid)).upper()
    require(args.runtime.is_absolute() and args.output.is_absolute(),"Use explicit absolute runtime/output paths")
    probe=Probe(args)
    failure=None
    try:
        probe.run()
    except BaseException as error:
        failure=error
    finally:
        probe.finish(failure)
    return 1 if failure else 0

if __name__=="__main__":
    raise SystemExit(main())
