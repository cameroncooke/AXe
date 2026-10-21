#!/usr/bin/env python3
"""Read frozen retained-pair proof. This sends no input and starts no simulator."""
import argparse
import hashlib
import json
from pathlib import Path


def require(value, reason):
    if not value:
        raise ValueError(reason)


def read(folder, name):
    return json.loads((folder / name).read_text())


def walk(roots):
    for node in roots:
        yield node
        yield from walk(node.get("children", []))


def paired_start(folder, framework):
    before = read(folder, "before.json")
    held = read(folder, "held-before-move.json")
    moved_app = read(folder, "held-before-change.json")
    config = read(folder, "configuration.json")
    began = read(folder, "began.json")
    moved = read(folder, "moved.json")
    require(before["activeWindowTouches"] == 0 and held["activeWindowTouches"] == moved_app["activeWindowTouches"] == 2, "Wrong actual contact count")
    trace = held["windowTouchTrace"][len(before["windowTouchTrace"]):]
    starts = [row for row in trace if row["phase"] == "windowTouchBegan"]
    ids = {row["contactID"] for row in starts}
    require(len(starts) == len(ids) == 2, "Two distinct app contacts did not start")
    for key in ("first", "second"):
        point = config[key]
        require(any(abs(row["x"]-point["x"]) < .5 and abs(row["y"]-point["y"]) < .5 for row in starts), "Pair start differs from fresh points")
    trace = moved_app["windowTouchTrace"][len(before["windowTouchTrace"]):]
    last = [[row for row in trace if row["contactID"] == cid][-1] for cid in ids]
    for key in ("movedFirst", "movedSecond"):
        point = config[key]
        require(any(row["phase"] == "windowTouchMoved" and abs(row["x"]-point["x"]) < .5 and abs(row["y"]-point["y"]) < .5 for row in last), "Both contacts did not move before change")
    for stage, outcome in ((began, "retained"), (moved, "moved")):
        require(stage["frameworkPath"] == framework and stage["operation"]["outcome"] == outcome and stage["operation"]["normalEventDelta"] == 1, "Wrong actual library stage")
        require(stage["operation"]["tokenReturned"] and stage["operation"]["sameOriginalToken"] and stage["status"]["hasRetainedContact"], "Retained token was not consistent")
    return before, moved_app, config, ids


def changed_pair(folder, original_context, idle_held):
    idle = read(folder, "idleAfterChange.json")
    idle_app = read(folder, "idle-app.json")
    change = read(folder, "external-change.json")
    old = read(folder, "oldMove1.json")
    require(idle["uptime"] >= change["finishedUptime"] + .99, "Idle observation was not after the bounded wait")
    require(idle["status"]["hasRetainedContact"] and idle["status"]["normalEnqueuedEventCount"] == 2 and idle.get("cleanupEvidence") is None, "Idle library state changed")
    require(idle_app["activeWindowTouches"] == idle_held and "staleContext" in idle["feedValidation"], "Idle app contacts or feed invalidation differ")
    if idle_held:
        released = read(folder, "after-first-rejection.json")
        require(released["activeWindowTouches"] == 0, "Owned cleanup did not release actual contacts")
        ended = [row for row in released["windowTouchTrace"][len(idle_app["windowTouchTrace"]):] if row["phase"] == "windowTouchEnded"]
        require(len(ended) == len({row["contactID"] for row in ended}) == 2, "Actual rotation contacts did not both end")
    require(old["operation"]["normalEventDelta"] == 0 and "staleContext" in old["operation"]["error"], "Old move sent normal input")
    require(not old["status"]["hasRetainedContact"] and old["status"]["normalEnqueuedEventCount"] == 2, "Retained state not cleared")
    evidence = old["cleanupEvidence"]
    require(evidence["outcome"] == "releaseEnqueuedAndDrained" and evidence["contextValidation"] == "releaseIdentityMatchedBeforeAndAfter" and not evidence["timedOut"], "Owned release is uncertain")
    releases = evidence["releases"]
    require(len(releases) == 1 and releases[0]["primitive"] == "TwoFingerTouch <hidden>" and releases[0]["returnedSuccessfully"], "Missing actual paired cleanup release")
    transport = releases[0]["transport"]
    require(transport["messageType"] == "IndigoDigitizerEvent" and transport["startedUptime"] <= transport["hostEnqueueCompletedUptime"] <= transport["guestBarrierStartedUptime"] <= transport["guestBarrierCompletedUptime"] <= releases[0]["finishedUptime"], "Pair release barrier was not confirmed")
    require(evidence["drainCompletedUptime"] >= evidence["drainStartedUptime"] >= releases[0]["finishedUptime"], "Cleanup drain missing")
    for identity in (evidence["identityBefore"], evidence["identityAfter"]):
        require(identity["bootIdentity"] == original_context["bootIdentity"] and identity["screenID"] == original_context["screenID"] and identity["screenUUID"] == original_context["screenUUID"], "Cleanup migrated target identity")
        require(identity["nativePixelWidth"] == original_context["nativePixelWidth"] and identity["nativePixelHeight"] == original_context["nativePixelHeight"] and identity["scale"] == original_context["scale"], "Cleanup changed native coordinate space")
    return evidence


def fresh_tap(folder, separate=False):
    before = read(folder, "state-before.json" if separate else "after-pair.json")
    after = read(folder, "state-after.json" if separate else "after-tap.json")
    description = read(folder, "describe-ui.json" if separate else "describe-after.stdout")
    receipt = read(folder, "tap.json" if separate else "fresh-tap.stdout")
    button = [node for node in walk(description["ax"]["roots"]) if node.get("AXUniqueId") == "feature.tap"]
    require(len(button) == 1 and button[0]["pid"] == 12430, "Fresh owned Button not found")
    require(receipt.get("error") is None and receipt["outcome"] == "enqueuedAndDrained" and receipt["enqueuedEventCount"] == 2 and receipt["context"] == description["context"], "Fresh tap did not complete")
    require(after["counts"].get("tap",0) == before["counts"].get("tap",0) + 1 and after["activeWindowTouches"] == 0, "No actual released fresh callback")
    trace = after["windowTouchTrace"][len(before["windowTouchTrace"]):]
    require(len(trace) == 2 and trace[0]["phase"] == "windowTouchBegan" and trace[-1]["phase"] == "windowTouchEnded" and trace[0]["contactID"] == trace[-1]["contactID"], "Fresh contact did not release")
    frame = button[0]["frame"]
    for row in trace:
        require(abs(row["x"]-frame["x"]-frame["width"]/2) < .5 and abs(row["y"]-frame["y"]-frame["height"]/2) < .5, "Fresh tap used old coordinates")
    require((after["width"],after["height"]) == (receipt["context"]["logicalWidth"],receipt["context"]["logicalHeight"]), "Fresh space differs from app")
    return receipt["context"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--current", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    pins = read(root, "pairs-pins.json")
    for pin in pins["files"]:
        require(hashlib.sha256((root/pin["snapshot"]).read_bytes()).hexdigest() == pin["sha256"], "Frozen pin differs: " + pin["label"])
        if args.current:
            require(hashlib.sha256(Path(pin["original"]).read_bytes()).hexdigest() == pin["sha256"], "Current input differs: " + pin["label"])
    session_source = (root/"pairs-candidate/library/FBSimulatorHIDSession.swift").read_text()
    require("releases.append(Self.event(contacts, direction: .up))" in session_source and "case let .pair(first, second): return .twoFingerTouch(direction: direction, finger1: first, finger2: second)" in session_source, "Pinned cleanup source does not bind paired UP")
    normal = root/"pairs-normal"
    _, _, _, normal_ids = paired_start(normal, pins["frameworkPath"])
    ended = read(normal, "ended.json")
    closed = read(normal, "closed.json")
    require(ended["operation"]["outcome"] == "endedAndDrained" and ended["operation"]["normalEventDelta"] == 1 and not ended["operation"]["tokenReturned"], "Normal end did not clear token")
    require(closed["status"]["state"] == "closed" and not closed["status"]["hasRetainedContact"] and not closed["operation"]["tokenReturned"] and closed["status"]["normalEnqueuedEventCount"] == 3, "Normal close incomplete")
    normal_fresh = fresh_tap(normal)
    fold = root/"pairs-fold"
    _, _, _, fold_ids = paired_start(fold, pins["frameworkPath"])
    fold_context = read(fold, "describe-before.stdout")["context"]
    fold_cleanup = changed_pair(fold, fold_context, idle_held=0)
    require(not (fold/"oldMove2.json").exists() and not (fold/"closed.json").exists(), "Fold second retry/normal close was incorrectly claimed")
    stopped = read(fold, "probe-stopped-process.json")
    require(stopped["exitCode"] == 2 and stopped["reaped"], "Original aborted probe not reaped")
    require("Missing owned pair UP" in read(fold, "failure.json")["error"], "Original grading failure was not preserved")
    abort = [json.loads(line) for line in (fold/"probe.stdout").read_text().splitlines() if line][-1]
    require(abort["stage"] == "failedAfterCleanup" and abort["status"]["state"] == "closed" and abort["cleanupEvidence"] == fold_cleanup, "Abort did not preserve owned cleanup")
    fold_fresh = fresh_tap(root/"pairs-fold-tail", separate=True)
    require(fold_context["screenID"] == 1 and fold_fresh["screenID"] == 3, "Opening did not switch panels")
    rotation = root/"pairs-rotate"
    _, _, _, rotation_ids = paired_start(rotation, pins["frameworkPath"])
    rotation_context = read(rotation, "describe-before.stdout")["context"]
    rotation_cleanup = changed_pair(rotation, rotation_context, idle_held=2)
    second = read(rotation, "oldMove2.json")
    require(second["operation"]["normalEventDelta"] == 0 and "invalidated" in second["operation"]["error"] and second["cleanupEvidence"] == rotation_cleanup, "Second old request sent or repeated input")
    closed = read(rotation, "closed.json")
    require(not closed["operation"]["tokenReturned"] and not closed["status"]["hasRetainedContact"] and closed["status"]["state"] == "closed", "Rotation did not clear token/state")
    rotation_fresh = fresh_tap(rotation)
    require(rotation_context["rotationDegrees"] == 90 and rotation_fresh["rotationDegrees"] == 180 and rotation_context["screenID"] == rotation_fresh["screenID"] == 3, "Actual inner rotation differs")
    shutdown = read(root/"pairs-shutdown", "result.json")
    require(shutdown["exitCode"] == 0 and shutdown["reaped"] and shutdown["stopReason"] is None, "Assigned guest not shut down")
    guards = []
    for name in ("pairs-compile-v1", "pairs-compile-v2", "pairs-boot", "pairs-ready", "pairs-launch", "pairs-normal-guard", "pairs-fold-guard", "pairs-fold-tail-discovery", "pairs-fold-tail-guard", "pairs-rotate-guard", "pairs-shutdown"):
        receipt = read(root/name, "result.json")
        require(receipt["reaped"] and receipt["stopReason"] is None and not receipt["signalsSent"], "Resource or process failure: " + name)
        require(receipt["exitCode"] == (1 if name == "pairs-fold-guard" else 0), "Wrong command exit: " + name)
        guards.append(receipt)
    for folder in (normal, fold, rotation):
        require(read(folder, "idle-resource.json")["appFootprintGiB"] < 7.75, "Input began above idle limit")
    result = dict(status="RETAINED_PAIR_BOUNDED_PROOF_WITH_IDLE_GAP", normalLifecycle=True,
        contactIDs=[sorted(normal_ids),sorted(fold_ids),sorted(rotation_ids)],
        changedCases=2, staleMoveNormalEvents=0, confirmedOwnedPairedReleases=2,
        secondOldRequestProved="rotation only; fold was aborted after first rejection",
        freshNamedButtonEffects=3, heldTouchesAtEnd=0, automaticOwnedIdleRelease=False,
        idleGap="Fold canceled app contacts; rotation retained both app contacts. Library kept pair/token in both until next stale request",
        idleAppContacts={"fold":0,"rotation":2},
        originalFoldDriver="FAILED_PRESERVED; separately source-bound release grading and fresh public tap accepted",
        sourceBoundDirection="Paired UP direction comes from pinned library source; public description hides direction",
        contexts=[normal_fresh,fold_fresh,rotation_fresh], candidatePins=len(pins["files"]),
        sampledPeaks={k:max(g["peaks"][k] for g in guards) for k in ("app","simulator","command")},
        nativeInputSharedSimulatorPeakGiB=max(read(root/name,"result.json")["peaks"]["simulator"] for name in ("pairs-normal-guard","pairs-fold-guard","pairs-fold-tail-guard","pairs-rotate-guard")),
        securityScan="UNVERIFIED", productionChange=False)
    (root/"pairs-main-result.json").write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
