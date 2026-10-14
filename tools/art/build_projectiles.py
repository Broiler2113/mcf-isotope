"""Native sprite models for firing effects. Projectiles point to the right.

Run from the project root with Python, NumPy and Pillow:
    python tools/art/build_projectiles.py
"""
import os, math
from core import *


def render(kind):
    cv = Canvas(1, 1, seed=17)
    steel, dark = rgb('#c3c4af'), rgb('#3f4c37')
    if kind == 'smoke':
        for k in range(9):
            a = k * 2.39996
            cv.circle(.5+.16*math.cos(a),.5+.16*math.sin(a),.16,.05,solid(rgb('#b6b5ab'),var=.1),bevel=.1,dome=.03)
    elif kind == 'grenade':
        cv.ellipse(.5,.52,.17,.21,.15,painted(dark),bevel=.04,dome=.03)
        for y in [.42,.52,.62]: cv.line(.36,y,.64,y,.02,.16,solid(rgb('#202d20')),bevel=.003)
        cv.rect(.45,.27,.57,.36,.17,metal(steel),r=.01,bevel=.01)
        cv.line(.55,.29,.65,.6,.04,.18,metal(steel),bevel=.008)
    elif kind in ['muzzle','exhaust']:
        for k in range(7):
            a = k * math.tau / 7
            cv.line(.4,.5,.4+.35*math.cos(a),.5+.27*math.sin(a),.09,.1,solid(rgb('#dc822c')),bevel=.025,emit=.7)
        cv.line(.3,.5,.77,.5,.14,.12,solid(rgb('#fff0a1')),bevel=.035,emit=.95)
    else:
        if kind == 'rocket':
            cv.rect(.25,.42,.75,.58,.12,painted(dark),r=.06,bevel=.02)
            for y in [.34,.58]: cv.rect(.23,y,.35,y+.08,.1,metal(steel),r=.008,bevel=.008)
            cv.line(.66,.5,.83,.5,.085,.14,metal(steel),bevel=.025)
        else:
            cv.line(.16,.5,.7,.5,.07,.1,solid(rgb('#dba64d')),bevel=.015,emit=.6)
            cv.ellipse(.7,.5,.12,.06,.12,solid(rgb('#fff0b2')),bevel=.02,emit=.9)
    return cv.image(shadow=kind not in ['muzzle','exhaust','smoke'])

def main():
    for kind in ['bullet','shell','rocket','grenade','smoke','muzzle','exhaust']:
        name='fx_'+kind
        folder='textures/fx/'+name
        os.makedirs(folder,exist_ok=True)
        render(kind).save(folder+'/'+name+'.png')


if __name__ == '__main__':
    main()
