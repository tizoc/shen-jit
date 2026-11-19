(datatype mods-internal ____ private-token : mods-rep;)
(datatype mods-public ____ public-token : mods-public-type;)
(datatype mods-reenabled ____ another-token : mods-public-type;)
(preclude [mods-internal mods-reenabled])
