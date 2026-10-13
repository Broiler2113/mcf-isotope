class_name AIPersonality
extends RefCounted

## Личности ИИ (0.12, решение владельца): уровней сложности больше нет — каждый ИИ играет
## в полную силу HARD, а отличается МАНЕРОЙ. Три личности:
##
##   Tactician — штабной расчёт: план на весь ход, укрытия, сосредоточенный огонь, размен
##               на равных. Это прежний HARD, и по нему меряются остальные.
##   Aggressor — темп любой ценой: идёт вперёд, гранаты и дроны в ход сразу, берёт в плен,
##               давит техникой, бьёт по ближайшему; потери его не останавливают.
##   Fortifier — держит землю: копает окопы, инженеры ставят мешки и ежи, сапёры минируют
##               подходы, стоит в укрытиях и не лезет под огонь, а наступает перебежками,
##               когда раунды идут и стоять дальше бессмысленно.
##
## Номера совпадают с AIController.Style (STANDARD/RUSH/TURTLE), и это не случайность:
## обучение RL (rl/config/*.yaml, opponent_styles) зовёт манеры HARD по номеру, и старые
## конфиги на ноутбуке владельца обязаны работать после обновления. Четвёртая манера,
## FLANK, осталась ТОЛЬКО для обучения — в игре её не выбрать.

const TACTICIAN := 0
const AGGRESSOR := 1
const FORTIFIER := 2
## Порядок в лобби и в настройках.
const ALL: Array[int] = [TACTICIAN, AGGRESSOR, FORTIFIER]
const NAMES := ["Tactician", "Aggressor", "Fortifier"]
const BLURBS := [
	"Plans the whole turn, uses cover, concentrates fire and trades evenly.",
	"Pushes forward, spends grenades and drones early, takes prisoners and accepts losses for tempo.",
	"Digs trenches, builds sandbags, mines the approaches and holds ground; advances by bounds when it must.",
]

static func name_of(style: int) -> String:
	return NAMES[style] if style >= 0 and style < NAMES.size() else "Tactician"

static func blurb_of(style: int) -> String:
	return BLURBS[style] if style >= 0 and style < BLURBS.size() else BLURBS[0]

## Прежние веса штаба (#100) — ими по-прежнему ходят мирные жители: их поведение
## личности не меняют.
const CLASSIC := {
	"fire": 30.0, "fire_ease": 2.0, "advance": 3.0, "cover": 2.5, "trench": 2.0,
	"danger": -5.0, "stay": 2.0, "step": -0.15,
}

## Всё, чем личность отличается: веса штабной раскладки клеток (AIPlanner) и ручки
## отдельных решений (AIController). round — номер раунда: Fortifier со временем смелеет.
static func profile(style: int, round: int = 1) -> Dictionary:
	match style:
		AGGRESSOR:
			return {
				"fire": 30.0, "fire_ease": 2.0, "advance": 5.0, "cover": 2.0, "trench": 1.5,
				"danger": -1.5, "stay": 0.5, "step": -0.1,
				# Самосохранение (owner rule, 0.12): и Aggressor не лезет под огонь зря —
				# он наступает, но от укрытия к укрытию.
				"threat": -10.0, "shelter": 4.0,
				# По ближайшему: цель ближе на клетку — на столько дороже.
				"near_target": 1.2,
				# Граната летит, если в среднем убьёт хотя бы столько.
				"grenade_min": 0.55,
				# Дымовая: сколько ожидаемых попаданий должна закрыть завеса.
				"smoke_min": 0.6,
				"capture_bonus": 20.0,
				"dig": 0.0, "build": 0.0, "mine_bonus": -12.0, "mine_cap": 6,
				"vehicle_gain": 1.8,
			}
		FORTIFIER:
			return {
				"fire": 30.0, "fire_ease": 3.0, "advance": _bounding(round), "cover": 6.0,
				"trench": 2.5, "danger": -9.0, "stay": 6.0, "step": -0.2,
				"threat": -20.0, "shelter": 10.0,
				"near_target": 0.0,
				"grenade_min": 0.9,
				"smoke_min": 0.7,
				"capture_bonus": 0.0,
				"dig": 58.0, "build": 56.0, "mine_bonus": 10.0, "mine_cap": 24,
				"vehicle_gain": 0.7,
			}
		_:
			return {
				"fire": 30.0, "fire_ease": 2.0, "advance": 3.0, "cover": 4.0, "trench": 2.0,
				"danger": -5.0, "stay": 2.0, "step": -0.15,
				"threat": -15.0, "shelter": 7.0,
				"near_target": 0.0,
				"grenade_min": 0.9,
				"smoke_min": 0.8,
				"capture_bonus": 0.0,
				"dig": 0.0, "build": 0.0, "mine_bonus": 0.0, "mine_cap": 12,
				"vehicle_gain": 1.0,
			}

## Fortifier стоит, пока стоять выгодно, но не вечно: две крепости друг против друга иначе
## просидели бы весь бой. Первые раунды — почти на месте, потом перебежками от укрытия к
## укрытию (вес укрытий остаётся высоким), к концу — обычный темп.
static func _bounding(round: int) -> float:
	if round <= 3:
		return 0.4
	if round <= 6:
		return 1.4
	return 2.6
