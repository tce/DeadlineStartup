;;; Emacs integration regression checks -*- lexical-binding: t; -*-
(require 'ert)
;; Mock built-in frame functions without invoking the machine's native compiler.
(setq native-comp-enable-subr-trampolines nil)

(defvar deadline-test-hook-calls 0)
(defun my-project-hook ()
  ;; Reproduce the user's filename assumption, without loading their init.
  (when (string= (file-name-extension buffer-file-name) "tex")
    (setq deadline-test-hook-calls (1+ deadline-test-hook-calls))))
(defun latex-outline-editor ()
  ;; Reproduce switching buffers from a LaTeX mode hook.
  (set-buffer (get-buffer-create " *deadline-test-outline*")))

(load (getenv "DEADLINE_EMACS_PREPARE_FILE") nil t)

(ert-deftest deadline-startup-preserves-source-for-later-hooks ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/example.tex")
    (let ((source (current-buffer)) (deadline-test-hook-calls 0))
      (latex-outline-editor)
      (should (eq source (current-buffer)))
      (my-project-hook)
      (should (= deadline-test-hook-calls 1)))))

(ert-deftest deadline-startup-skips-file-hook-for-temporary-buffer ()
  (with-temp-buffer
    (let ((deadline-test-hook-calls 0))
      (my-project-hook)
      (should (= deadline-test-hook-calls 0)))))

(ert-deftest deadline-startup-preparation-is-idempotent ()
  (load (getenv "DEADLINE_EMACS_PREPARE_FILE") nil t)
  (with-temp-buffer
    (setq buffer-file-name "/tmp/example.tex")
    (let ((deadline-test-hook-calls 0))
      (my-project-hook)
      (should (= deadline-test-hook-calls 1)))))

(ert-deftest deadline-startup-readiness-survives-frame-renaming ()
  (should (equal (alist-get 'deadline-startup-project deadline-test-frame-parameters)
                 deadline-test-token))
  (cl-letf (((symbol-function 'frame-list) (lambda () '(project-frame)))
            ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
            ((symbol-function 'frame-parameter)
             (lambda (_frame parameter)
               (if (eq parameter 'deadline-startup-project)
                   deadline-test-token
                 "A title changed by the user's configuration"))))
    (should (equal (eval deadline-test-readiness) deadline-test-token))))

(ert-deftest deadline-startup-readiness-rejects-unrelated-frame ()
  (cl-letf (((symbol-function 'frame-list) (lambda () '(unrelated-frame)))
            ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
            ((symbol-function 'frame-parameter) (lambda (&rest _) nil)))
    (should-not (eval deadline-test-readiness))))

(ert-deftest deadline-startup-readiness-rejects-terminal-frame ()
  (should (eq (alist-get 'window-system deadline-test-frame-parameters) 'ns))
  (cl-letf (((symbol-function 'frame-list) (lambda () '(terminal-frame)))
            ((symbol-function 'display-graphic-p) (lambda (&optional _) nil))
            ((symbol-function 'frame-parameter) (lambda (&rest _) deadline-test-token)))
    (should-not (eval deadline-test-readiness))))

(ert-run-tests-batch-and-exit)
