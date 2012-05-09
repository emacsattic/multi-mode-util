(require 'multi-mode)

(defcustom multi-mode-util-inhibit-eval-during-redisplay nil
  "Whether to set `inhibit-eval-during-redisplay' to t in the buffer.
This suppresses `Error during redisplay: (args-out-of-rage ...)' message but
`jit-lock-mode' won't work properly."
  :type 'boolean
  :group 'multi-mode-util)

(defun multi-make-chunk-finder (start-pat end-pat mode)
  `(lambda (pos)
     (let ((start (point-min)) (end (point-max)))
       (save-excursion
         (save-restriction
           (widen)
           (goto-char pos)
           (when (re-search-backward ,end-pat nil t) (setq start (point)))
           (let (s e)
             (goto-char start)
             (when (re-search-forward ,start-pat pos t) (setq s (1+ (point))))
             (goto-char (or s start))
             (when (re-search-forward ,end-pat nil t)
               (re-search-backward ,end-pat nil t)
               (setq e (1- (point))))
             (if (and s e (<= s e) (<= s pos) (<= pos e))
                 (multi-make-list ',mode s e)
               nil)))))))
(defun multi-mode-init (&optional base-mode)
 (interactive)
  (unless (and multi-mode-alist (local-variable-p 'multi-mode-alist))
    (set (make-local-variable 'multi-mode-alist)
         `((,(or base-mode major-mode) . nil))))
  (when multi-mode-util-inhibit-eval-during-redisplay
    (set (make-variable-buffer-local 'inhibit-eval-during-redisplay) t)
    (add-hook
     'multi-indirect-buffer-hook
     '(lambda ()
        (set (make-variable-buffer-local 'inhibit-eval-during-redisplay) t))))
  (multi-mode-install-modes)
  (multi-viper-init)
  (multi-evil-init))
(defun multi-install-chunk-finder (start end mode)
  (unless (assoc mode multi-mode-alist)
    (let ((finder (multi-make-chunk-finder start end mode)))
      (setq multi-mode-alist (append multi-mode-alist `((,mode . ,finder))))
      (multi-install-mode mode finder))))

(defun multi-fontify-current-chunk ()
  "Workaround for fontification."
  (interactive)
  (when (buffer-base-buffer)
      (let ((val (multi-find-mode-at)))
        (if jit-lock-mode
            (save-restriction
              (narrow-to-region (nth 1 val) (nth 2 val))
              (jit-lock-refontify))
          (funcall font-lock-fontify-region-function
                   (nth 1 val) (nth 2 val) nil)))))
(add-hook 'multi-select-mode-hook 'multi-fontify-current-chunk)

(defadvice multi-select-buffer
  (around multi-disable-select-buffer-when-mark-active activate)
  "Workaround for transient-mark-mode."
  (unless (and (boundp 'mark-active) mark-active) ad-do-it))

(defadvice restore-buffer-modified-p
  (around restore-indirect-buffer-modified-p activate)
  "Workaround for Emacs bug: `restore-buffer-modified-p' function does not
respect indirect buffers."
  (if (buffer-base-buffer)
      (with-current-buffer (buffer-base-buffer) ad-do-it)
    ad-do-it))

(defun multi-defadvice-in-base-buffer (func)
  "Workaround for undo/redo.
This is not multi-mode specific problem; undo/redo in indirect buffers seem to
have the same problem."
  (eval `(defadvice ,func
           (around ,(intern (concat (symbol-name func) "-in-base-buffer"))
                   activate)
           (let (pos)
             (with-current-buffer (or (buffer-base-buffer) (current-buffer))
               ad-do-it
               (setq pos (point)))
             (goto-char pos)))))
(multi-defadvice-in-base-buffer 'undo)
(multi-defadvice-in-base-buffer 'redo)
(multi-defadvice-in-base-buffer 'undo-tree-undo)
(multi-defadvice-in-base-buffer 'undo-tree-redo)
(defadvice undo-tree-visualize
  (around undo-tree-visualize-in-base-buffer activate)
  (with-current-buffer (or (buffer-base-buffer) (current-buffer)) ad-do-it))

(defgroup multi-mode-util nil "Customization for multi-mode-util."
  :prefix "multi-mode-util-")

;; Workaround to prevent inconsistency in viper states
(defcustom multi-mode-util-preserved-viper-states
  '(vi-state insert-state emacs-state)
  "States of viper-mode preserved among multiple major modes."
  :type '(symbol)
  :group 'multi-mode-util)
(defvar multi-preserving-viper-states nil)
(defvar multi-viper-hook-alist nil)
(defun multi-viper-hook-name (state)
  (when (symbolp state) (setq state (symbol-name state)))
  (concat "viper-" state "-hook"))
(defun multi-viper-state-name (state)
  (when (symbolp state) (setq state (symbol-name state)))
  (car (split-string state "-")))
(defun multi-viper-change-state (state)
  (let* ((hook (intern (multi-viper-hook-name state)))
         (func (cdr (assoc hook multi-viper-hook-alist)))
         (st (multi-viper-state-name state)))
    (remove-hook hook func)
    (funcall (intern (concat "viper-change-state-to-" st)))
    (add-hook hook func)))
(defun multi-viper-change-base-buffer-state (state)
  (with-current-buffer (multi-base-buffer) (multi-viper-change-state state)))
(defun multi-viper-change-indirect-buffers-state (state)
  (dolist (elt multi-indirect-buffers-alist)
    (with-current-buffer (cdr elt) (multi-viper-change-state state))))
(defun multi-viper-init ()
  (when (and (boundp 'viper-mode) viper-mode)
    (dolist (st multi-mode-util-preserved-viper-states)
      (let ((hook (intern (multi-viper-hook-name st)))
            (func
             `(lambda ()
                (when multi-mode-alist
                  (multi-viper-change-indirect-buffers-state ',st)
                  (unless (buffer-base-buffer)
                    (multi-viper-change-base-buffer-state ',st))))))
        (unless (assoc hook multi-viper-hook-alist)
          (push (cons hook func) multi-viper-hook-alist))
        (add-hook hook func)))))

;; Workaround to prevent inconsistency in evil states
(defcustom multi-mode-util-preserved-evil-states
  '(normal insert emacs)
  "States of evil-mode preserved among multiple major modes."
  :type '(symbol)
  :group 'multi-mode-util)
(defvar multi-preserving-evil-states nil)
(defvar multi-evil-hook-alist nil)
(defun multi-evil-state-name (state)
  (when (symbolp state) (setq state (symbol-name state)))
  (concat "evil-" state "-state"))
(defun multi-evil-hook-name (state)
  (concat (multi-evil-state-name state) "-entry-hook"))
(defun multi-evil-change-state (state)
  (let* ((hook (intern (multi-evil-hook-name state)))
         (func (cdr (assoc hook multi-evil-hook-alist)))
         (st (multi-evil-state-name state)))
    (remove-hook hook func)
    (funcall (intern st) 1)
    (add-hook hook func)))
(defun multi-evil-change-base-buffer-state (state)
  (with-current-buffer (multi-base-buffer)
    (multi-evil-change-state state)))
(defun multi-evil-change-indirect-buffers-state (state)
  (dolist (elt multi-indirect-buffers-alist)
    (with-current-buffer (cdr elt) (multi-evil-change-state state))))
(defun multi-evil-hook-func (state)
  `(lambda ()
     (when multi-mode-alist
       (multi-evil-change-indirect-buffers-state ',state)
       (unless (buffer-base-buffer)
         (multi-evil-change-base-buffer-state ',state)))))
(defun multi-evil-init ()
  (when (and (boundp 'evil-mode) evil-mode)
    (add-hook 'multi-indirect-buffer-hook 'evil-initialize-state)
    (dolist (st multi-mode-util-preserved-evil-states)
      (let ((hook (intern (multi-evil-hook-name st)))
            (func
             `(lambda ()
                (when multi-mode-alist
                  (multi-evil-change-indirect-buffers-state ',st)
                  (unless (buffer-base-buffer)
                    (multi-evil-change-base-buffer-state ',st))))))
        (unless (assoc hook multi-evil-hook-alist)
          (push (cons hook func) multi-evil-hook-alist))
        (add-hook hook func)))))

(provide 'multi-mode-util)
;;; multi-mode-util.el ends here
