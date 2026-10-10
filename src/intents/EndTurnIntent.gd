class_name EndTurnIntent
extends Intent

## Передать ход сопернику (§3.3). Доступно всегда.

## Кто просит завершить ход, −1 = «не проверять» (ИИ, мирные, старые вызовы).
##
## Нужно для единственной дыры в правах, которую нашёл аудит (§2.4): actor_id у
## этого намерения равен −1, поэтому _validate_actor с его проверкой «юнит твой?»
## для него не запускается вовсе, а NetGame резолвит любое присланное клиентом
## намерение. Клиент мог завершить ЧУЖОЙ ход — а это ещё и слот мирных, и
## распространение огня. Заполненный requester резолвер сверяет с текущей стороной.
##
## NetworkSession supplies the authenticated sender. NetGame checks this requester
## against that peer’s roster seat before the resolver checks the active turn.
var requester: int = -1

func _init(p_requester: int = -1) -> void:
	super(-1)
	requester = p_requester
