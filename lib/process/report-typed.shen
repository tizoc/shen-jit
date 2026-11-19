(shen.x.namespace process
  (use buffer)

(define report-check
  {report --> report}
  Report -> (if (report? Report) Report (error "process: not an execution report")))

(define child
  {report --> child}
  Report -> (report.child (report-check Report)))

(define status
  {report --> status}
  Report -> (report.status (report-check Report)))

(define input-count
  {report --> fixnum}
  Report -> (report.input-count (report-check Report)))

(define output-count
  {report --> fixnum}
  Report -> (report.output-count (report-check Report)))

(define error-count
  {report --> fixnum}
  Report -> (report.error-count (report-check Report)))

(define output-bytes
  {report --> buffer.view}
  Report -> (report.output-bytes (report-check Report)))

(define error-bytes
  {report --> buffer.view}
  Report -> (report.error-bytes (report-check Report)))

(define pending-input
  {report --> buffer.view}
  Report -> (report.pending-input (report-check Report)))

(define output-observed?
  {report --> boolean}
  Report -> (report.output-observed (report-check Report)))

(define error-observed?
  {report --> boolean}
  Report -> (report.error-observed (report-check Report)))

(define input-read-count
  {report --> fixnum}
  Report -> (fx+ (input-count Report) (buffer.length (pending-input Report))))

)