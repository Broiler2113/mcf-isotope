"""Additional loose props, using the same height-map materials as the original items."""
import math
from functools import partial
from core import *

DARK = rgb('#262d33')
WHITE = rgb('#ede9dc')
STEEL = rgb('#b8c5c9')


def block(cv, colour, x=.32, y=.36, w=.36, h=.28):
    cv.rect(x, y, x+w, y+h, .12, painted(rgb(colour)), r=.015, bevel=.015)


def newspaper(cv, edition=0):
    cv.rect(.23, .28, .77, .72, .025, solid(WHITE), r=.002, bevel=.002)
    cv.rect(.27, .32, .73, .365, .029, solid(DARK), r=0, bevel=0)
    for x in [.28, .53]:
        for row in range(5):
            y = .4 + row*.05
            cv.line(x, y, x+.18, y, .012, .03, solid(DARK), bevel=0)
    if edition != 1:
        cv.rect(.28 if edition == 0 else .54, .4, .47 if edition == 0 else .72, .54, .032,
                solid(rgb('#596d76') if edition == 0 else rgb('#986447')), r=0, bevel=0)


def toolbox(cv):
    block(cv, '#b33c2a', .26, .36, .48, .3)
    cv.rect(.4,.3,.6,.36,.13,metal(DARK),r=.02,bevel=.01)
    cv.line(.29,.51,.71,.51,.025,.14,metal(STEEL),bevel=.005)
    for x in [.34,.64]: cv.rect(x,.49,x+.04,.56,.15,metal(STEEL),r=.002,bevel=.004)


def food(cv, kind):
    if kind in ['apple', 'orange']:
        col = '#bb3c29' if kind == 'apple' else '#e58e24'
        cv.circle(.49,.51,.13,.1,plastic(rgb(col)),bevel=.04,dome=.04)
        cv.line(.49,.43,.52,.35,.025,.15,wood(rgb('#63502b')),bevel=.005)
        cv.ellipse(.57,.39,.06,.025,.13,solid(rgb('#4e7c3f')),bevel=.01)
    elif kind == 'bread':
        cv.ellipse(.5,.5,.22,.13,.12,solid(rgb('#bd883f')),bevel=.05,dome=.04)
        for x in [.38,.49,.6]: cv.line(x,.43,x+.03,.57,.025,.16,solid(rgb('#e2ba73')),bevel=.005)
    elif kind == 'sandwich':
        block(cv,'#d9b36a',.35,.35,.3,.3)
        cv.line(.35,.53,.65,.53,.04,.14,solid(rgb('#618e37')),bevel=.003)
        cv.line(.35,.57,.65,.57,.035,.15,solid(rgb('#c85639')),bevel=.003)
    elif kind == 'milk_carton':
        block(cv,'#e5e7db',.38,.32,.24,.37)
        cv.rect(.38,.45,.62,.58,.13,solid(rgb('#468bbb')),r=0,bevel=0)
        cv.line(.38,.35,.62,.35,.025,.15,solid(DARK),bevel=.004)
    elif kind == 'meat':
        cv.ellipse(.5,.5,.2,.13,.07,solid(rgb('#a8413a')),bevel=.03,dome=.02)
        cv.ellipse(.51,.5,.06,.04,.08,solid(rgb('#e6c1aa')),bevel=.01)
    elif kind == 'vegetables':
        for i in range(3):
            cv.line(.37+i*.09,.62,.43+i*.09,.4,.065,.08,solid(rgb('#d8842b')),bevel=.015)
            cv.line(.43+i*.09,.4,.4+i*.09,.31,.035,.09,solid(rgb('#547a38')),bevel=.008)
    else:
        block(cv,'#c7ad78',.3,.38,.4,.25)
        cv.rect(.33,.42,.67,.59,.14,solid(rgb('#d7c650')),r=.025,bevel=.01)
        for x,y in [(.39,.46),(.58,.52)]: cv.circle(x,y,.025,.15,solid(rgb('#ac8b33')),bevel=.006)


def medical(cv, kind):
    if kind in ['first_aid', 'bandages', 'medicine']:
        block(cv, '#f0eadb' if kind != 'first_aid' else '#48754e')
        cv.rect(.46,.39,.54,.61,.14,solid(rgb('#bb3e38')),r=0,bevel=0)
        cv.rect(.39,.46,.61,.54,.14,solid(rgb('#bb3e38')),r=0,bevel=0)
    elif kind == 'syringe':
        cv.line(.3,.5,.72,.5,.025,.06,metal(STEEL),bevel=.005)
        cv.rect(.39,.45,.61,.55,.08,glass(rgb('#d6e5e4')),r=.01,bevel=.01)
        cv.line(.34,.42,.34,.58,.03,.08,plastic(rgb('#4e87b0')),bevel=.005)
    elif kind == 'stethoscope':
        for x in [.4,.6]: cv.line(x,.34,x,.59,.03,.04,plastic(DARK),bevel=.008)
        cv.line(.4,.59,.52,.68,.03,.04,plastic(DARK),bevel=.008)
        cv.line(.6,.59,.52,.68,.03,.04,plastic(DARK),bevel=.008)
        cv.circle(.6,.32,.06,.07,metal(STEEL),bevel=.015)
    else:
        cv.rect(.45,.32,.55,.66,.09,glass(rgb('#94bbc8')),r=.035,bevel=.02)
        cv.rect(.44,.3,.56,.36,.11,plastic(rgb('#a73532')),r=.01,bevel=.01)


def instrument(cv, kind):
    if kind == 'guitar':
        cv.ellipse(.5,.63,.16,.18,.1,wood(rgb('#ac723b')),bevel=.025,dome=.01)
        cv.rect(.46,.15,.54,.6,.13,wood(rgb('#654022')),r=.01,bevel=.01)
        cv.circle(.5,.57,.065,.14,solid(DARK),bevel=.005)
        cv.line(.5,.19,.5,.76,.012,.15,metal(STEEL),bevel=.002)
    elif kind == 'violin':
        cv.ellipse(.5,.58,.11,.19,.09,wood(rgb('#a46631')),bevel=.02)
        cv.rect(.475,.19,.525,.56,.11,wood(DARK),r=.006,bevel=.006)
        cv.line(.7,.25,.7,.78,.018,.08,wood(rgb('#bda074')),bevel=.005)
    else:
        cv.line(.25,.5,.75,.5,.06,.08,metal(STEEL),bevel=.02)
        for x in [.35,.44,.53,.62]: cv.circle(x,.49,.017,.12,solid(DARK),bevel=.002)


def tool(cv, kind):
    colour = rgb('#b48c31') if kind in ['hammer','pliers','drill'] else rgb('#4b7791')
    if kind == 'drill':
        cv.rect(.3,.38,.61,.51,.13,plastic(colour),r=.03,bevel=.02)
        cv.rect(.43,.5,.54,.68,.1,plastic(DARK),r=.02,bevel=.01)
        cv.line(.6,.44,.78,.44,.035,.13,metal(STEEL),bevel=.005)
    elif kind == 'saw':
        cv.rect(.25,.4,.68,.57,.04,metal(STEEL),r=0,bevel=.005)
        cv.rect(.65,.42,.78,.6,.07,wood(colour),r=.025,bevel=.015)
        for x in [.3,.39,.48,.57]: cv.line(x,.56,x+.03,.61,.04,.04,metal(STEEL),bevel=.004)
    else:
        cv.line(.5,.32,.5,.72,.055,.06,wood(colour),bevel=.012)
        if kind == 'hammer': cv.rect(.34,.29,.66,.4,.1,metal(STEEL),r=.015,bevel=.015)
        else:
            for sign in [-1,1]: cv.line(.5,.4,.5+sign*.09,.25,.045,.09,metal(STEEL),bevel=.008)


def equipment(cv, kind):
    if kind == 'handcuffs':
        for x in [.37,.63]:
            cv.circle(x,.5,.105,.05,metal(STEEL),bevel=.015)
            cv.circle(x,.5,.068,.051,solid(DARK),bevel=.003)
        cv.line(.46,.5,.54,.5,.025,.06,metal(STEEL),bevel=.005)
    elif kind in ['rifle','pistol']:
        left,right=(.16,.84) if kind=='rifle' else (.3,.67)
        cv.rect(left,.45,right,.51,.09,metal(DARK),r=.004,bevel=.01)
        cv.rect(.37,.5,.45,.64,.08,wood(rgb('#6d4d34')),r=.012,bevel=.008)
        cv.rect(left,.43,left+.15,.55,.08,wood(rgb('#705538')),r=.012,bevel=.008)
    elif kind == 'ammunition':
        for x in [.35,.45,.55,.65]:
            cv.rect(x,.35,x+.055,.65,.07,metal(rgb('#b9a05c')),r=.018,bevel=.01)
            cv.rect(x,.35,x+.055,.42,.08,metal(rgb('#9e6848')),r=.02,bevel=.008)
    elif kind in ['helmet','hard_hat']:
        col = '#b99832' if kind=='hard_hat' else '#52633a'
        cv.ellipse(.5,.5,.19,.16,.16,painted(rgb(col)),bevel=.06,dome=.05)
        cv.line(.33,.64,.67,.64,.035,.13,painted(rgb(col)),bevel=.01)
    elif kind == 'boots':
        for x in [.33,.55]:
            cv.rect(x,.34,x+.12,.58,.1,fabric(rgb('#61513d')),r=.025,bevel=.02)
            cv.ellipse(x+.06,.59,.075,.09,.12,plastic(DARK),bevel=.025)
    elif kind == 'gloves':
        for x in [.35,.56]:
            cv.rect(x,.43,x+.12,.62,.05,fabric(rgb('#bfa876')),r=.03,bevel=.015)
            for k in range(3): cv.line(x+.025+k*.035,.44,x+.025+k*.035,.34,.027,.05,fabric(rgb('#bfa876')),bevel=.008)
    elif kind == 'backpack':
        block(cv,'#64734b',.33,.28,.34,.46)
        cv.rect(.37,.5,.63,.68,.15,fabric(rgb('#4b593c')),r=.025,bevel=.02)
    elif kind == 'fire_extinguisher':
        cv.rect(.4,.32,.6,.72,.12,painted(rgb('#bb3c31')),r=.07,bevel=.025)
        cv.line(.44,.29,.64,.29,.04,.15,metal(DARK),bevel=.008)
        cv.line(.63,.29,.68,.59,.035,.13,plastic(DARK),bevel=.008)
    elif kind == 'flashlight':
        cv.rect(.42,.3,.58,.66,.09,metal(DARK),r=.03,bevel=.01)
        cv.rect(.39,.27,.61,.37,.11,metal(STEEL),r=.02,bevel=.01)
    elif kind == 'keys':
        cv.circle(.41,.4,.065,.05,metal(STEEL),bevel=.01)
        for x in [.43,.53]: cv.line(.41,.45,x,.65,.025,.05,metal(STEEL),bevel=.005)
    else: # personal case or service supplies
        block(cv,'#46758a')
        cv.rect(.4,.32,.6,.37,.14,metal(DARK),r=.01,bevel=.005)


def science(cv, kind):
    if kind == 'microscope':
        cv.rect(.33,.56,.68,.7,.06,painted(rgb('#d2d7cf')),r=.025,bevel=.015)
        cv.line(.38,.63,.52,.37,.11,.13,metal(STEEL),bevel=.02)
        cv.line(.5,.35,.65,.35,.09,.2,plastic(DARK),bevel=.015)
        cv.rect(.48,.48,.7,.54,.14,metal(DARK),r=.004,bevel=.008)
    elif kind == 'petri_dish':
        cv.circle(.5,.5,.16,.04,glass(rgb('#c4d6cf')),bevel=.02)
        for x,y in [(.43,.46),(.55,.57),(.57,.44)]: cv.circle(x,y,.035,.06,solid(rgb('#73a35a')),bevel=.01)
    else:
        cv.rect(.3,.36,.7,.65,.1,painted(rgb('#757d7a')),r=.015,bevel=.01)
        cv.rect(.35,.4,.57,.53,.12,screen(rgb('#73a983')),r=.004,bevel=.004)
        for x in [.39,.5,.61]: cv.circle(x,.59,.022,.13,metal(STEEL),bevel=.006)


def register(cv):
    block(cv,'#a8b4af',.24,.4,.52,.32)
    cv.rect(.27,.31,.58,.43,.19,plastic(DARK),r=.01,bevel=.01)
    cv.rect(.29,.32,.55,.38,.2,screen(rgb('#68ad89')),r=.003,bevel=.003)
    for y in [.49,.55,.61]:
        for x in [.36,.44,.52]: cv.rect(x,y,x+.04,y+.035,.14,plastic(DARK),r=.002,bevel=.002)
    cv.line(.27,.68,.73,.68,.025,.14,metal(DARK),bevel=.005)


EXTRA_ITEMS = {'newspaper': partial(newspaper, edition=0), 'newspaper_local': partial(newspaper, edition=1),
               'newspaper_science': partial(newspaper, edition=2), 'toolbox': toolbox, 'cash_register': register}
for names, fn in [
    ('apple orange bread sandwich milk_carton meat vegetables cheese', food),
    ('first_aid bandages medicine syringe stethoscope sample_vial', medical),
    ('guitar violin flute', instrument),
    ('hammer pliers drill saw', tool),
    ('handcuffs rifle pistol ammunition helmet hard_hat boots gloves backpack fire_extinguisher flashlight keys suitcase', equipment),
    ('microscope petri_dish multimeter', science),
]:
    for name in names.split(): EXTRA_ITEMS[name] = partial(fn, kind=name)
