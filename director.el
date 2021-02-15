;;; director.el --- Simulate user sessions -*- lexical-binding: t -*-

;; Copyright (C) 2021 Massimiliano Mirra

;; Author: Massimiliano Mirra <hyperstruct@gmail.com>
;; URL: https://github.com/bard/emacs-director
;; Version: 0.1
;; Package-Requires: ((emacs "27.1"))
;; Keywords:

;; This file is not part of GNU Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Simulate user sessions.

;;; Code:

(defvar director--delay 0.1)
(defvar director--steps nil)
(defvar director--start-time nil)
(defvar director--counter 0)
(defvar director--error nil)
(defvar director--before-start-function nil)
(defvar director--after-end-function nil)
(defvar director--before-step-function nil)
(defvar director--after-step-function nil)
(defvar director--on-error nil)
(defvar director--log-target nil)
(defvar director--typing-style nil)

(defun director-run (&rest config)
  (director--read-config config)
  (setq director--start-time (float-time))
  (director--before-start)
  (director--schedule-next))

(defun director--read-config (config)
  (or (setq director--steps (plist-get config :steps))
      (error "Missing `:steps' argument."))
  (when (plist-member config :delay-between-steps)
    (setq director--delay (plist-get config :delay-between-steps)))
  (when (plist-member config :before-step)
    (setq director--before-step-function (plist-get config :before-step)))
  (when (plist-member config :before-start)
    (setq director--before-start-function (plist-get config :before-start)))
  (when (plist-member config :after-end)
    (setq director--after-end-function (plist-get config :after-end)))
  (when (plist-member config :after-step)
    (setq director--after-step-function (plist-get config :after-step)))
  (when (plist-member config :on-error)
    (setq director--on-error (plist-get config :on-error)))
  (when (plist-member config :log-target)
    (setq director--log-target (plist-get config :log-target)))
  (when (plist-member config :typing-style)
    (setq director--typing-style (plist-get config :typing-style))))

(defun director--log (message)
  (when director--log-target
    (let ((log-line (format "%06d %03d %s\n"
                            (round (- (* 1000 (float-time))
                                      (* 1000 director--start-time)))
                            director--counter
                            message))
          (target-type (car director--log-target))
          (target-name (cdr director--log-target)))
      (pcase target-type
        ('buffer
         (with-current-buffer (get-buffer-create target-name)
           (goto-char (point-max))
           (insert log-line)))
        ('file
         (let ((save-silently t))
           (append-to-file log-line nil target-name)))
        (_
         (error "Unrecognized log target type: %S" target-type))))))

(defun director--schedule-next (&optional delay-override)
  (cond
   (director--error
    (director--log (format "ERROR %S" director--error))
    (director--after-end)
    (when director--on-error
      ;; Give time to the current event loop iteration to finish
      ;; in case the on-error hook is a `kill-emacs'
      (run-with-timer 0.05 nil director--on-error)))

   ((length= director--steps 0)
    (director--after-step)
    (run-with-timer director--delay nil 'director--after-end))

   (t
    (unless (eq director--counter 0)
      (director--after-step))
    (let* ((next-step (car director--steps))
           (delay (cond (delay-override delay-override)
                        ((and (listp next-step)
                              (member (car next-step) '(:call :type)))
                         director--delay)
                        (t 0.05))))
      (run-with-timer delay
                      nil
                      (lambda ()
                        (director--before-step)
                        (director--exec-step-then-next)))))))

(defun director--exec-step-then-next ()
  (let ((step (car director--steps)))
    (setq director--counter (1+ director--counter)
          director--steps (cdr director--steps))
    (director--log (format "STEP %S" step))
    (condition-case err
        (pcase step
          
          (`(:call ,command)
           ;; Next step must be scheduled before executing the command, because
           ;; the command might block (e.g. when requesting input) in which case
           ;; we'd never get to schedule the step.
           (director--schedule-next)
           (call-interactively command))

          (`(:log ,form)
           (director--schedule-next)
           (director--log (format "LOG %S" (eval form))))

          (`(:type ,key-sequence)
           (if (eq director--typing-style 'human)
               (director--simulate-human-typing
                (listify-key-sequence key-sequence)
                'director--schedule-next)
             (director--schedule-next)
             (setq unread-command-events
                   (listify-key-sequence key-sequence))))

          (`(:wait ,delay)
           (director--schedule-next delay))

          (`(:assert ,condition)
           (director--schedule-next)
           (or (eval condition)
               (error "Expectation failed: `%S'" condition)))

          (step
           (director--schedule-next)
           (error "Unrecognized step: %S" step)))

      ;; Save error so that already scheduled step can handle it
      (error (setq director--error err)))))

(defun director--simulate-human-typing (command-events callback)
  (if command-events
      (let* ((base-delay-ms 50)
             (random-variation-ms (- (random 50) 25))
             (delay-s (/ (+ base-delay-ms random-variation-ms) 1000.0)))
        (setq unread-command-events (list (car command-events)))
        (run-with-timer delay-s nil 'director--simulate-human-typing (cdr command-events) callback))
    (funcall callback)))

;;; Hooks

(defun director--before-step ()
  (when director--before-step-function
    (funcall director--before-step-function)))

(defun director--after-step ()
  (when director--after-step-function
    (funcall director--after-step-function)))

(defun director--before-start ()
  (when director--before-start-function
    (funcall director--before-start-function)))

(defun director--after-end ()
  (director--log "END")
  (setq director--counter 0
        director--start-time nil
        director--error nil)
  (when director--after-end-function
    (funcall director--after-end-function)))

;;; Utilities

(defun director-capture-screen (file-name-pattern)
  (let ((capture-directory (file-name-directory file-name-pattern))
        (file-name-pattern (or file-name-pattern
                               (concat temporary-file-directory
                                       "director-capture.%d"))))
    (make-directory capture-directory t)
    (call-process "screen"
                  nil nil nil
                  "-X" "hardcopy" (format file-name-pattern
                                          director--counter))))

;;; Meta

(provide 'director)

;;; director.el ends here
