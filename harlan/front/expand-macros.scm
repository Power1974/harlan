(library
    (harlan front expand-macros)
  (export expand-macros)
  (import
   (except (chezscheme) gensym)
   (only (elegant-weapons helpers) gensym define-match)
   (elegant-weapons match))

  ;; This is basically going to be syntax-case as given in Dybvig et
  ;; al, 1992. We'll have a notion of primitive syntax and extended
  ;; syntax. We need to be sure that there is primitive syntax for
  ;; every binding form in Harlan, or else we'll get all the capture
  ;; wrong.

  (define-record-type ident (fields name binding marks))
  
(define (match-pat kw* p e sk fk)
  (let ((e (expose e)))
    (cond
      ((and (pair? p) (pair? (cdr p)) (eq? '... (cadr p)))
       (let loop ((e e)
                  (b '()))
         (if (null? e)
             (match-pat kw* (cddr p) e
                        (lambda (b^) (sk `((... . ,b) . ,b^)))
                        fk)
             (match-pat kw* (car p) (car e)
                        (lambda (b^)
                          (loop (cdr e) (snoc b b^)))
                        (lambda ()
                          (match-pat kw* (cddr p) e
                                     (lambda (b^) (sk `((... . ,b) . ,b^)))
                                     fk))))))
      ((and (pair? p) (pair? e))
       (match-pat kw* (car p) (car e)
                  (lambda (b)
                    (match-pat kw* (cdr p) (cdr e)
                               (lambda (b^) (sk (append b b^)))
                               fk))
                  fk))
      ((eq? p '_)
       (sk '()))
      ((and (memq p kw*) (eq? p e))
       (sk '()))
      ((and (symbol? p) (not (memq p kw*)))
       (if (memq e kw*)
           (error 'match-pat "misplaced aux keyword" e)
           (sk (list (cons p e)))))
      ((and (null? p) (null? e))
       (sk '()))
      (else (fk)))))

  (define (subst* p bindings)
    (cond
      ((and (pair? p) (pair? (cdr p)) (eq? '... (cadr p)))
       (let ((bindings... (extract-... (car p) bindings)))
         (if (null? bindings...)
             (subst* (cddr p) bindings)
             (append
              (apply map (cons (lambda b*
                                 (subst* (car p)
                                         (append (apply append b*)
                                                 bindings)))
                               bindings...))
              (subst* (cddr p) bindings)))))
      ((pair? p)
       (cons (subst* (car p) bindings)
             (subst* (cdr p) bindings)))
      ((assq p bindings) => cdr)
      (else p)))

(define (snoc d a)
  (if (null? d)
      (list a)
      (cons (car d) (snoc (cdr d) a))))

(define (extract-... p bindings)
  (if (null? bindings)
      '()
      (let ((rest (extract-... p (cdr bindings)))
            (b (car bindings)))
        (if (and (eq? (car b) '...) (not (null? (cdr b))))
            (let ((names (map car (cadr b))))
              (if (ormap (lambda (x) (mem* x p)) names)
                  (cons (cdr b) rest)
                  rest))
            rest))))

(define (mem* x ls)
  (cond
    ((and (pair? ls) (pair? (cdr ls)) (eq? (cadr ls) '...))
     #f)
    ((pair? ls)
     (or (mem* x (car ls)) (mem* x (cdr ls))))
    (else (eq? x ls))))

  (define (apply-macro kw* patterns e)
    (if (null? patterns)
        (error 'apply-macro "Invalid syntax")
        (match-pat kw* (caar patterns) e
                   (lambda (bindings)
                     (subst* (cadar patterns) bindings))
                   (lambda ()
                     (apply-macro kw* (cdr patterns) e)))))
  
  (define (expand-one e env)
    (match (expose e)
      ((,m . ,args)
       (guard (assq (expose m) env))
       (expand-one ((cdr (assq (expose m) env)) `(,(expose m) . ,args)) env))
      ((,[(lambda (x) (expand-one x env)) -> e*] ...) e*)
      (,x x)))

  (define-match reify
    (,x (guard (symbol? x))
        (getprop x 'rename x))
    ((,[e*] ...) e*)
    (,e e))
  
  ;; This is the main expander driver. It combines parsing too.
  (define (expand-top e env)
    (match e
      (((define-macro ,name (,kw* ...)
          ,patterns ...) . ,rest)
       (guard (symbol? name))
       (expand-top rest (cons (cons name (lambda (e)
                                           (apply-macro kw* patterns e)))
                              env)))
      ((,e . ,[e*])
       (cons (reify (expand-one e env)) e*))
      (() '())))
       
(define (expand-let e)
  (match-pat
   '()
   `(_ ((x e) ...) b ...)
   e
   (lambda (env)
     (let ((x (get-... 'x env))
           (e (get-... 'e env))
           (b (get-... 'b env)))
       (let ((let (gensym 'let))
             (x^ (map gensym x)))
         (putprop let 'rename 'let)
         (match #t
           (#t
            `(,let ((,x^ ,e) ...)
               (subst (begin ,b ...) (,x . ,x^) ...)))))))
   (lambda () (error 'expand-let "invalid syntax" e))))

(define (expand-define e)
  (match-pat
   '()
   `(_ (f x ...) b ...)
   e
   (lambda (env)
     (let ((x (get-... 'x env))
           (b (get-... 'b env)))
       (let ((define (gensym 'define))
             (x^ (map gensym x)))
         (putprop define 'rename 'define)
         (match #t
           (#t
            `(,define (,(lookup 'f env) ,x^ ...)
               (subst (begin ,b ...) (,x . ,x^) ...)))))))
   (lambda () (error 'expand-define "invalid syntax" e))))

(define (get-... x env)
  (match env
    (() '())
    (((... . ,env) . ,rest)
     (let ((env (map (lambda (e) (assq x e)) env)))
       (if (ormap (lambda (x) x) env)
           (map cdr env)
           (get-... x rest))))
    ((,a . ,d)
     (get-... x d))))

(define (lookup x env)
  (cdr (assq x env)))

  ;;(subst y (x . x^))       => y
  ;;(subst x (x . x^))       => (subst x^ (x . x^))
  ;;(subst (e ...) (x . x^)) => ((subst e x x^) ...)
  ;;(subst (subst e (x . x^)) (y . y^)) =>
  ;;  (expose (subst e (x . x^) (y . y^)))
  
  (define (expose e)
    (match e
      ((subst ,x . ,s*)
       (guard (symbol? x))
       (let ((match (assq x s*)))
         (if match
             (expose `(subst ,(cdr match) . ,s*))
             x)))
      ((subst (subst ,e . ,s1) . ,s2)
       (expose `(subst ,e . ,(append s1 s2))))
      ((subst ,atom . ,s*)
       (guard (not (pair? atom)))
       atom)
      ((subst (,e* ...) . ,s*)
       (map (lambda (e)
              `(subst ,e . ,s*))
            e*))
      ((,e . , e*)
       (guard (not (eq? e 'subst)))
       `(,e . ,e*))
      (,x (guard (not (pair? x))) x)))
    
  (define primitive-env `((let . ,expand-let)
                          (define . ,expand-define)))
    
  (define (expand-macros x)
    ;; Assume we got a (module decl ...) form
    `(module . ,(expand-top (cdr x) primitive-env))))