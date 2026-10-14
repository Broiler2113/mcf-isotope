"""Small items (0.12.1): loose objects placed freely on tables and floors, at any angle.

Each is drawn at its real size in the middle of one cell, from above, its top (back) up;
the game rotates the whole picture. Same renderer and materials as the furniture.
"""
import math
from core import *

INK = rgb("#2a2c30")
PAPER = rgb("#f1eee6")
CHROME = rgb("#c4c9ce")
C = 0.5


def papers(cv):
    cv.rect(C - 0.13, C - 0.17, C + 0.11, C + 0.15, 0.03, solid(PAPER * 0.96, var=0.02), r=0.004, bevel=0.004)
    cv.rect(C - 0.1, C - 0.14, C + 0.14, C + 0.18, 0.04, solid(PAPER, var=0.02), r=0.004, bevel=0.004)
    for k in range(6):
        cv.groove(C - 0.06, C - 0.09 + k * 0.045, C + 0.1 - (k % 3) * 0.03, C - 0.085 + k * 0.045, depth=0.002, dark=0.6)


def folder(cv):
    cv.rect(C - 0.13, C - 0.16, C - 0.02, C - 0.12, 0.03, solid(rgb("#c9a35c")), r=0.01, bevel=0.005)
    cv.rect(C - 0.13, C - 0.13, C + 0.13, C + 0.17, 0.04, solid(rgb("#d4ae66"), var=0.03), r=0.01, bevel=0.008)


def book(cv):
    cv.rect(C - 0.11, C - 0.15, C + 0.11, C + 0.15, 0.06, solid(rgb("#8e2f2a"), var=0.03, gloss=0.2), r=0.01, bevel=0.012)
    cv.rect(C - 0.11, C - 0.15, C - 0.075, C + 0.15, 0.065, solid(rgb("#6a211d")), r=0.008, bevel=0.008)
    cv.rect(C + 0.095, C - 0.14, C + 0.11, C + 0.14, 0.055, solid(PAPER * 0.92), r=0.0, bevel=0.0)


def magazine(cv):
    cv.rect(C - 0.12, C - 0.16, C + 0.12, C + 0.16, 0.03, solid(rgb("#e7e2d6"), gloss=0.5), r=0.006, bevel=0.005)
    cv.rect(C - 0.1, C - 0.13, C + 0.1, C + 0.02, 0.035, solid(rgb("#3a7bc0"), gloss=0.5), r=0.004, bevel=0.0)
    cv.rect(C - 0.1, C + 0.05, C + 0.04, C + 0.08, 0.035, solid(rgb("#c43a2e")), r=0.0, bevel=0.0)


def mug(cv):
    cv.rect(C + 0.04, C - 0.015, C + 0.1, C + 0.015, 0.1, ceramic(rgb("#e4e0d6")), r=0.01, bevel=0.01)
    cv.circle(C, C, 0.065, 0.12, ceramic(rgb("#e8e4da")), bevel=0.02)
    cv.circle(C, C, 0.045, 0.1, solid(rgb("#3a2414"), gloss=0.6), bevel=0.01)


def plate(cv):
    cv.circle(C, C, 0.14, 0.03, ceramic(rgb("#ece9e1")), bevel=0.05)
    cv.circle(C, C, 0.09, 0.02, ceramic(rgb("#e2ded4")), bevel=0.03)
    cv.line(C + 0.17, C - 0.1, C + 0.17, C + 0.1, 0.015, 0.03, metal(CHROME, gloss=0.8), bevel=0.005)
    cv.line(C - 0.17, C - 0.1, C - 0.17, C + 0.1, 0.015, 0.03, metal(CHROME, gloss=0.8), bevel=0.005)


def cup(cv):
    cv.circle(C, C, 0.05, 0.1, glass(rgb("#b9d2da")), bevel=0.02, dome=0.01)
    cv.circle(C, C, 0.035, 0.08, glass(rgb("#9fc0cc")), bevel=0.01)


def bottle(cv):
    cv.circle(C, C, 0.055, 0.2, glass(rgb("#3f7a4e")), bevel=0.03, dome=0.03)
    cv.circle(C, C, 0.022, 0.24, metal(rgb("#b8a24a"), gloss=0.6), bevel=0.01)


def can(cv):
    cv.circle(C, C, 0.045, 0.12, metal(rgb("#b8352a"), gloss=0.6), bevel=0.012)
    cv.circle(C, C, 0.034, 0.125, metal(CHROME, gloss=0.8), bevel=0.006)
    cv.rect(C - 0.01, C - 0.025, C + 0.01, C - 0.005, 0.13, metal(CHROME * 0.8), r=0.004, bevel=0.0)


def monitor(cv):
    cv.rect(C - 0.06, C - 0.02, C + 0.06, C + 0.1, 0.08, plastic(INK), r=0.02, bevel=0.015)
    cv.rect(C - 0.28, C - 0.08, C + 0.28, C - 0.02, 0.35, plastic(rgb("#1a1c1f")), r=0.015, bevel=0.012)
    cv.rect(C - 0.26, C - 0.035, C + 0.26, C - 0.022, 0.36, screen(rgb("#3b6fb0")), r=0.0, bevel=0.0, emit=0.7)


def keyboard(cv):
    cv.rect(C - 0.2, C - 0.07, C + 0.2, C + 0.07, 0.04, plastic(rgb("#2b2d30")), r=0.015, bevel=0.01)
    for k in range(1, 4):
        cv.groove(C - 0.18, C - 0.07 + k * 0.035, C + 0.18, C - 0.067 + k * 0.035, depth=0.003, dark=0.65)
    for k in range(1, 10):
        cv.groove(C - 0.2 + k * 0.04, C - 0.06, C - 0.197 + k * 0.04, C + 0.06, depth=0.003, dark=0.7)


def mouse(cv):
    cv.ellipse(C, C, 0.035, 0.055, 0.05, plastic(rgb("#2b2d30")), bevel=0.02, dome=0.015)
    cv.groove(C - 0.002, C - 0.055, C + 0.002, C - 0.015, depth=0.003, dark=0.6)


def phone(cv):
    cv.rect(C - 0.05, C - 0.09, C + 0.05, C + 0.09, 0.03, plastic(rgb("#1d1f22"), gloss=0.6), r=0.015, bevel=0.008)
    cv.rect(C - 0.042, C - 0.075, C + 0.042, C + 0.07, 0.032, screen(rgb("#2c4f6e")), r=0.008, bevel=0.0, emit=0.4)


def laptop(cv):
    cv.rect(C - 0.17, C - 0.15, C + 0.17, C + 0.0, 0.04, plastic(rgb("#2a2d31")), r=0.012, bevel=0.008)
    cv.rect(C - 0.15, C - 0.135, C + 0.15, C - 0.015, 0.042, screen(rgb("#3b6fb0")), r=0.006, bevel=0.0, emit=0.7)
    cv.rect(C - 0.17, C + 0.0, C + 0.17, C + 0.15, 0.035, metal(rgb("#8e949a"), gloss=0.5), r=0.012, bevel=0.008)
    cv.rect(C - 0.14, C + 0.02, C + 0.14, C + 0.09, 0.037, plastic(rgb("#2b2d30")), r=0.004, bevel=0.003)
    cv.rect(C - 0.04, C + 0.1, C + 0.04, C + 0.135, 0.036, metal(rgb("#7a8086")), r=0.004, bevel=0.002)


def radio(cv):
    cv.line(C + 0.07, C - 0.06, C + 0.12, C - 0.22, 0.012, 0.12, metal(INK), bevel=0.004)
    cv.rect(C - 0.11, C - 0.07, C + 0.11, C + 0.07, 0.1, painted(rgb("#5a6338"), gloss=0.25), r=0.015, bevel=0.012)
    cv.rect(C - 0.09, C - 0.05, C + 0.02, C + 0.05, 0.105, solid(rgb("#30351f")), r=0.006, bevel=0.0)
    for k in range(2):
        cv.circle(C + 0.06, C - 0.025 + k * 0.05, 0.018, 0.12, metal(CHROME), bevel=0.008)


def headset(cv):
    for s in (-1, 1):
        cv.ellipse(C + s * 0.1, C + 0.02, 0.035, 0.05, 0.06, plastic(INK), bevel=0.02, dome=0.01)
    cv.line(C - 0.1, C - 0.02, C, C - 0.09, 0.018, 0.05, plastic(rgb("#3a3d41")), bevel=0.006)
    cv.line(C, C - 0.09, C + 0.1, C - 0.02, 0.018, 0.05, plastic(rgb("#3a3d41")), bevel=0.006)


def wrench(cv):
    cv.line(C - 0.12, C + 0.12, C + 0.08, C - 0.08, 0.03, 0.03, metal(CHROME, gloss=0.8), bevel=0.01)
    cv.circle(C + 0.1, C - 0.1, 0.04, 0.032, metal(CHROME, gloss=0.8), bevel=0.012)
    cv.circle(C + 0.115, C - 0.115, 0.018, 0.02, solid(rgb("#3c3f43")), bevel=0.0)


def screwdriver(cv):
    cv.line(C - 0.02, C - 0.02, C + 0.14, C - 0.14, 0.012, 0.03, metal(CHROME, gloss=0.8), bevel=0.004)
    cv.line(C - 0.13, C + 0.13, C - 0.02, C + 0.02, 0.04, 0.04, plastic(rgb("#d6a72a")), bevel=0.012)


def flask(cv):
    cv.circle(C, C + 0.02, 0.075, 0.12, glass(rgb("#7fc4a8")), bevel=0.03, dome=0.02)
    cv.circle(C, C + 0.02, 0.025, 0.2, glass(rgb("#c7dde0")), bevel=0.01)


def test_tubes(cv):
    cv.rect(C - 0.14, C - 0.045, C + 0.14, C + 0.045, 0.08, metal(rgb("#9aa0a6"), gloss=0.5), r=0.01, bevel=0.01)
    for k, col in enumerate((rgb("#7fc4a8"), rgb("#d4a62a"), rgb("#9ab8e6"), rgb("#c46a8a"))):
        cv.circle(C - 0.105 + k * 0.07, C, 0.022, 0.12, glass(col), bevel=0.008, dome=0.006)


def clipboard(cv):
    cv.rect(C - 0.11, C - 0.15, C + 0.11, C + 0.15, 0.03, wood(rgb("#8a6a44"), freq=10), r=0.012, bevel=0.008)
    cv.rect(C - 0.09, C - 0.11, C + 0.09, C + 0.13, 0.035, solid(PAPER), r=0.003, bevel=0.003)
    cv.rect(C - 0.04, C - 0.16, C + 0.04, C - 0.12, 0.045, metal(CHROME, gloss=0.8), r=0.01, bevel=0.008)
    for k in range(4):
        cv.groove(C - 0.06, C - 0.06 + k * 0.045, C + 0.06, C - 0.057 + k * 0.045, depth=0.002, dark=0.6)


def tray(cv):
    cv.rect(C - 0.17, C - 0.11, C + 0.17, C + 0.11, 0.03, metal(rgb("#b4b9be"), brushed=1, gloss=0.6), r=0.02, bevel=0.012)
    for k in range(3):
        y = C - 0.05 + k * 0.05
        cv.line(C - 0.12, y, C + 0.1, y - 0.01, 0.01, 0.04, metal(CHROME, gloss=0.9), bevel=0.003)


def remote(cv):
    cv.rect(C - 0.03, C - 0.09, C + 0.03, C + 0.09, 0.03, plastic(rgb("#1d1f22")), r=0.012, bevel=0.008)
    cv.circle(C, C - 0.06, 0.01, 0.034, solid(rgb("#c43a2e")), bevel=0.0)
    for k in range(4):
        cv.circle(C, C - 0.02 + k * 0.03, 0.008, 0.033, plastic(rgb("#8a8e92")), bevel=0.0)


def shirt(cv):
    cv.rect(C - 0.12, C - 0.1, C + 0.12, C + 0.1, 0.05, fabric(rgb("#3d5f86")), r=0.02, bevel=0.03, dome=0.01)
    cv.groove(C - 0.12, C - 0.005, C + 0.12, C + 0.005, depth=0.008, dark=0.75)
    cv.rect(C - 0.04, C - 0.1, C + 0.04, C - 0.07, 0.055, fabric(rgb("#334f70")), r=0.01, bevel=0.01)


def box(cv):
    cv.rect(C - 0.12, C - 0.12, C + 0.12, C + 0.12, 0.2, solid(rgb("#b9946a"), var=0.05), r=0.01, bevel=0.02)
    cv.groove(C - 0.12, C - 0.005, C + 0.12, C + 0.005, depth=0.006, dark=0.8)
    cv.rect(C - 0.03, C - 0.12, C + 0.03, C + 0.12, 0.205, solid(rgb("#c9b48a")), r=0.0, bevel=0.0)


def map_sheet(cv):
    cv.rect(C - 0.2, C - 0.15, C + 0.2, C + 0.15, 0.02, solid(rgb("#d9d2b8"), var=0.03), r=0.004, bevel=0.004)
    cv.groove(C - 0.2, C - 0.002, C + 0.2, C + 0.002, depth=0.002, dark=0.75)
    cv.groove(C - 0.002, C - 0.15, C + 0.002, C + 0.15, depth=0.002, dark=0.75)
    cv.line(C - 0.15, C + 0.08, C + 0.12, C - 0.1, 0.012, 0.022, solid(rgb("#3a6aa8")), bevel=0.0)
    cv.circle(C + 0.06, C + 0.06, 0.025, 0.022, solid(rgb("#c43a2e")), bevel=0.0)


ITEMS = {k: v for k, v in globals().items() if callable(v) and k in (
    "papers folder book magazine mug plate cup bottle can monitor keyboard mouse phone laptop radio headset "
    "wrench screwdriver flask test_tubes clipboard tray remote shirt box map_sheet").split()}
