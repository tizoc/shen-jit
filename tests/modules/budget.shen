(set mods.parent-limit (maxinferences -1))
(module.use [budget-nested])
(set mods.after-nested (maxinferences -1))
(if (value mods.budget-fail) (simple-error "budget failed") done)
