#!/usr/bin/env python3
"""Writes the app icon: an Icon Composer bundle, and an image stack for visionOS.

    python3 Scripts/make-app-icon.py

The bundle is apps/Sangam/AppIcon.icon: icon.json plus one SVG per layer.
Xcode's asset compiler turns it into every size iOS and macOS need and applies
the system shape and the glass, dark, clear and tinted treatments, so the
artwork here is full bleed and carries no mask, rim or shadow of its own.

The picture is the painted Sangam icon (Artwork/AppIcon.svg) redrawn as flat
vector shapes: a white river and a black river meeting in a green valley and
running on side by side, under a sky that is stormy on the black river's side
and bright on the white river's. From back to front the layers are the sky
(the fill), Peaks (clouds and the far mountains), Valley (the hillsides),
Dark (the black river) and Light (the white river). In the dark appearance
the sky, Peaks and Valley change to night colours and the rivers stay as
they are.

visionOS takes nothing from an Icon Composer bundle. Its icon is a stack of up
to three bitmaps that it crops to a circle and sets apart in depth, so the
same drawings are also written as 1024 px PNGs to
apps/Sangam/Assets.xcassets/AppIcon.solidimagestack: Back (the sky and Peaks),
Middle (Valley) and Front (both rivers). The asset compiler gives each
platform the one it can use; both are named AppIcon. The PNGs are drawn by
sips, which comes with macOS.

Both are committed, so this only needs running when the design changes. To
look at the bundle without building:

    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \\
        apps/Sangam/AppIcon.icon --export-image --output-file icon.png \\
        --platform macOS --rendition Default --width 512 --height 512 --scale 2
"""
import json
import math
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "apps", "Sangam", "AppIcon.icon")
CATALOG = os.path.join(ROOT, "apps", "Sangam", "Assets.xcassets")

# The canvas is 1024 x 1024 with y downward. Shapes that leave the canvas run
# on to these coordinates so no edge of theirs can show inside it.
LEFT, RIGHT, TOP, BOTTOM = -40, 1064, -40, 1064

# Colours.
# The fill, top to bottom, by day and by night. Only the top quarter shows.
SKY = ("#8FB8DB", "#FFF3DC")
NIGHT_SKY = ("#0A1428", "#5A6E96")

STORM_CORE = "#0E1D24"
STORM = "#2B4A5E"
STORM_EDGE = "#6C97B5"
CLOUD = "#EFE6D6"
CLOUD_LIGHT = "#FAF4E8"
CLOUD_PEACH = "#EFCBB0"
PEAK_DARK = "#0C2C2B"           # the left peak, under the storm
PEAK_TEAL = "#135750"
PEAK_FAR = "#C9CFC4"            # the right peaks, in the sun
PEAK_FAR_SHADE = "#B3BEB7"
PEAK_NEAR = "#A9B7B1"
PEAK_NEAR_SHADE = "#8FA29D"

WHITE_WATER = "#F4F6F7"
WHITE_CURRENT = "#C5D0D8"
BLACK_WATER = "#0B1114"
BLACK_CURRENT = "#6F838D"

# Geometry.

# The white river's banks. Both run from its source on the horizon to the
# bottom of the canvas. The left bank is also where the two rivers touch.
WHITE_LEFT = [(532, 256), (470, 280), (425, 302), (450, 322), (500, 345), (545, 380), (520, 412),
              (440, 440), (402, 480), (405, 520), (440, 556), (478, 590), (486, 640), (488, 680),
              (520, 712), (575, 745), (602, 785), (592, 830), (562, 872), (530, 902), (450, 928),
              (370, 955), (300, 985), (265, BOTTOM)]
WHITE_RIGHT = [(542, 258), (544, 276), (525, 300), (555, 325), (585, 355), (600, 385), (632, 412),
               (648, 440), (610, 470), (560, 500), (560, 530), (610, 558), (680, 574), (740, 596),
               (790, 622), (812, 650), (790, 690), (760, 730), (775, 765), (815, 795), (828, 830),
               (810, 870), (765, 905), (715, 940), (650, 965), (590, 1000), (560, BOTTOM)]

# The black river's outer bank, from where it joins to the bottom corner.
BLACK_LEFT = [(415, 310), (375, 340), (348, 385), (322, 428), (262, 458), (210, 490), (180, 540),
              (190, 590), (222, 640), (258, 690), (282, 745), (294, 800), (272, 845), (232, 882),
              (180, 912), (120, 942), (60, 985), (LEFT, 1050)]
# How far the black river runs on under the white one, so no seam shows.
UNDERLAP = 16

# The hillsides, back to front. Each is its colour and the points of its top
# edge, from the side of the canvas inward, and the height at which that edge
# reaches the rivers (None for one that leaves the canvas first). Below its
# top edge a hillside fills its whole side of the valley, so each one covers
# the lower part of those behind it.
LEFT_HILLS = [
    ("#7C9853", [(LEFT, 92), (60, 138), (170, 192), (300, 238), (430, 258)], 258),
    ("#2D5A3C", [(LEFT, 128), (60, 172), (170, 224), (290, 270), (380, 296)], 318),
    ("#1F4129", [(LEFT, 318), (70, 330), (180, 360), (270, 400)], 450),
    ("#152D1D", [(LEFT, 470), (50, 478), (130, 510), (190, 560)], 640),
    ("#4F7F3C", [(LEFT, 630), (60, 628), (160, 652), (240, 700)], 800),
    ("#35633A", [(LEFT, 868), (50, 872), (120, 905)], 980),
]
RIGHT_HILLS = [
    ("#A7B27C", [(RIGHT, 190), (920, 205), (800, 215), (680, 232), (590, 250)], 258),
    ("#2F5A3A", [(RIGHT, 208), (950, 220), (850, 238), (760, 270), (680, 320), (620, 370)], 420),
    ("#5E8C49", [(RIGHT, 392), (960, 410), (860, 408), (770, 425), (700, 465)], 520),
    ("#79A254", [(RIGHT, 540), (950, 532), (860, 555), (800, 600)], 650),
    ("#1E3F2A", [(RIGHT, 688), (960, 696), (880, 728), (830, 780)], 840),
    ("#B8853F", [(RIGHT, 818), (960, 826), (870, 860), (790, 915), (700, 962)], 1010),
    ("#6F7A33", [(RIGHT, 925), (960, 928), (860, 962), (790, 1010), (760, BOTTOM)], None),
]
# Patches lying on the hillsides: meadow light and two drifts of flowers.
PATCHES = [
    ("#86A45A", [(10, 705), (110, 688), (215, 722), (190, 760), (90, 768), (20, 752)]),
    ("#D49A5B", [(770, 300), (840, 262), (930, 240), (1010, 238), (960, 272), (870, 300), (800, 318)]),
    ("#DD8468", [(900, 332), (970, 304), (RIGHT, 292), (RIGHT, 338), (990, 354), (930, 352)]),
]

# Currents in the water: strokes that taper to a point at both ends, each the
# points it runs through and its width in the middle.
WHITE_CURRENTS = [
    ([(585, 592), (640, 625), (668, 675), (650, 722)], 16),
    ([(660, 772), (705, 810), (712, 850), (682, 890)], 16),
    ([(430, 988), (510, 958), (590, 936), (650, 906)], 14),
]
BLACK_CURRENTS = [
    ([(285, 500), (320, 570), (345, 640), (395, 705)], 13),
    ([(480, 800), (440, 850), (360, 890), (270, 925)], 15),
]

# The far mountains, as straight-edged outlines, each with a second face in
# another tone.
LEFT_PEAK = [(LEFT, 70), (40, 42), (105, 8), (150, 40), (215, 92), (290, 160), (370, 222),
             (450, 252), (560, 262), (560, 420), (LEFT, 420)]
LEFT_PEAK_FACET = [(105, 8), (40, 42), (LEFT, 70), (LEFT, 420), (260, 420), (230, 250), (170, 120)]
FAR_PEAK = [(RIGHT, -20), (985, 14), (930, 62), (880, 96), (820, 150), (760, 200), (760, 420), (RIGHT, 420)]
FAR_PEAK_SHADE = [(985, 14), (930, 62), (880, 96), (820, 150), (760, 200), (900, 200), (950, 110)]
NEAR_PEAK = [(RIGHT, 205), (940, 172), (850, 150), (790, 136), (742, 152), (690, 182), (640, 204),
             (590, 236), (520, 262), (520, 420), (RIGHT, 420)]
NEAR_PEAK_SHADE = [(790, 136), (742, 152), (690, 182), (640, 204), (590, 236), (520, 262), (660, 262), (750, 205)]

# Clouds are circles (x, y, radius) run together.
STORM_EDGE_PUFFS = [(455, 30, 78), (490, 105, 52), (432, 158, 62), (385, 222, 50)]
STORM_PUFFS = [(420, 20, 80), (455, 95, 52), (395, 150, 62), (350, 215, 50)]
STORM_CORE_PUFFS = [(360, 10, 80), (395, 90, 50), (335, 140, 60), (290, 200, 50)]
CLOUD_PUFFS = [(640, 10, 75), (660, 110, 80), (600, 175, 55), (700, 190, 80), (760, 60, 110)]
CLOUD_LIGHT_PUFFS = [(700, 40, 70), (780, 110, 60), (880, 30, 80)]
CLOUD_PEACH_PUFFS = [(810, 30, 52), (865, 75, 36)]


def day(hex_color):
    return hex_color


def night(hex_color):
    """The same colour after dark: dimmed, and pulled toward blue."""
    r, g, b = (int(hex_color[i:i + 2], 16) for i in (1, 3, 5))
    return "#%02X%02X%02X" % (round(r * 0.42 + 6), round(g * 0.50 + 10), round(b * 0.62 + 22))


def number(v):
    return ("%.1f" % v).rstrip("0").rstrip(".")


def pt(p):
    return "%s %s" % (number(p[0]), number(p[1]))


def curve(points, closed=False):
    """Path data for a smooth curve through the points (a Catmull-Rom spline)."""
    n = len(points)

    def at(i):
        return points[i % n] if closed else points[max(0, min(n - 1, i))]

    d = ["M" + pt(points[0])]
    for i in range(n if closed else n - 1):
        p0, p1, p2, p3 = at(i - 1), at(i), at(i + 1), at(i + 2)
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d.append("C%s %s %s" % (pt(c1), pt(c2), pt(p2)))
    return " ".join(d) + (" Z" if closed else "")


def lines(points):
    return " ".join("L" + pt(p) for p in points)


def path(d, fill):
    return '<path d="%s" fill="%s"/>' % (d, fill)


def polygon(points, fill):
    return '<polygon points="%s" fill="%s"/>' % (" ".join("%s,%s" % (number(x), number(y)) for x, y in points), fill)


def circles(puffs, fill):
    return ['<circle cx="%d" cy="%d" r="%d" fill="%s"/>' % (x, y, r, fill) for x, y, r in puffs]


def along(points, steps=8):
    """Points close together on the smooth curve through the given ones."""
    n = len(points)
    out = []
    for i in range(n - 1):
        p0, p1, p2, p3 = points[max(0, i - 1)], points[i], points[i + 1], points[min(n - 1, i + 2)]
        for k in range(steps):
            t = k / steps
            out.append(tuple(
                0.5 * (2 * p1[a] + (p2[a] - p0[a]) * t + (2 * p0[a] - 5 * p1[a] + 4 * p2[a] - p3[a]) * t * t
                       + (3 * p1[a] - p0[a] - 3 * p2[a] + p3[a]) * t ** 3) for a in (0, 1)))
    return out + [points[-1]]


def brush(points, width, fill):
    """A stroke along the curve through the points, tapering to nothing at both ends."""
    mid = along(points)
    n = len(mid)
    left, right = [], []
    for i, (x, y) in enumerate(mid):
        (ax, ay), (bx, by) = mid[max(0, i - 1)], mid[min(n - 1, i + 1)]
        length = math.hypot(bx - ax, by - ay)
        half = width / 2 * math.sin(math.pi * i / (n - 1))
        nx, ny = (ay - by) / length * half, (bx - ax) / length * half
        left.append((x + nx, y + ny))
        right.append((x - nx, y - ny))
    return path("M" + pt(left[0]) + " " + lines(left[1:] + right[-2:0:-1]) + " Z", fill)


# A line that stays under the white river all the way down. Hillsides end on
# it, so their inner edges are always covered.
SPINE = [(x + 22, y) for x, y in WHITE_LEFT]


def spine_at(y):
    for (x0, y0), (x1, y1) in zip(SPINE, SPINE[1:]):
        if y0 <= y <= y1:
            return (x0 + (x1 - x0) * (y - y0) / (y1 - y0), y)
    raise ValueError(y)


def hill(color, top, reach, side):
    if reach is None:
        return path(curve(top) + " " + lines([(side, BOTTOM)]) + " Z", color)
    edge = top + [spine_at(reach)]
    below = [p for p in SPINE if p[1] > reach]
    return path(curve(edge) + " " + lines(below + [(side, BOTTOM)]) + " Z", color)


# Each drawing takes the time of day as a function from a colour to the
# colour it has then. The rivers are the same by day and by night.

def peaks(tone):
    body = circles(STORM_EDGE_PUFFS, tone(STORM_EDGE)) + circles(STORM_PUFFS, tone(STORM))
    body.append(polygon([(LEFT, TOP), (400, TOP), (330, 280), (LEFT, 280)], tone(STORM_CORE)))
    body += circles(STORM_CORE_PUFFS, tone(STORM_CORE))
    body.append(polygon([(660, TOP), (RIGHT, TOP), (RIGHT, 280), (620, 280)], tone(CLOUD)))
    body += circles(CLOUD_PUFFS, tone(CLOUD))
    body += circles(CLOUD_LIGHT_PUFFS, tone(CLOUD_LIGHT))
    body += circles(CLOUD_PEACH_PUFFS, tone(CLOUD_PEACH))
    body += [polygon(FAR_PEAK, tone(PEAK_FAR)), polygon(FAR_PEAK_SHADE, tone(PEAK_FAR_SHADE)),
             polygon(NEAR_PEAK, tone(PEAK_NEAR)), polygon(NEAR_PEAK_SHADE, tone(PEAK_NEAR_SHADE))]
    body += [polygon(LEFT_PEAK, tone(PEAK_DARK)), polygon(LEFT_PEAK_FACET, tone(PEAK_TEAL))]
    return body


def valley(tone):
    body = []
    # Alternate sides so the far hills of both lie behind the near ones.
    for i in range(max(len(LEFT_HILLS), len(RIGHT_HILLS))):
        for hills, side in ((RIGHT_HILLS, RIGHT), (LEFT_HILLS, LEFT)):
            if i < len(hills):
                color, top, reach = hills[i]
                body.append(hill(tone(color), top, reach, side))
    for color, outline in PATCHES:
        body.append(path(curve(outline, closed=True), tone(color)))
    return body


def dark_river(tone):
    under = [(x + UNDERLAP, y) for x, y in WHITE_LEFT if y > 315]
    outline = BLACK_LEFT + [(LEFT, BOTTOM)] + under[::-1]
    return ([path(curve(outline, closed=True), BLACK_WATER)]
            + [brush(points, width, BLACK_CURRENT) for points, width in BLACK_CURRENTS])


def light_river(tone):
    return ([path(curve(WHITE_LEFT + WHITE_RIGHT[::-1], closed=True), WHITE_WATER)]
            + [brush(points, width, WHITE_CURRENT) for points, width in WHITE_CURRENTS])


def sky(tone):
    """The fill as a drawing, for the icon that has no fill of its own."""
    # Icon Composer runs a fill's gradient over the middle four fifths of the height.
    return ['<linearGradient id="sky" x1="0" y1="0.1" x2="0" y2="0.9">'
            '<stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
            % (tone(SKY[0]), tone(SKY[1])),
            '<rect width="1024" height="1024" fill="url(#sky)"/>']


def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            + "".join("  %s\n" % line for line in body) + "</svg>\n")


def color(hex_color):
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return "extended-srgb:%.5f,%.5f,%.5f,1.00000" % (r, g, b)


# Layers from front to back, the order icon.json lists them: name, drawing,
# whether it is a glass piece, the opacity of the shadow it casts, and whether
# it has a second drawing for the dark appearance.
LAYERS = [
    ("Light", light_river, True, 0.5, False),
    ("Dark", dark_river, True, 0.5, False),
    ("Valley", valley, True, 0.5, True),
    ("Peaks", peaks, False, 0.0, True),
]


# The visionOS stack from front to back: name, and the drawings it holds from
# back to front. The back one has to be opaque.
STACK = [
    ("Front", [dark_river, light_river]),
    ("Middle", [valley]),
    ("Back", [sky, peaks]),
]


def gradient(colors):
    return {"linear-gradient": [color(colors[0]), color(colors[1])]}


def write_json(path, doc):
    with open(path, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True, separators=(",", " : "))
        f.write("\n")


def write_png(path, body):
    with tempfile.TemporaryDirectory() as scratch:
        drawing = os.path.join(scratch, "layer.svg")
        with open(drawing, "w") as f:
            f.write(svg(body))
        subprocess.run(["sips", "-s", "format", "png", drawing, "--out", path],
                       check=True, stdout=subprocess.DEVNULL)


def write_stack():
    info = {"author": "xcode", "version": 1}
    stack = os.path.join(CATALOG, "AppIcon.solidimagestack")
    for name, drawings in STACK:
        images = os.path.join(stack, name + ".solidimagestacklayer", "Content.imageset")
        os.makedirs(images, exist_ok=True)
        write_png(os.path.join(images, name + ".png"), [line for draw in drawings for line in draw(day)])
        write_json(os.path.join(images, "Contents.json"),
                   {"images": [{"filename": name + ".png", "idiom": "vision", "scale": "2x"}], "info": info})
        write_json(os.path.join(os.path.dirname(images), "Contents.json"), {"info": info})
    write_json(os.path.join(stack, "Contents.json"),
               {"info": info, "layers": [{"filename": name + ".solidimagestacklayer"} for name, _ in STACK]})
    write_json(os.path.join(CATALOG, "Contents.json"), {"info": info})
    print("wrote", os.path.relpath(stack, ROOT))


def main():
    os.makedirs(os.path.join(OUT, "Assets"), exist_ok=True)
    groups = []
    for name, draw, glass, shadow, changes in LAYERS:
        files = [(name + ".svg", day)] + ([(name + "-Dark.svg", night)] if changes else [])
        for filename, tone in files:
            with open(os.path.join(OUT, "Assets", filename), "w") as f:
                f.write(svg(draw(tone)))
        layer = {"name": name}
        if changes:
            layer["image-name-specializations"] = [{"value": name + ".svg"},
                                                   {"appearance": "dark", "value": name + "-Dark.svg"}]
        else:
            layer["image-name"] = name + ".svg"
        if not glass:
            layer["glass"] = False
        groups.append({
            "layers": [layer],
            "shadow": {"kind": "neutral", "opacity": shadow},
            "translucency": {"enabled": False, "value": 0.5},
        })
    doc = {
        "fill-specializations": [{"value": gradient(SKY)},
                                 {"appearance": "dark", "value": gradient(NIGHT_SKY)}],
        "groups": groups,
        "supported-platforms": {"squares": "shared"},
    }
    write_json(os.path.join(OUT, "icon.json"), doc)
    print("wrote", os.path.relpath(OUT, ROOT))
    write_stack()


if __name__ == "__main__":
    main()
