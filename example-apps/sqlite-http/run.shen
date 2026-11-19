\\ Run from the repository root; the kernel loader is used only to load source code.
(do (module.load "example-apps/sqlite-http/sqlite-http.shenmod")
    (counter-app.main (value *argv*)))
