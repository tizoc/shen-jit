\\ Expectations for untyped fixtures and saved-image checks.
(shen.x.namespace fixture
  (import result ok err)
  (export success failure)

  (define success
    (:ok X) -> X
    Other -> (error "expected success, got ~S" Other))

  (define failure
    (:err E) -> E
    Other -> (error "expected failure, got ~S" Other)))
