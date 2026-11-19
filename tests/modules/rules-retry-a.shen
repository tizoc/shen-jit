(datatype mods-retry-t S : string; ========== [retry S] : mods-retry-t;)
(if (value mods.retry-fail) (simple-error "retry failed") skip)
