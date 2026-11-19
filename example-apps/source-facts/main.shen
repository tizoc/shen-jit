\\ Load the application, and its compile-commands part if asked for, before running it.
(let Args (value *argv*)
     _ (if (and (= (length Args) 6) (= (hd (tl (tl Args))) "--compile-commands"))
           (module.load "example-apps/source-facts/build.shenmod")
           [])
  (module.load "example-apps/source-facts/source-facts.shenmod"))

(source-facts.main (value *argv*))
