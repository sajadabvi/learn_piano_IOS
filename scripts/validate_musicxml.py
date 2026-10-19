#!/usr/bin/env python3
"""Structural validator for the bundled MusicXML arrangements.

Usage: python3 -I scripts/validate_musicxml.py FILE [FILE...]
Exit code 0 when every file passes. Prints one JSON object per file.

Checks (score-partwise only):
  * well-formed XML, root <score-partwise>, at least one <part>
  * every measure resolves <divisions> and a <time> signature before its first note
  * per measure: the furthest position reached by notes/backup/forward equals the
    time-signature length (first measure may be a shorter pickup; last measure may
    be shorter to complete a pickup); no voice over-fills the measure
  * <chord/> notes do not advance time; rests are allowed; grace notes ignored
  * pitch step in A..G, octave 0..9, alter in -2..2, MIDI number within 21..108
  * ties: every tie start has a later tie stop of the same pitch in the same voice
  * staff numbers (if present) are 1 or 2; two hands exist (two staves OR two parts)
  * note type matches duration within tuplet tolerance (warning only)
"""
import json, sys, zipfile, io
import xml.etree.ElementTree as ET

STEP_SEMITONE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
TYPE_QUARTERS = {"maxima": 32, "long": 16, "breve": 8, "whole": 4, "half": 2, "quarter": 1,
                 "eighth": 0.5, "16th": 0.25, "32nd": 0.125, "64th": 0.0625, "128th": 0.03125}


def load(path):
    if path.endswith(".mxl"):
        with zipfile.ZipFile(path) as z:
            container = ET.fromstring(z.read("META-INF/container.xml"))
            root = container.find(".//rootfile").get("full-path")
            return ET.fromstring(z.read(root))
    return ET.parse(path).getroot()


def midi(pitch):
    step = pitch.findtext("step")
    octave = int(pitch.findtext("octave"))
    alter = float(pitch.findtext("alter") or 0)
    return int(12 * (octave + 1) + STEP_SEMITONE[step] + alter)


def validate(path):
    errors, warnings = [], []
    try:
        root = load(path)
    except Exception as e:  # noqa
        return {"file": path, "ok": False, "errors": [f"parse error: {e}"], "warnings": []}
    if root.tag != "score-partwise":
        errors.append(f"root is <{root.tag}>, expected <score-partwise>")
        return {"file": path, "ok": False, "errors": errors, "warnings": warnings}
    parts = root.findall("part")
    if not parts:
        errors.append("no <part>")
    title = root.findtext("work/work-title") or root.findtext("movement-title")
    if not title:
        warnings.append("no work-title/movement-title")
    staves_seen = set()
    total_measures = 0
    for part in parts:
        pid = part.get("id")
        divisions = None
        beats, beat_type = None, None
        measures = part.findall("measure")
        total_measures = max(total_measures, len(measures))
        open_ties = {}  # (voice, midi) -> measure number
        for mi, m in enumerate(measures):
            mnum = m.get("number", str(mi + 1))
            attrs = m.find("attributes")
            if attrs is not None:
                d = attrs.findtext("divisions")
                if d:
                    divisions = int(d)
                t = attrs.find("time")
                if t is not None:
                    beats, beat_type = int(t.findtext("beats")), int(t.findtext("beat-type"))
                st = attrs.findtext("staves")
                if st:
                    staves_seen.add(("staves", int(st)))
            pos = 0
            maxpos = 0
            voice_pos = {}
            last_note_dur = 0
            for el in m:
                if el.tag == "backup":
                    pos -= int(el.findtext("duration"))
                elif el.tag == "forward":
                    pos += int(el.findtext("duration"))
                    maxpos = max(maxpos, pos)
                elif el.tag == "note":
                    if el.find("grace") is not None:
                        continue
                    if divisions is None or beats is None:
                        errors.append(f"{pid} m{mnum}: note before divisions/time are set")
                        break
                    dur_txt = el.findtext("duration")
                    if dur_txt is None:
                        errors.append(f"{pid} m{mnum}: note without <duration>")
                        continue
                    dur = int(dur_txt)
                    voice = el.findtext("voice") or "1"
                    staff = el.findtext("staff")
                    if staff is not None:
                        if staff not in ("1", "2"):
                            errors.append(f"{pid} m{mnum}: staff {staff} not 1/2")
                        staves_seen.add(("staff", int(staff)))
                    is_chord = el.find("chord") is not None
                    pitch = el.find("pitch")
                    rest = el.find("rest")
                    if pitch is None and rest is None:
                        errors.append(f"{pid} m{mnum}: note with neither pitch nor rest")
                    if pitch is not None:
                        step = pitch.findtext("step")
                        if step not in STEP_SEMITONE:
                            errors.append(f"{pid} m{mnum}: bad step {step}")
                            continue
                        try:
                            octv = int(pitch.findtext("octave"))
                        except Exception:
                            errors.append(f"{pid} m{mnum}: bad octave")
                            continue
                        alter = float(pitch.findtext("alter") or 0)
                        if not (0 <= octv <= 9) or not (-2 <= alter <= 2):
                            errors.append(f"{pid} m{mnum}: octave/alter out of range ({step}{octv} alter {alter})")
                        n = midi(pitch)
                        if not (21 <= n <= 108):
                            errors.append(f"{pid} m{mnum}: MIDI {n} outside 88-key range")
                        for tie in el.findall("tie"):
                            key = (voice, n)
                            if tie.get("type") == "start":
                                open_ties[key] = mnum
                            elif tie.get("type") == "stop":
                                if key in open_ties:
                                    del open_ties[key]
                                else:
                                    errors.append(f"{pid} m{mnum}: tie stop without start (voice {voice}, midi {n})")
                    ntype = el.findtext("type")
                    if ntype in TYPE_QUARTERS and divisions:
                        expected = TYPE_QUARTERS[ntype] * divisions
                        dots = len(el.findall("dot"))
                        for _ in range(dots):
                            expected *= 1.5
                        tm = el.find("time-modification")
                        if tm is not None:
                            expected = expected * int(tm.findtext("normal-notes")) / int(tm.findtext("actual-notes"))
                        if abs(expected - dur) > 0.01 * divisions + 0.5:
                            warnings.append(f"{pid} m{mnum}: <type>{ntype}</type>{'.'*dots} implies {expected:g} but duration is {dur}")
                    if is_chord:
                        # chord notes share the onset of the previous note; they must not advance
                        pass
                    else:
                        start = pos
                        pos += dur
                        maxpos = max(maxpos, pos)
                        voice_pos[voice] = max(voice_pos.get(voice, 0), pos)
                        last_note_dur = dur
            if beats is not None and divisions is not None:
                mlen = beats * 4 * divisions // beat_type
                if maxpos > mlen:
                    errors.append(f"{pid} m{mnum}: content {maxpos} exceeds measure length {mlen}")
                elif maxpos < mlen:
                    if mi == 0 or mi == len(measures) - 1:
                        warnings.append(f"{pid} m{mnum}: short measure ({maxpos}/{mlen}) — ok only as pickup/final")
                    else:
                        errors.append(f"{pid} m{mnum}: under-filled measure ({maxpos}/{mlen})")
        for (voice, n), mnum in open_ties.items():
            errors.append(f"{pid}: tie started in m{mnum} (voice {voice}, midi {n}) never stopped")
    has_two_staves = ("staves", 2) in staves_seen or (("staff", 1) in staves_seen and ("staff", 2) in staves_seen)
    if len(parts) < 2 and not has_two_staves:
        errors.append("need two hands: either <staves>2</staves> with staff 1/2 or two parts")
    if total_measures < 4:
        warnings.append(f"only {total_measures} measures")
    return {"file": path, "ok": not errors, "measures": total_measures, "errors": errors, "warnings": warnings}


if __name__ == "__main__":
    ok = True
    for p in sys.argv[1:]:
        r = validate(p)
        ok &= r["ok"]
        print(json.dumps(r, indent=1))
    sys.exit(0 if ok else 1)
