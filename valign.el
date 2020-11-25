;;; valign.el --- Visually align tables      -*- lexical-binding: t; -*-

;; Author: Yuan Fu <casouri@gmail.com>
;; URL: https://github.com/casouri/valign
;; Version: 2.3.0
;; Keywords: convenience
;; Package-Requires: ((emacs "26.0"))

;;; This file is NOT part of GNU Emacs

;;; Commentary:
;;
;; This package provides visual alignment for Org and Markdown tables
;; on GUI Emacs.  It can properly align tables containing
;; variable-pitch font, CJK characters and images.  In the meantime,
;; the text-based alignment generated by Org mode (or Markdown mode)
;; is left untouched.
;;
;; To use this package, load it and run M-x valign-mode RET.  And any
;; Org tables in Org mode should be automatically aligned.  If you want
;; to align a table manually, run M-x valign-table RET on a table.
;;
;; Valign provides two styles of separator, |-----|-----|, and
;; |           |.  Customize ‘valign-separator-row-style’ to set a
;; style.
;;
;; TODO:
;;
;; - Hidden links in markdown still occupy the full length of the link
;;   because it uses character composition, which we don’t support.

;;; Developer:
;;
;; We decide to re-align in jit-lock hook, that means any change that
;; causes refontification will trigger re-align.  This may seem
;; inefficient and unnecessary, but there are just too many things
;; that can mess up a table’s alignment.  Therefore it is the most
;; reliable to re-align every time there is a refontification.
;; However, we do have a small optimization for typing in a table: if
;; the last command is 'self-insert-command', we don’t realign.  That
;; should improve the typing experience in large tables.

;;; Code:
;;

(require 'cl-lib)
(require 'pcase)

(defcustom valign-lighter " valign"
  "The lighter string used by function `valign-mode'."
  :group 'valign
  :type 'string)

;;; Backstage

(define-error 'valign-bad-cell "Valign encountered a invalid table cell")
(define-error 'valign-not-gui "Valign only works in GUI environment")
(define-error 'valign-not-on-table "Valign is asked to align a table, but the point is not on one")

(defun valign--cell-alignment ()
  "Return how is current cell aligned.
Return 'left if aligned left, 'right if aligned right.
Assumes point is after the left bar (“|”).
Doesn’t check if we are in a cell."
  (save-excursion
    (if (looking-at " [^ ]")
        'left
      (if (not (search-forward "|" nil t))
          (signal 'valign-bad-cell nil)
        (if (looking-back
             "[^ ] |" (max (- (point) 3) (point-min)))
            'right
          'left)))))

(defun valign--cell-content-config ()
  "Return (CELL-BEG CONTENT-BEG CONTENT-END CELL-END).
CELL-BEG is after the left bar, CELL-END is before the right bar.
CELL-CONTENT contains the actual non-white-space content,
possibly with a single white space padding on the either side, if
there are more than one white space on that side.

If the cell is empty, CONTENT-BEG is

    (min (CELL-BEG + 1) CELL-END)

CONTENT-END is

    (max (CELL-END - 1) CELL-BEG)

Assumes point is after the left bar (“|”).  Assumes there is a
right bar."
  (save-excursion
    (let ((cell-beg (point))
          (cell-end (save-excursion
                      (search-forward "|" (line-end-position))
                      (match-beginning 0)))
          ;; `content-beg-strict' is the beginning of the content
          ;; excluding any white space. Same for `content-end-strict'.
          content-beg-strict content-end-strict)
      (if (save-excursion (skip-chars-forward " ") (looking-at-p "|"))
          ;; Empty cell.
          (list cell-beg
                (min (1+ cell-beg) cell-end)
                (max (1- cell-end) cell-beg)
                cell-end)
        ;; Non-empty cell.
        (skip-chars-forward " ")
        (setq content-beg-strict (point))
        (goto-char cell-end)
        (skip-chars-backward " ")
        (setq content-end-strict (point))
        ;; Calculate delimiters. Basically, we try to preserve a white
        ;; space on the either side of the content, i.e., include them
        ;; in (BEG . END). Because if you are typing in a cell and
        ;; type a space, you probably want valign to keep that space
        ;; as cell content, rather than to consider it as part of the
        ;; padding and add overlay over it.
        (list cell-beg
              (if (= (- content-beg-strict cell-beg) 1)
                  content-beg-strict
                (1- content-beg-strict))
              (if (= (- cell-end content-end-strict) 1)
                  content-end-strict
                (1+ content-end-strict))
              cell-end)))))

(defun valign--cell-empty-p ()
  "Return non-nil if cell is empty.
Assumes point is after the left bar (“|”)."
  (save-excursion
    (and (skip-chars-forward " ")
         (looking-at "|"))))

(defun valign--cell-content-width ()
  "Return the pixel width of the cell at point.
Assumes point is after the left bar (“|”).
Return nil if not in a cell."
  ;; We assumes:
  ;; 1. Point is after the left bar (“|”).
  ;; 2. Cell is delimited by either “|” or “+”.
  ;; 3. There is at least one space on either side of the content,
  ;;    unless the cell is empty.
  ;; IOW: CELL      := <DELIM>(<EMPTY>|<NON-EMPTY>)<DELIM>
  ;;      EMPTY     := <SPACE>+
  ;;      NON-EMPTY := <SPACE>+<NON-SPACE>+<SPACE>+
  ;;      DELIM     := | or +
  (pcase-let ((`(,_a ,beg ,end ,_b) (valign--cell-content-config)))
    (valign--pixel-width-from-to beg end)))

;; Sometimes, because of Org's table alignment, empty cell is longer
;; than non-empty cell.  This usually happens with CJK text, because
;; CJK characters are shorter than 2x ASCII character but Org treats
;; CJK characters as 2 ASCII characters when aligning.  And if you
;; have 16 CJK char in one cell, Org uses 32 ASCII spaces for the
;; empty cell, which is longer than 16 CJK chars.  So better regard
;; empty cell as 0-width rather than measuring it's white spaces.
(defun valign--cell-nonempty-width ()
  "Return the pixel width of the cell at point.
If the cell is empty, return 0.  Otherwise return cell content’s
width."
  (if (valign--cell-empty-p) 0
    (valign--cell-content-width)))

;; We used to use a custom functions that calculates the pixel text
;; width that doesn’t require a live window.  However that function
;; has some limitations, including not working right with face remapping.
;; With this function we can avoid some of them.  However we still can’t
;; get the true tab width, see comment in ‘valgn--tab-width’ for more.
(defun valign--pixel-width-from-to (from to &optional with-prefix)
  "Return the width of the glyphs from FROM (inclusive) to TO (exclusive).
The buffer has to be in a live window.  FROM has to be less than
TO and they should be on the same line.  Valign display
properties must be cleaned before using this.

If WITH-PREFIX is non-nil, don’t subtract the width of line
prefix."
  (let* ((window (get-buffer-window))
         ;; This computes the prefix width.  This trick doesn’t seem
         ;; work if the point is at the beginning of a line, so we use
         ;; TO instead of FROM.
         ;;
         ;; Why all this fuss: Org puts some display property on white
         ;; spaces in a cell: (space :relative-width 1).  And that
         ;; messes up the calculation of prefix: now it returns the
         ;; width of a space instead of 0 when there is no line
         ;; prefix.  So we move the test point around until it doesn’t
         ;; sit on a character with display properties.
         (line-prefix
          (let ((pos to))
            (while (get-char-property pos 'display)
              (cl-decf pos))
            (car (window-text-pixel-size window pos pos)))))
    (- (car (window-text-pixel-size window from to))
       (if with-prefix 0 line-prefix)
       (if (bound-and-true-p display-line-numbers-mode)
           (line-number-display-width 'pixel)
         0))))

(defun valign--separator-p ()
  "If the current cell is actually a separator.
Assume point is after the left bar (“|”)."
  (or (eq (char-after) ?:) ;; Markdown tables.
      (eq (char-after) ?-)))

(defun valign--alignment-from-seperator ()
  "Return the alignment of this column.
Assumes point is after the left bar (“|”) of a separator
cell.  We don’t distinguish between left and center aligned."
  (save-excursion
    (if (eq (char-after) ?:)
        'left
      (skip-chars-forward "-")
      (if (eq (char-after) ?:)
          'right
        'left))))

(defmacro valign--do-row (row-idx-sym limit &rest body)
  "Go to each row’s beginning and evaluate BODY.
At each row, stop at the beginning of the line.  Start from point
and stop at LIMIT.  ROW-IDX-SYM is bound to each row’s
index (0-based)."
  (declare (debug (sexp form &rest form))
           (indent 2))
  `(progn
     (setq ,row-idx-sym 0)
     (while (<= (point) ,limit)
       (beginning-of-line)
       ,@body
       (forward-line)
       (cl-incf ,row-idx-sym))))

(defmacro valign--do-column (column-idx-sym &rest body)
  "Go to each column in the row and evaluate BODY.
Start from point and stop at the end of the line.  Stop after the
cell bar (“|”) in each iteration.
COLUMN-IDX-SYM is bound to the index of the column (0-based)."
  (declare (debug (sexp &rest form))
           (indent 1))
  `(progn
     (setq ,column-idx-sym 0)
     (beginning-of-line)
     (while (search-forward "|" (line-end-position) t)
       ;; Unless we are after the last bar.
       (unless (looking-at "[^|]*\n")
         ,@body)
       (cl-incf ,column-idx-sym))))

(defun valign--alist-to-list (alist)
  "Convert an ALIST ((0 . a) (1 . b) (2 . c)) to (a b c)."
  (let ((inc 0) return-list)
    (while (alist-get inc alist)
      (push (alist-get inc alist)
            return-list)
      (cl-incf inc))
    (reverse return-list)))

(defun valign--calculate-cell-width (limit)
  "Return a list of column widths.
Each column width is the largest cell width of the column.
Start from point, stop at LIMIT."
  (let (row-idx column-idx column-width-alist)
    (ignore row-idx)
    (save-excursion
      (valign--do-row row-idx limit
        (valign--do-column column-idx
          ;; Point is after the left “|”.
          ;;
          ;; Calculate this column’s pixel width, record it if it
          ;; is the largest one for this column.
          (unless (valign--separator-p)
            (let ((oldmax (alist-get column-idx column-width-alist))
                  (cell-width (valign--cell-nonempty-width)))
              ;; Why “=”: if cell-width is 0 and the whole column is 0,
              ;; still record it.
              (if (>= cell-width (or oldmax 0))
                  (setf (alist-get column-idx column-width-alist)
                        cell-width)))))))
    ;; Turn alist into a list.
    (mapcar (lambda (width) (+ width 16))
            (valign--alist-to-list column-width-alist))))

(cl-defmethod valign--calculate-alignment ((type (eql markdown)) limit)
  "Return a list of alignments ('left or 'right) for each column.
TYPE must be 'markdown.  Start at point, stop at LIMIT."
  (ignore type)
  (let (row-idx column-idx column-alignment-alist)
    (ignore row-idx)
    (save-excursion
      (valign--do-row row-idx limit
        (when (valign--separator-p)
          (valign--do-column column-idx
            (setf (alist-get column-idx column-alignment-alist)
                  (valign--alignment-from-seperator))))))
    (if (not column-alignment-alist)
        (save-excursion
          (valign--do-column column-idx
            (push 'left column-alignment-alist))
          column-alignment-alist)
      (valign--alist-to-list column-alignment-alist))))

(cl-defmethod valign--calculate-alignment ((type (eql org)) limit)
  "Return a list of alignments ('left or 'right) for each column.
TYPE must be 'org.  Start at point, stop at LIMIT."
  ;; Why can’t infer the alignment on each cell by its space padding?
  ;; Because the widest cell of a column has one space on both side,
  ;; making it impossible to infer the alignment.
  (ignore type)
  (let (column-idx column-alignment-alist row-idx)
    (ignore row-idx)
    (save-excursion
      (valign--do-row row-idx limit
        (valign--do-column column-idx
          (when (not (valign--separator-p))
            (setf (alist-get column-idx column-alignment-alist)
                  (cons (valign--cell-alignment)
                        (alist-get column-idx column-alignment-alist))))))
      ;; Now we have an alist
      ;; ((0 . (left left right left ...) (1 . (...))))
      ;; For each column, we take the majority.
      (cl-labels ((majority (list)
                            (let ((left-count (cl-count 'left list))
                                  (right-count (cl-count 'right list)))
                              (if (> left-count right-count)
                                  'left 'right))))
        (mapcar #'majority
                (valign--alist-to-list column-alignment-alist))))))

(defun valign--at-table-p ()
  "Return non-nil if point is in a table."
  (save-excursion
    (beginning-of-line)
    (let ((face (plist-get (text-properties-at (point)) 'face)))
      ;; Don’t align tables in org blocks.
      (and (looking-at "[ \t]*[|\\+]")
           (not (and (consp face)
                     (or (equal face '(org-block))
                         (equal (plist-get face :inherit)
                                '(org-block)))))))))

(defun valign--beginning-of-table ()
  "Go backward to the beginning of the table at point.
Assumes point is on a table."
  (beginning-of-line)
  (let ((p (point)))
    (catch 'abort
      (while (looking-at "[ \t]*[|\\+]")
        (setq p (point))
        (if (eq (point) (point-min))
            (throw 'abort nil))
        (forward-line -1)
        (beginning-of-line)))
    (goto-char p)))

(defun valign--end-of-table ()
  "Go forward to the end of the table at point.
Assumes point is on a table."
  (end-of-line)
  (while (looking-at "\n[ \t]*[|\\+]")
    (forward-line)
    (end-of-line)))

(defun valign--put-overlay (beg end &rest props)
  "Put overlay between BEG and END.
PROPS contains properties and values."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'valign t)
    (overlay-put ov 'evaporate t)
    (while props
      (overlay-put ov (pop props) (pop props)))))

(defsubst valign--space (xpos)
  "Return a display property that aligns to XPOS."
  `(space :align-to (,xpos)))

(defvar valign-fancy-bar)
(defun valign--maybe-render-bar (point)
  "Make the character at POINT a full height bar.
But only if `valign-fancy-bar' is non-nil."
  (when valign-fancy-bar
    (valign--render-bar point)))

(defun valign--fancy-bar-cursor-fn (window prev-pos action)
  "Run when point enters or left a fancy bar.
Because the bar is so thin, the cursor disappears in it.  We
expands the bar so the cursor is visible.  'cursor-intangible
doesn’t work because it prohibits you to put the cursor at BOL.

WINDOW is just window, PREV-POS is the previous point of cursor
before event, ACTION is either 'entered or 'left."
  (ignore window)
  (with-silent-modifications
    (let ((ov-list (overlays-at (pcase action
                                  ('entered (point))
                                  ('left prev-pos)))))
      (dolist (ov ov-list)
        (when (overlay-get ov 'valign-bar)
          (overlay-put
           ov 'display (pcase action
                         ('entered (if (eq cursor-type 'bar)
                                       '(space :width (3)) " "))
                         ('left '(space :width (1))))))))))

(defun valign--render-bar (point)
  "Make the character at POINT a full-height bar."
  (with-silent-modifications
    (put-text-property point (1+ point)
                       'cursor-sensor-functions
                       '(valign--fancy-bar-cursor-fn))
    (valign--put-overlay point (1+ point)
                         'face '(:inverse-video t)
                         'display '(space :width (1))
                         'valign-bar t)))

(defun valign--clean-text-property (beg end)
  "Clean up the display text property between BEG and END."
  (with-silent-modifications
    (put-text-property beg end 'cursor-sensor-functions nil))
  (let ((ov-list (overlays-in beg end)))
    (dolist (ov ov-list)
      (when (overlay-get ov 'valign)
        (delete-overlay ov)))))

(defun valign--glyph-width-of (string point)
  "Return the pixel width of STRING with font at POINT.
STRING should have length 1."
  (aref (aref (font-get-glyphs (font-at point) 0 1 string) 0) 4))

(cl-defmethod valign--align-separator-row
  (type (style (eql single-column)) column-width-list)
  "Align the separator row (|---+---|) as “|---------|”.
Assumes the point is after the left bar (“|”).  TYPE can be
either 'org-mode or 'markdown.  STYLE is 'single-column.
COLUMN-WIDTH-LIST is returned from
`valign--calculate-cell-width'."
  (ignore type style)
  (let* ((p (point))
         (column-count (length column-width-list))
         (bar-width (valign--glyph-width-of "|" p))
         ;; Position of the right-most bar.
         (total-width (+ (apply #'+ column-width-list)
                         (* bar-width (1+ column-count)))))
    ;; Render the left bar.
    (valign--maybe-render-bar (1- (point)))
    (when (re-search-forward "[|\\+]" nil t)
      (valign--put-overlay p (1- (point)) total-width
                           'face '(:strike-through t))
      ;; Render the right bar.
      (valign--maybe-render-bar (1- (point))))))

(defun valign--separator-row-add-overlay (beg end right-pos)
  "Add overlay to a separator row’s “cell”.
Cell ranges from BEG to END, the pixel position RIGHT-POS marks
the position for the right bar (“|”).
Assumes point is on the right bar or plus sign."
  ;; Make “+” look like “|”
  (if valign-fancy-bar
      ;; Render the right bar.
      (valign--render-bar end)
    (when (eq (char-after end) ?+)
      (let ((ov (make-overlay end (1+ end))))
        (overlay-put ov 'display "|")
        (overlay-put ov 'valign t))))
  ;; Markdown row
  (when (eq (char-after beg) ?:)
    (setq beg (1+ beg)))
  (when (eq (char-before end) ?:)
    (setq end (1- end)
          right-pos (- right-pos
                       (valign--pixel-width-from-to (1- end) end))))
  ;; End of Markdown
  (valign--put-overlay beg end
                       'display (valign--space right-pos)
                       'face '(:strike-through t)))

(cl-defmethod valign--align-separator-row
  (type (style (eql multi-column)) column-width-list)
  "Align the separator row in multi column style.
TYPE can be 'org-mode or 'markdown-mode, STYLE is 'multi-column.
COLUMN-WIDTH-LIST is returned from
`valign--calculate-cell-width'."
  (ignore type style)
  (let ((bar-width (valign--glyph-width-of "|" (point)))
        (space-width (valign--glyph-width-of " " (point)))
        (column-start (point))
        (col-idx 0)
        (pos (valign--pixel-width-from-to
              (line-beginning-position) (point) t)))
    ;; Render the first left bar.
    (valign--maybe-render-bar (1- (point)))
    ;; Specially handle separator lines like “+--+--+”.
    (when (looking-back "\\+" 1)
      (valign--put-overlay (1- (point)) (point) 'display "|")
      (setq pos (valign--pixel-width-from-to
                 (line-beginning-position) (point) t)))
    ;; Add overlay in each column.
    (while (re-search-forward "[+|]" (line-end-position) t)
      ;; Render the right bar.
      (valign--maybe-render-bar (1- (point)))
      (let ((column-width (nth col-idx column-width-list)))
        (valign--separator-row-add-overlay
         column-start (1- (point)) (+ pos column-width space-width))
        (setq column-start (point)
              pos (+ pos column-width bar-width space-width))
        (cl-incf col-idx)))))

(defun valign--guess-table-type ()
  "Return either 'org or 'markdown."
  (cond ((derived-mode-p 'org-mode 'org-agenda-mode) 'org)
        ((derived-mode-p 'markdown-mode) 'markdown)
        ((string-match-p "org" (symbol-name major-mode)) 'org)
        ((string-match-p "markdown" (symbol-name major-mode)) 'markdown)
        (t 'org)))

;;; Userland

(defcustom valign-separator-row-style 'multi-column
  "The style of the separator row of a table.
Valign can render it as “|-----------|”
or as “|-----|-----|”.  Set this option to 'single-column
for the former, and 'multi-column for the latter.
You need to restart valign mode or realign tables for this
setting to take effect."
  :type '(choice
          (const :tag "Multiple columns" multi-column)
          (const :tag "A single column" single-column))
  :group 'valign)

(defcustom valign-fancy-bar nil
  "Non-nil means to render bar as a full-height line.
You need to restart valign mode for this setting to take effect."
  :type '(choice
          (const :tag "Enable fancy bar" t)
          (const :tag "Disable fancy bar" nil))
  :group 'valign)

(defun valign-table ()
  "Visually align the table at point."
  (interactive)
  (valign-table-maybe t))

(defvar valign-not-align-after-list '(self-insert-command
                                      org-self-insert-command
                                      markdown-outdent-or-delete
                                      org-delete-backward-char
                                      backward-kill-word
                                      delete-char
                                      kill-word)
  "Valign doesn’t align table after these commands.")

(defun valign-table-maybe (&optional force)
  "Visually align the table at point.
If FORCE non-nil, force align."
  (condition-case err
      (save-excursion
        (when (and (display-graphic-p)
                   (valign--at-table-p)
                   (or force
                       (not (memq (or this-command last-command)
                                  valign-not-align-after-list))))
          (valign-table-1)))
    ((valign-bad-cell search-failed error)
     (valign--clean-text-property
      (save-excursion (valign--beginning-of-table) (point))
      (save-excursion (valign--end-of-table) (point)))
     (when (eq (car err) 'error)
       (error (error-message-string err))))))

(defun valign-table-1 ()
  "Visually align the table at point."
  (valign--beginning-of-table)
  (let* ((space-width (valign--glyph-width-of " " (point)))
         (bar-width (valign--glyph-width-of "|" (point)))
         (table-beg (point))
         (table-end (save-excursion (valign--end-of-table) (point)))
         ;; Very hacky, but..
         (_ (valign--clean-text-property table-beg table-end))
         (column-width-list (valign--calculate-cell-width table-end))
         (column-alignment-list (valign--calculate-alignment
                                 (valign--guess-table-type) table-end))
         row-idx column-idx column-start)
    (ignore row-idx)

    ;; Align each row.
    (valign--do-row row-idx table-end
      (re-search-forward "[|\\+]" (line-end-position))
      (if (valign--separator-p)
          ;; Separator row.
          (valign--align-separator-row
           (valign--guess-table-type)
           valign-separator-row-style
           column-width-list)

        ;; Not separator row, align each cell. ‘column-start’ is the
        ;; pixel position of the current point, i.e., after the left
        ;; bar.
        (setq column-start (valign--pixel-width-from-to
                            (line-beginning-position) (point) t))

        (valign--do-column column-idx
          (save-excursion
            ;; We are after the left bar (“|”).
            ;; Render the left bar.
            (valign--maybe-render-bar (1- (point)))
            ;; Start aligning this cell.
            ;;      Pixel width of the column.
            (let* ((col-width (nth column-idx column-width-list))
                   ;; left or right aligned.
                   (alignment (nth column-idx column-alignment-list))
                   ;; Pixel width of the cell.
                   (cell-width (valign--cell-content-width)))
              ;; Align cell.
              (cl-labels ((valign--put-ov
                           (beg end xpos)
                           (valign--put-overlay beg end 'display
                                                (valign--space xpos))))
                (pcase-let ((`(,cell-beg
                               ,content-beg
                               ,content-end
                               ,cell-end)
                             (valign--cell-content-config)))
                  (cond ((= cell-beg content-beg)
                         ;; This cell has only one space.
                         (valign--put-ov
                          cell-beg cell-end
                          (+ column-start col-width space-width)))
                        ;; Empty cell.  Sometimes empty cells are
                        ;; longer than other non-empty cells (see
                        ;; `valign--cell-width'), so we put overlay on
                        ;; all but the first white space.
                        ((valign--cell-empty-p)
                         (valign--put-ov
                          content-beg cell-end
                          (+ column-start col-width space-width)))
                        ;; A normal cell.
                        (t
                         (pcase alignment
                           ;; Align a left-aligned cell.
                           ('left (valign--put-ov
                                   content-end cell-end
                                   (+ column-start
                                      col-width space-width)))
                           ;; Align a right-aligned cell.
                           ('right (valign--put-ov
                                    cell-beg content-beg
                                    (+ column-start
                                       (- col-width cell-width)))))))))
              ;; Update ‘column-start’ for the next cell.
              (setq column-start (+ column-start
                                    col-width
                                    bar-width
                                    space-width)))))
        ;; Now we are at the last right bar.
        (valign--maybe-render-bar (1- (point)))))))

;;; Mode intergration

(defun valign-region (&optional beg end)
  "Align tables between BEG and END.
Supposed to be called from jit-lock.
Force align if FORCE non-nil."
  ;; Text sized can differ between frames, only use current frame.
  ;; We only align when this buffer is in a live window, because we
  ;; need ‘window-text-pixel-size’ to calculate text size.
  (let* ((beg (or beg (point-min)))
         (end (or end (point-max)))
         (fontified-end end))
    (when (window-live-p (get-buffer-window nil (selected-frame)))
      (save-excursion
        (goto-char beg)
        (while (and (search-forward "|" nil t)
                    (< (point) end))
          (condition-case err
              (valign-table-maybe)
            (error (message "Error when aligning table: %s"
                            (error-message-string err))))
          (valign--end-of-table)
          (setq fontified-end (point)))))
    (cons 'jit-lock-bounds (cons beg (max end fontified-end)))))

(defvar valign-mode)
(defun valign--buffer-advice (&rest _)
  "Realign whole buffer."
  (when valign-mode
    (valign-region)))

(defvar org-indent-agentized-buffers)
(defun valign--org-indent-advice (&rest _)
  "Re-align after org-indent is done."
  ;; See ‘org-indent-initialize-agent’.
  (when (not org-indent-agentized-buffers)
    (valign--buffer-advice)))

;; When an org link is in an outline fold, it’s full length
;; is used, when the subtree is unveiled, org link only shows
;; part of it’s text, so we need to re-align.  This function
;; runs after the region is flagged. When the text
;; is shown, jit-lock will make valign realign the text.
(defun valign--flag-region-advice (beg end flag &optional _)
  "Valign hook, realign table between BEG and END.
FLAG is the same as in ‘org-flag-region’."
  (when (and valign-mode (not flag))
    (with-silent-modifications
      (put-text-property beg end 'fontified nil))))

(defun valign--tab-advice (&rest _)
  "Force realign after tab so user can force realign."
  (when (and valign-mode
             (valign--at-table-p))
    (valign-table)))

(defun valign-reset-buffer ()
  "Remove alignment in the buffer."
  (with-silent-modifications
    (valign--clean-text-property (point-min) (point-max))
    (jit-lock-refontify)))

(defun valign-remove-advice ()
  "Remove advices added by valign."
  (interactive)
  (dolist (fn '(org-cycle
                org-table-blank-field
                markdown-cycle))
    (advice-remove fn #'valign--tab-advice))
  (dolist (fn '(text-scale-increase
                text-scale-decrease
                org-agenda-finalize-hook))
    (advice-remove fn #'valign--buffer-advice))
  (dolist (fn '(org-flag-region outline-flag-region))
    (advice-remove fn #'valign--flag-region-advice)))

;;; Userland

;;;###autoload
(define-minor-mode valign-mode
  "Visually align Org tables."
  :require 'valign
  :group 'valign
  :lighter valign-lighter
  (if (not (display-graphic-p))
      (when valign-mode
        (message "Valign mode has no effect in non-graphical display"))
    (if valign-mode
        (progn
          (add-hook 'jit-lock-functions #'valign-region 98 t)
          (dolist (fn '(org-cycle
                        ;; Why this function?  If you tab into an org
                        ;; field (cell) and start typing right away,
                        ;; org clears that field for you with this
                        ;; function.  The problem is, this functions
                        ;; messes up the overlay and makes the bar
                        ;; invisible.  So we have to fix the overlay
                        ;; after this function.
                        org-table-blank-field
                        markdown-cycle))
            (advice-add fn :after #'valign--tab-advice))
          (dolist (fn '(text-scale-increase
                        text-scale-decrease
                        org-agenda-finalize-hook
                        org-toggle-inline-images))
            (advice-add fn :after #'valign--buffer-advice))
          (dolist (fn '(org-flag-region outline-flag-region))
            (advice-add fn :after #'valign--flag-region-advice))
          (with-eval-after-load 'org-indent
            (advice-add 'org-indent-initialize-agent
                        :after #'valign--org-indent-advice))
          (add-hook 'org-indent-mode-hook #'valign--buffer-advice 0 t)
          (if valign-fancy-bar (cursor-sensor-mode))
          (jit-lock-refontify))
      (with-eval-after-load 'org-indent
        (advice-remove 'org-indent-initialize-agent
                       #'valign--org-indent-advice))
      (remove-hook 'jit-lock-functions #'valign-region t)
      (valign-reset-buffer)
      (cursor-sensor-mode -1))))

(provide 'valign)

;;; valign.el ends here

;; Local Variables:
;; sentence-end-double-space: t
;; End:
