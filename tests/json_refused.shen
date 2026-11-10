\\ A JSON value is not a string or a number without json.string or a match.
(define json-refused.string {json.value --> string} X -> X)
\\ next
(define json-refused.number {json.value --> number} X -> X)
\\ next
(define json-refused.list {json.value --> (list json.value)} X -> X)
