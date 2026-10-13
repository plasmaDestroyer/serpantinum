#!/usr/bin/env python3
"""Check actual dashboard QML expressions against bar geometry contracts.

Uses Node for QML's JavaScript arithmetic; does not start the desktop shell.
An optional QML path allows checking a preserved pre-fix source snapshot.
"""
from pathlib import Path
import itertools
import json
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "src/quickshell/calendar/Dashboard.qml"
text = source.read_text()
height = re.search(r"    property real barHeight: \{(.*?)\n    \}", text, re.S)
assert height, "Dashboard barHeight binding missing"
expressions = {"height": height.group(1)}
for name in ("barInset", "modularGap", "edgeOffset", "barEndRadius"):
    binding = re.search(r"^    (?:readonly )?property real " + name + r": (.+)$", text, re.M)
    assert binding, f"Dashboard {name} binding missing"
    expressions[name] = binding.group(1)
mask = re.search(r"^        property int barThickness: (.+)$", text, re.M)
assert mask, "Dashboard bar input mask missing"
expressions["mask"] = mask.group(1)
cases = [dict(style=style, scale=scale, height=height, margin=margin,
              autohide=state == "autohide", hidden=state != "visible")
         for style, scale, height, margin, state in itertools.product(
             ("modular", "solid", "fill"), (.75, .9, 1, 1.5),
             (28, 40, 48), (0, 4, 10, 24), ("visible", "autohide", "fullscreen"))]
script = r'''
const fs = require("node:fs");
const {expressions: e, cases} = JSON.parse(fs.readFileSync(0, "utf8"));
const height = new Function("Config", "s", "configRevision", "rawBarSettings", e.height);
const args = ["barHeight", "barStyle", "barAutohide", "s", "Config", "isSolid", "isBarEffectivelyHidden", "barInset", "modularGap"];
const inset = new Function(...args, "return " + e.barInset);
const gap = new Function(...args, "return " + e.modularGap);
const edge = new Function(...args, "return " + e.edgeOffset);
const radius = new Function(...args, "ThemeBackend", "return " + e.barEndRadius);
const mask = new Function("dashboardWindow", "Config", "return " + e.mask);
for (const c of cases) {
    const config = {barThickness: c.height, barScale: c.scale, barMargin: c.margin};
    const h = height(config, x => x, 0, {height: c.height});
    const values = [h, c.style, c.autohide, x => x, config, c.style !== "modular", c.hidden];
    const i = inset(...values);
    const g = gap(...values);
    c.actual = {height: h, inset: i, offset: edge(...values, i, g),
        radius: radius(...values, i, g, {borderRadius: 12}),
        mask: mask({barHeight: h, barInset: i, barStyle: c.style, s: x => x}, config)};
}
process.stdout.write(JSON.stringify(cases));
'''
result = subprocess.run(["node", "-e", script],
                        input=json.dumps({"expressions": expressions, "cases": cases}),
                        capture_output=True, text=True, check=True)
checked = json.loads(result.stdout)
failures = []
for case in checked:
    # Bar.qml rounds scaled thickness before adding its unscaled edge margin.
    expected_height = int(case["height"] * case["scale"] + .5)
    if case["hidden"]:
        expected_offset = 10 if case["style"] == "modular" else 0
    elif case["style"] == "modular":
        expected_offset = expected_height + case["margin"] + 6  # upstream clearance
    elif case["style"] == "solid":
        expected_offset = expected_height + case["margin"]
    else:
        expected_offset = expected_height
    expected_mask = expected_height + (0 if case["style"] == "fill" else case["margin"])
    expected_radius = min(int(12 * case["scale"] + .5) if case["style"] == "fill" else 12, expected_height / 2)
    expected_inset = expected_height + (case["margin"] if case["style"] == "solid" and not case["autohide"] else 0)
    if case["actual"] != dict(height=expected_height, inset=expected_inset,
                              offset=expected_offset, mask=expected_mask, radius=expected_radius):
        failures.append({**case, "expected_height": expected_height, "expected_offset": expected_offset,
                         "expected_mask": expected_mask, "expected_radius": expected_radius})
assert not failures, f"{len(failures)} cases failed; first: {failures[0]}"
print(f"Dashboard placement, input mask and radius: {len(checked)} cases passed (3 styles, scale, thickness, margin, visible/autohide/fullscreen).")
