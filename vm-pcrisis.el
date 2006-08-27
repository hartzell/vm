;;; vm-pcrisis.el --- wide-ranging auto-setup for personalities in VM
;;
;; Copyright (C) 1999 Rob Hodges, 2006 Robert Widhopf
;;
;; Package: Personality Crisis for VM
;; Homepage: http://www.robf.de/Hacking/elisp/
;; Author: Rob Hodges
;; Maintainer: Robert Widhopf-Fenk <hack@robf.de>
;; Filename: vm-pcrisis.el
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, you can either send email to this
;; program's maintainer or write to: The Free Software Foundation,
;; Inc.; 59 Temple Place, Suite 330; Boston, MA 02111-1307, USA.


;; DOCUMENTATION:
;; -------------
;;
;; Documentation is now in Texinfo and HTML formats.  You should have
;; downloaded one or the other along with this package at the URL
;; above.

;;; TODO:
;; - more lispification, Rob was a bit unfunctional

;;; Code:
(eval-when-compile
  (require 'vm-version)
  (require 'vm-message)
  (require 'vm-macro)
  ;; get the macros we need.
  (require 'cl))

(require 'vm-reply)

;; -------------------------------------------------------------------
;; Variables:
;; -------------------------------------------------------------------
(defconst vmpc-version "0.9"
  "Version of pcrisis.")

(defgroup vmpc nil
  "Manage personalities and more in VM."
  :group  'vm)

(defcustom vmpc-conditions ()
  "*List of conditions which will be checked by pcrisis."
  :group 'vmpc)

(defcustom vmpc-actions ()
  "*List of actions.
Actions are associated with conditions from `vmpc-conditions' by one of
`vmpc-actions-alist', `vmpc-reply-alist', `', `vmpc-forward-alist',
`vmpc-resend-alist',  `vmpc-newmail-alist' or `vmpc-automorph-alist'.

These are also the actions from which you can choose when using the newmail
features of Personality Crisis, or the `vmpc-prompt-for-profile' action."
  :type '(repeat (list (string :tag "Action name")
                       (sexp :tag "Condition")))
  :group 'vmpc)

(defun vmpc-alist-set (symbol value)
  "Used as :set for vmpc-*-alist variables.
Checks if the condition and all the actions exist."
  (while value
    (let ((condition (caar value))
          (actions   (cdar value)))
      (if (and condition (not (assoc condition vmpc-conditions)))
          (error "Condition '%s' does not exist!" condition))
      (while actions 
        (if (not (assoc (car actions) vmpc-actions))
            (error "Action '%s' does not exist!" (car actions)))
        (setq actions (cdr actions))))
    (setq value (cdr value)))
  (set symbol value))

(defun vmpc-defcustom-alist-type ()
  "Generate :type for vmpc-*-alist variables."
  (list 'repeat
        (list 'list 
              (append '(choice :tag "Condition")
                      (mapcar (lambda (c) (list 'const (car c))) vmpc-conditions)
                      '((string)))
              (list 'repeat :tag "Actions to run"
                    (append '(choice :tag "Action")
                            (mapcar (lambda (a) (list 'const (car a))) vmpc-actions)
                            '(string))))))

(defcustom vmpc-actions-alist ()
  "*An alist associating conditions with actions from `vmpc-actions'.
If you do not want to map actions for each state, e.g. for replying, forwarding,
resending, composing or automorphing, then set this one."
  :type (vmpc-defcustom-alist-type)
  :set 'vmpc-alist-set
  :group 'vmpc)

(defcustom vmpc-reply-alist ()
  "*An alist associating conditions with actions from `vmpc-actions' when replying."
  :type (vmpc-defcustom-alist-type)
  :set 'vmpc-alist-set
  :group 'vmpc)

(defcustom vmpc-forward-alist ()
  "*An alist associating conditions with actions from `vmpc-actions' when forwarding."
  :type (vmpc-defcustom-alist-type)
  :set 'vmpc-alist-set
  :group 'vmpc)

(defcustom vmpc-automorph-alist ()
  "*An alist associating conditions with actions from `vmpc-actions' when automorphing."
  :type (vmpc-defcustom-alist-type)
  :set 'vmpc-alist-set
  :group 'vmpc)

(defcustom vmpc-newmail-alist ()
  "*An alist associating conditions with actions from `vmpc-actions' when composing."
  :type (vmpc-defcustom-alist-type)
  :set 'vmpc-alist-set
  :group 'vmpc)

(defcustom vmpc-resend-alist ()
  "*An alist associating conditions with actions from `vmpc-actions' when resending."
  :type (vmpc-defcustom-alist-type)
  :set 'vmpc-alist-set
  :group 'vmpc)

(defcustom vmpc-auto-profiles-file "~/.vmpc-auto-profiles"
  "*File in which to save information used by `vmpc-prompt-for-profile'.
The user is welcome to change this value."
  :type 'file
  :group 'vmpc)

(defcustom vmpc-auto-profiles-expunge-days 100
  "*Number of days after which to expunge old address-profile associations.
Performance may suffer noticeably if this file becomes enormous, but in other
respects it is preferable for this value to be fairly high.  The value that is
right for you will depend on how often you send email to new addresses using
`vmpc-prompt-for-profile' (with the REMEMBER flag set to 'always or 'prompt)."
  :type 'integer
  :group 'vmpc)

(defvar vmpc-current-state nil
  "The current state of pcrisis.
It is one of 'reply, 'forward, 'resent, 'automorph or 'newmail.
It controls which actions/functions can/will be run.")

(defvar vmpc-current-buffer nil
  "The current buffer, i.e. 'none or 'composition.
It is 'none before running an adviced VM function and 'composition afterward,
i.e. when within the composition buffer.")

(defvar vmpc-saved-headers-alist nil
  "Alist of headers from the original message saved for later use.")

(defvar vmpc-actions-to-run nil
  "The actions to run.")

(defvar vmpc-true-conditions nil
  "The true conditions.")

(defvar vmpc-auto-profiles nil
  "The auto profiles as stored in `vmpc-auto-profiles-file'.")

;; An "exerlay" is an overlay in FSF Emacs and an extent in XEmacs.
;; It's not a real type; it's just the way I'm dealing with the damn
;; things to produce containers for the signature and pre-signature
;; which can be highlighted etc. and work on both platforms.

(defvar vmpc-pre-sig-exerlay ()
  "Don't mess with this.")

(make-variable-buffer-local 'vmpc-pre-sig-exerlay)

(defvar vmpc-sig-exerlay ()
  "Don't mess with this.")

(make-variable-buffer-local 'vmpc-sig-exerlay)

(defvar vmpc-pre-sig-face (progn (make-face 'vmpc-pre-sig-face
	    "Face used for highlighting the pre-signature.")
				 (set-face-foreground
				  'vmpc-pre-sig-face "forestgreen")
				 'vmpc-pre-sig-face)
  "Face used for highlighting the pre-signature.")

(defvar vmpc-sig-face (progn (make-face 'vmpc-sig-face
		"Face used for highlighting the signature.")
			     (set-face-foreground 'vmpc-sig-face
						  "steelblue")
			     'vmpc-sig-face)
  "Face used for highlighting the signature.")

(defvar vmpc-intangible-pre-sig 'nil
  "Whether to forbid the cursor from entering the pre-signature.")

(defvar vmpc-intangible-sig 'nil
  "Whether to forbid the cursor from entering the signature.")

(defvar vmpc-expect-default-signature 'nil
  "*Set this to 't if you have a signature-inserting function.
It will ensure that pcrisis correctly handles the signature .")


;; -------------------------------------------------------------------
;; Some easter-egg functionality:
;; -------------------------------------------------------------------

(defun vmpc-my-identities (&rest identities)
  "Setup pcrisis with the given IDENTITIES."
  (setq vmpc-conditions    '(("always true" t))
        vmpc-actions-alist '(("always true" "prompt for a profile"))
        vmpc-actions       '(("prompt for a profile" (vmpc-prompt-for-profile 'always))))
  (setq vmpc-actions
        (append (mapcar
                 (lambda (i)
                   (list i (list 'vmpc-substitute-header "From" i)))
                 identities)
                vmpc-actions)))

(defun vmpc-header-field-for-point ()
  "*Return a string indicating the mail header field point is in.
If point is not in a header field, returns nil."
  (save-excursion
    (unless (save-excursion
	      (re-search-backward (regexp-quote mail-header-separator)
				  (point-min) t))
      (re-search-backward "^\\([^ \t\n:]+\\):")
      (match-string 1))))

(defun vmpc-tab-header-or-tab-stop (&optional backward)
  "*If in a mail header field, moves to next useful header or body.
When moving to the message body, calls the `vmpc-automorph' function.
If within the message body, runs `tab-to-tab-stop'.
If BACKWARD is specified and non-nil, moves to previous useful header
field, whether point is in the body or the headers.
\"Useful header fields\" are currently, in order, \"To\" and
\"Subject\"."
  (interactive)
  (let ((curfield) (nextfield) (useful-headers '("To" "Subject")))
    (if (or (setq curfield (vmpc-header-field-for-point))
	    backward)
	(progn
	  (setq nextfield
		(- (length useful-headers)
		   (length (member curfield useful-headers))))
	  (if backward
	      (setq nextfield (nth (1- nextfield) useful-headers))
	    (setq nextfield (nth (1+ nextfield) useful-headers)))
	  (if nextfield
	      (mail-position-on-field nextfield)
	    (mail-text)
	    (vmpc-automorph))
	  )
      (tab-to-tab-stop)
      )))

(defun vmpc-backward-tab-header-or-tab-stop ()
  "*Wrapper for `vmpc-tab-header-or-tab-stop' with BACKWARD set."
  (interactive)
  (vmpc-tab-header-or-tab-stop t))


;; -------------------------------------------------------------------
;; Stuff for dealing with exerlays:
;; -------------------------------------------------------------------

(defun vmpc-set-overlay-insertion-types (overlay start end)
  "Set insertion types for OVERLAY from START to END.
In fact a new copy of OVERLAY with different insertion types at START and END
is created and returned.

START and END should be nil or t -- the marker insertion types at the start
and end.  This seems to be the only way you of changing the insertion types
for an overlay -- save the overlay properties that we care about, create a new
overlay with the new insertion types, set its properties to the saved ones.
Overlays suck.  Extents rule.  XEmacs got this right."
  (let* ((useful-props (list 'face 'intangible 'evaporate)) (saved-props)
	 (i 0) (len (length useful-props)) (startpos) (endpos) (new-ovl))
    (while (< i len)
      (setq saved-props (append saved-props (cons
		       (overlay-get overlay (nth i useful-props)) ())))
      (setq i (1+ i)))
    (setq startpos (overlay-start overlay))
    (setq endpos (overlay-end overlay))
    (delete-overlay overlay)
    (if (and startpos endpos)
	(setq new-ovl (make-overlay startpos endpos (current-buffer)
				    start end))
      (setq new-ovl (make-overlay 1 1 (current-buffer) start end))
      (vmpc-forcefully-detach-exerlay new-ovl))
    (setq i 0)
    (while (< i len)
      (overlay-put new-ovl (nth i useful-props) (nth i saved-props))
      (setq i (1+ i)))
    new-ovl))


(defun vmpc-set-extent-insertion-types (extent start end)
  "Set the insertion types of EXTENT from START to END.
START and END should be either nil or t, indicating the desired value
of the 'start-open and 'end-closed properties of the extent
respectively.
This is the XEmacs version of `vmpc-set-overlay-insertion-types'."
  ;; pretty simple huh?
  (set-extent-property extent 'start-open start)
  (set-extent-property extent 'end-closed end))


(defun vmpc-set-exerlay-insertion-types (exerlay start end)
  "Set the insertion types for EXERLAY from START to END.
In other words, EXERLAY is the name of the overlay or extent with a quote in
front.  START and END are the equivalent of the marker insertion types for the
start and end of the overlay/extent."
  (if vm-xemacs-p
      (vmpc-set-extent-insertion-types (symbol-value exerlay) start end)
    (set exerlay (vmpc-set-overlay-insertion-types (symbol-value exerlay)
						   start end))))


(defun vmpc-exerlay-start (exerlay)
  "Return buffer position of the start of EXERLAY."
  (if vm-xemacs-p
      (extent-start-position exerlay)
    (overlay-start exerlay)))


(defun vmpc-exerlay-end (exerlay)
  "Return buffer position of the end of EXERLAY."
  (if vm-xemacs-p
      (extent-end-position exerlay)
    (overlay-end exerlay)))


(defun vmpc-move-exerlay (exerlay new-start new-end)
  "Change EXERLAY to cover region from NEW-START to NEW-END."
  (if vm-xemacs-p
      (set-extent-endpoints exerlay new-start new-end (current-buffer))
    (move-overlay exerlay new-start new-end (current-buffer))))


(defun vmpc-set-exerlay-detachable-property (exerlay newval)
  "Set the 'detachable or 'evaporate property for EXERLAY to NEWVAL."
  (if vm-xemacs-p
      (set-extent-property exerlay 'detachable newval)
    (overlay-put exerlay 'evaporate newval)))


(defun vmpc-set-exerlay-intangible-property (exerlay newval)
  "Set the 'intangible or 'atomic property for EXERLAY to NEWVAL."
  (if vm-xemacs-p
      (progn
	(require 'atomic-extents)
	(set-extent-property exerlay 'atomic newval))
    (overlay-put exerlay 'intangible newval)))


(defun vmpc-set-exerlay-face (exerlay newface)
  "Set the face used by EXERLAY to NEWFACE."
  (if vm-xemacs-p
      (set-extent-face exerlay newface)
    (overlay-put exerlay 'face newface)))


(defun vmpc-forcefully-detach-exerlay (exerlay)
  "Leave EXERLAY in memory but detaches it from the buffer."
  (if vm-xemacs-p
      (detach-extent exerlay)
    (delete-overlay exerlay)))


(defun vmpc-make-exerlay (startpos endpos)
  "Create a new exerlay spanning from STARTPOS to ENDPOS."
  (if vm-xemacs-p
      (make-extent startpos endpos (current-buffer))
    (make-overlay startpos endpos (current-buffer))))


(defun vmpc-create-sig-and-pre-sig-exerlays ()
  "Create the extents in which the pre-sig and sig can reside.
Or overlays, in the case of GNU Emacs.  Thus, exerlays."
  (setq vmpc-pre-sig-exerlay (vmpc-make-exerlay 1 2))
  (setq vmpc-sig-exerlay (vmpc-make-exerlay 3 4))

  (vmpc-set-exerlay-detachable-property vmpc-pre-sig-exerlay t)
  (vmpc-set-exerlay-detachable-property vmpc-sig-exerlay t)
  (vmpc-forcefully-detach-exerlay vmpc-pre-sig-exerlay)
  (vmpc-forcefully-detach-exerlay vmpc-sig-exerlay)

  (vmpc-set-exerlay-face vmpc-pre-sig-exerlay 'vmpc-pre-sig-face)
  (vmpc-set-exerlay-face vmpc-sig-exerlay 'vmpc-sig-face)

  (vmpc-set-exerlay-intangible-property vmpc-pre-sig-exerlay
					vmpc-intangible-pre-sig)
  (vmpc-set-exerlay-intangible-property vmpc-sig-exerlay
					vmpc-intangible-sig)
  
  (vmpc-set-exerlay-insertion-types 'vmpc-pre-sig-exerlay t nil)
  (vmpc-set-exerlay-insertion-types 'vmpc-sig-exerlay t nil)

  ;; deal with signatures inserted by other things than vm-pcrisis:
  (if vmpc-expect-default-signature
      (save-excursion
	(let ((p-max (point-max))
	      (body-start (save-excursion (mail-text) (point)))
	      (sig-start nil))
	  (goto-char p-max)
	  (setq sig-start (re-search-backward "\n-- \n" body-start t))
	  (if sig-start
	      (vmpc-move-exerlay vmpc-sig-exerlay sig-start p-max))))))
  

;; -------------------------------------------------------------------
;; Functions for vmpc-actions:
;; -------------------------------------------------------------------

(defmacro vmpc-composition-buffer (&rest form)
  "Evaluate FORM if in the composition buffer.
That is to say, evaluates the form if you are really in a composition
buffer.  This function should not be called directly, only from within
the `vmpc-actions' list."
  (list 'if '(eq vmpc-current-buffer 'composition)
        (list 'eval (cons 'progn form))))

(put 'vmpc-composition-buffer 'lisp-indent-hook 'defun)

(defmacro vmpc-pre-function (&rest form)
  "Evaluate FORM if in pre-function state.
That is to say, evaluates the FORM before VM does its thing, whether
that be creating a new mail or a reply.  This function should not be
called directly, only from within the `vmpc-actions' list."
  (list 'if '(and (eq vmpc-current-buffer 'none)
                  (not (eq vmpc-current-state 'automorph)))
        (list 'eval (cons 'progn form))))

(put 'vmpc-pre-function 'lisp-indent-hook 'defun)

(defun vmpc-delete-header (hdrfield &optional entire)
  "Delete the contents of a HDRFIELD in the current mail message.
If ENTIRE is specified and non-nil, deletes the header field as well."
  (if (eq vmpc-current-buffer 'composition)
      (save-excursion
	(let ((start) (end))
	  (mail-position-on-field hdrfield)
	  (if entire
	      (setq end (+ (point) 1))
	    (setq end (point)))
	  (re-search-backward ": ")
	  (if entire
	      (setq start (progn (beginning-of-line) (point)))
	    (setq start (+ (point) 2)))
	  (delete-region start end)))))


(defun vmpc-insert-header (hdrfield content)
  "Insert to HDRFIELD the new CONTENT.
Both arguments are strings.  The field can either be present or not,
but if present, HDRCONT will be appended to the current header
contents."
  (if (eq vmpc-current-buffer 'composition)
      (save-excursion
	(mail-position-on-field hdrfield)
	(insert content))))

(defun vmpc-substitute-header (hdrfield content)
  "Substitute HDRFIELD with new CONTENT.
Both arguments are strings.  The field can either be present or not.
If the header field is present and already contains something, the
contents will be replaced, otherwise a new header is created."
  (if (eq vmpc-current-buffer 'composition)
      (save-excursion
	(vmpc-delete-header hdrfield)
	(vmpc-insert-header hdrfield content))))

(defun vmpc-get-current-header-contents (hdrfield &optional clump-sep)
  "Return the contents of HDRFIELD in the current mail message.
Returns an empty string if the header doesn't exist.  HDRFIELD should
be a string.  If the string CLUMP-SEP is specified, it means to return
the contents of all headers matching the regexp HDRFIELD, separated by
CLUMP-SEP."
  ;; This code is based heavily on vm-get-header-contents and vm-match-header.
  ;; Thanks Kyle :)
  (if (eq vmpc-current-state 'automorph)
      (save-excursion
	(let ((contents nil) (header-name-regexp "\\([^ \t\n:]+\\):")
	      (case-fold-search t) (temp-contents) (end-of-headers) (regexp))
          (if (not (listp hdrfield))
              (setq hdrfield (list hdrfield)))
	  ;; find the end of the headers:
	  (goto-char (point-min))
	  (or (re-search-forward
               (concat "^\\(" (regexp-quote mail-header-separator) "\\)$")
               nil t)
              (error "Cannot find mail-header-separator %S in buffer %S"
                     mail-header-separator (current-buffer)))
	  (setq end-of-headers (match-beginning 0))
	  ;; now rip through finding all the ones we want:
          (while hdrfield
            (setq regexp (concat "^\\(" (car hdrfield) "\\)"))
            (goto-char (point-min))
            (while (and (or (null contents) clump-sep)
                        (re-search-forward regexp end-of-headers t)
                        (save-excursion
                          (goto-char (match-beginning 0))
                          (let (header-cont-start header-cont-end)
                            (if (if (not clump-sep)
                                    (and (looking-at (car hdrfield))
                                         (looking-at header-name-regexp))
                                  (looking-at header-name-regexp))
                                (save-excursion
                                  (goto-char (match-end 0))
                                  ;; skip leading whitespace
                                  (skip-chars-forward " \t")
                                  (setq header-cont-start (point))
                                  (forward-line 1)
                                  (while (looking-at "[ \t]")
                                    (forward-line 1))
                                  ;; drop the trailing newline
                                  (setq header-cont-end (1- (point)))))
                            (setq temp-contents
                                  (buffer-substring header-cont-start
                                                    header-cont-end)))))
              (if contents
                  (setq contents
                        (concat contents clump-sep temp-contents))
                (setq contents temp-contents)))
            (setq hdrfield (cdr hdrfield)))

	  (if (null contents)
	      (setq contents ""))
	  contents ))))

(defun vmpc-get-current-body-text ()
  "Return the body text of the mail message in the current buffer."
  (if (eq vmpc-current-state 'automorph)
      (save-excursion
	(goto-char (point-min))
	(let ((start (re-search-forward
		      (concat "^" (regexp-quote mail-header-separator) "$")))
	      (end (point-max)))
	  (buffer-substring start end)))))


(defun vmpc-get-replied-header-contents (hdrfield &optional clump-sep)
  "Return the contents of HDRFIELD in the message being replied to.
If that header does not exist, returns an empty string.  If the string
CLUMP-SEP is specified, treat HDRFIELD as a regular expression and
return the contents of all header fields which match that regexp,
separated from each other by CLUMP-SEP."
  (if (and (eq vmpc-current-buffer 'none)
	   (memq vmpc-current-state '(reply forward resend)))
      (let ((mp (car (vm-select-marked-or-prefixed-messages 1)))
            content c)
        (if (not (listp hdrfield))
           (setq hdrfield (list hdrfield)))
        (while hdrfield
          (setq c (vm-get-header-contents mp (car hdrfield) clump-sep))
          (if c (setq content (cons c content)))
          (setq hdrfield (cdr hdrfield)))
        (or (mapconcat 'identity content "\n") ""))))

(defun vmpc-get-header-contents (hdrfield &optional clump-sep)
 "Return the contents of HDRFIELD."
 (cond ((and (eq vmpc-current-buffer 'none)
             (memq vmpc-current-state '(reply forward resend)))
        (vmpc-get-replied-header-contents hdrfield clump-sep))
       ((eq vmpc-current-state 'automorph)
        (vmpc-get-current-header-contents hdrfield clump-sep))
       (t (error "Unknow vmpc state %S" vmpc-current-state))))

(defun vmpc-get-replied-body-text ()
  "Return the body text of the message being replied to."
  (if (and (eq vmpc-current-buffer 'none)
	   (memq vmpc-current-state '(reply forward resend)))
      (save-excursion
	(let* ((mp (car (vm-select-marked-or-prefixed-messages 1)))
	       (message (vm-real-message-of mp))
	       start end)
	  (set-buffer (vm-buffer-of message))
	  (save-restriction
	    (widen)
	    (setq start (vm-text-of message))
	    (setq end (vm-end-of message))
	    (buffer-substring start end))))))

(defun vmpc-save-replied-header (hdrfield)
  "Save the contents of HDRFIELD in `vmpc-saved-headers-alist'.
Does nothing if that header doesn't exist."
  (let ((hdrcont (vmpc-get-replied-header-contents hdrfield)))
  (if (and (eq vmpc-current-buffer 'none)
	   (memq vmpc-current-state '(reply forward resend))
	   (not (equal hdrcont "")))
      (add-to-list 'vmpc-saved-headers-alist (cons hdrfield hdrcont)))))

(defun vmpc-get-saved-header (hdrfield)
  "Return the contents of HDRFIELD from `vmpc-saved-headers-alist'.
The alist in question is created by `vmpc-save-replied-header'."
  (if (and (eq vmpc-current-buffer 'composition)
	   (memq vmpc-current-state '(reply forward resend)))
      (cdr (assoc hdrfield vmpc-saved-headers-alist))))

(defun vmpc-substitute-replied-header (dest src)
  "Substitute header DEST with content from SRC.
For example, if the address you want to send your reply to is the same
as the contents of the \"From\" header in the message you are replying
to, use (vmpc-substitute-replied-header \"To\" \"From\"."
  (if (memq vmpc-current-state '(reply forward resend))
      (progn
	(if (eq vmpc-current-buffer 'none)
	    (vmpc-save-replied-header src))
	(if (eq vmpc-current-buffer 'composition)
	    (vmpc-substitute-header dest (vmpc-get-saved-header src))))))

(defun vmpc-get-header-extents (hdrfield)
  "Return buffer positions (START . END) for the contents of HDRFIELD.
If HDRFIELD does not exist, return nil."
  (if (eq vmpc-current-buffer 'composition)
      (save-excursion
        (let ((header-name-regexp "^\\([^ \t\n:]+\\):") (start) (end))
          (setq end
                (if (mail-position-on-field hdrfield t)
                    (point)
                  nil))
          (setq start
                (if (re-search-backward header-name-regexp (point-min) t)
                    (match-end 0)
                  nil))
          (and start end (<= start end) (cons start end))))))

(defun vmpc-substitute-within-header
  (hdrfield regexp to-string &optional append-if-no-match sep)
  "Replace in HDRFIELD strings matched by  REGEXP with TO-STRING.
HDRFIELD need not exist.  TO-STRING may contain references to groups
within REGEXP, in the same manner as `replace-regexp'.  If REGEXP is
not found in the header contents, and APPEND-IF-NO-MATCH is t,
TO-STRING will be appended to the header contents (with HDRFIELD being
created if it does not exist).  In this case, if the string SEP is
specified, it will be used to separate the previous header contents
from TO-STRING, unless HDRFIELD has just been created or was
previously empty."
  (if (eq vmpc-current-buffer 'composition)
      (save-excursion
        (let ((se (vmpc-get-header-extents hdrfield)) (found))
          (if se
              ;; HDRFIELD exists
              (save-restriction
                (narrow-to-region (car se) (cdr se))
                (goto-char (point-min))
                (while (re-search-forward regexp nil t)
                  (setq found t)
                  (replace-match to-string))
                (if (and (not found) append-if-no-match)
                    (progn
                      (goto-char (cdr se))
                      (if (and sep (not (equal (car se) (cdr se))))
                          (insert sep))
                      (insert to-string))))
            ;; HDRFIELD does not exist
            (if append-if-no-match
                (progn
                  (mail-position-on-field hdrfield)
                  (insert to-string))))))))


(defun vmpc-insert-signature (sig &optional pos)
  "Insert SIG at the end of `vmpc-sig-exerlay'.
SIG is a string.  If it is the name of a file, its contents is inserted --
otherwise the string itself is inserted.  Optional parameter POS means insert
the signature at POS if `vmpc-sig-exerlay' is detached."
  (if (eq vmpc-current-buffer 'composition)
      (progn
	(let ((end (or (vmpc-exerlay-end vmpc-sig-exerlay) pos)))
	  (save-excursion
	    (vmpc-set-exerlay-insertion-types 'vmpc-sig-exerlay nil t)
	    (vmpc-set-exerlay-detachable-property vmpc-sig-exerlay nil)
	    (vmpc-set-exerlay-intangible-property vmpc-sig-exerlay nil)
	    (unless end
	      (setq end (point-max))
	      (vmpc-move-exerlay vmpc-sig-exerlay end end))
	    (if (and pos (not (vmpc-exerlay-end vmpc-sig-exerlay)))
		(vmpc-move-exerlay vmpc-sig-exerlay pos pos))
	    (goto-char end)
	    (insert "\n-- \n")
	    (if (and (file-exists-p sig)
		     (file-readable-p sig)
		     (not (equal sig "")))
		(insert-file-contents sig)
	      (insert sig)))
	  (vmpc-set-exerlay-intangible-property vmpc-sig-exerlay
						vmpc-intangible-sig)
	  (vmpc-set-exerlay-detachable-property vmpc-sig-exerlay t)
	  (vmpc-set-exerlay-insertion-types 'vmpc-sig-exerlay t nil)))))
    

(defun vmpc-delete-signature ()
  "Deletes the contents of `vmpc-sig-exerlay'."
  (when (and (eq vmpc-current-buffer 'composition)
             ;; make sure it's not detached first:
             (vmpc-exerlay-start vmpc-sig-exerlay))
    (delete-region (vmpc-exerlay-start vmpc-sig-exerlay)
                   (vmpc-exerlay-end vmpc-sig-exerlay))
    (vmpc-forcefully-detach-exerlay vmpc-sig-exerlay)))


(defun vmpc-signature (sig)
  "Remove a current signature if present, and replace it with SIG.
If the string SIG is the name of a readable file, its contents are
inserted as the signature; otherwise SIG is inserted literally.  If
SIG is the empty string (\"\"), the current signature is deleted if
present, and that's all."
  (if (eq vmpc-current-buffer 'composition)
      (let ((pos (vmpc-exerlay-start vmpc-sig-exerlay)))
	(save-excursion
	  (vmpc-delete-signature)
	  (if (not (equal sig ""))
	      (vmpc-insert-signature sig pos))))))
  

(defun vmpc-insert-pre-signature (pre-sig &optional pos)
  "Insert PRE-SIG at the end of `vmpc-pre-sig-exerlay'.
PRE-SIG is a string.  If it's the name of a file, the file's contents
are inserted; otherwise the string itself is inserted.  Optional
parameter POS means insert the pre-signature at position POS if
`vmpc-pre-sig-exerlay' is detached."
  (if (eq vmpc-current-buffer 'composition)
      (progn
	(let ((end (or (vmpc-exerlay-end vmpc-pre-sig-exerlay) pos))
	      (sigstart (vmpc-exerlay-start vmpc-sig-exerlay)))
	  (save-excursion
	    (vmpc-set-exerlay-insertion-types 'vmpc-pre-sig-exerlay nil t)
	    (vmpc-set-exerlay-detachable-property vmpc-pre-sig-exerlay nil)
	    (vmpc-set-exerlay-intangible-property vmpc-pre-sig-exerlay nil)
	    (unless end
	      (if sigstart
		  (setq end sigstart)
		(setq end (point-max)))
	      (vmpc-move-exerlay vmpc-pre-sig-exerlay end end))
	    (if (and pos (not (vmpc-exerlay-end vmpc-pre-sig-exerlay)))
		(vmpc-move-exerlay vmpc-pre-sig-exerlay pos pos))
	    (goto-char end)
	    (insert "\n")
	    (if (and (file-exists-p pre-sig)
		     (file-readable-p pre-sig)
		     (not (equal pre-sig "")))
		(insert-file-contents pre-sig)
	      (insert pre-sig))))
	(vmpc-set-exerlay-intangible-property vmpc-pre-sig-exerlay
					      vmpc-intangible-pre-sig)
	(vmpc-set-exerlay-detachable-property vmpc-pre-sig-exerlay t)
	(vmpc-set-exerlay-insertion-types 'vmpc-pre-sig-exerlay t nil))))


(defun vmpc-delete-pre-signature ()
  "Deletes the contents of `vmpc-pre-sig-exerlay'."
  ;; make sure it's not detached first:
  (if (eq vmpc-current-buffer 'composition)
      (if (vmpc-exerlay-start vmpc-pre-sig-exerlay)
	  (progn
	    (delete-region (vmpc-exerlay-start vmpc-pre-sig-exerlay)
			   (vmpc-exerlay-end vmpc-pre-sig-exerlay))
	    (vmpc-forcefully-detach-exerlay vmpc-pre-sig-exerlay)))))


(defun vmpc-pre-signature (pre-sig)
  "Insert PRE-SIG at the end of `vmpc-pre-sig-exerlay' removing last pre-sig."
  (if (eq vmpc-current-buffer 'composition)
      (let ((pos (vmpc-exerlay-start vmpc-pre-sig-exerlay)))
	(save-excursion
	  (vmpc-delete-pre-signature)
	  (if (not (equal pre-sig ""))
	      (vmpc-insert-pre-signature pre-sig pos))))))


(defun vmpc-gregorian-days ()
  "Return the number of days elapsed since December 31, 1 B.C."
  ;; this code stolen from gnus-util.el :)
  (let ((tim (decode-time (current-time))))
    (timezone-absolute-from-gregorian
     (nth 4 tim) (nth 3 tim) (nth 5 tim))))


(defun vmpc-load-auto-profiles ()
  "Initialise `vmpc-auto-profiles' from `vmpc-auto-profiles-file'."
  (if (and (file-exists-p vmpc-auto-profiles-file)
	   (file-readable-p vmpc-auto-profiles-file))
      (save-excursion
	(set-buffer (get-buffer-create "*pcrisis-temp*"))
	(buffer-disable-undo (current-buffer))
	(erase-buffer)
	(insert-file-contents vmpc-auto-profiles-file)
	(goto-char (point-min))
	(setq vmpc-auto-profiles (read (current-buffer)))
	(kill-buffer (current-buffer)))))


(defun vmpc-save-auto-profiles ()
  "Save `vmpc-auto-profiles' to `vmpc-auto-profiles-file'."
  ;; TODO instead of recreating it all the time we should open it and modify
  ;; the buffer instead, then this would only be a save-buffer and updates
  ;; will be faster also for big files ... maybe we should use Berkley DB ...
  (if (file-writable-p vmpc-auto-profiles-file)
      (save-excursion
	(set-buffer (get-buffer-create "*pcrisis-temp*"))
	(buffer-disable-undo (current-buffer))
	(erase-buffer)
	(goto-char (point-min))
;	(prin1 vmpc-auto-profiles (current-buffer))
	(pp vmpc-auto-profiles (current-buffer))
	(write-region (point-min) (point-max)
		      vmpc-auto-profiles-file nil 'quietly)
	(kill-buffer (current-buffer)))
    ;; if file is not writable, signal an error:
    (error "Error: P-Crisis could not write to file %s"
	   vmpc-auto-profiles-file)))

(defun vmpc-fix-auto-profiles-file ()
  "Change `vmpc-auto-profiles-file' to the format used by v0.82+."
  (interactive)
  (vmpc-load-auto-profiles)
  (let ((len (length vmpc-auto-profiles)) (i 0) (day))
    (while (< i len)
      (setq day (cddr (nth i vmpc-auto-profiles)))
      (if (consp day)
	  (setcdr (cdr (nth i vmpc-auto-profiles)) (car day)))
      (setq i (1+ i))))
  (vmpc-save-auto-profiles)
  (setq vmpc-auto-profiles ()))


(defun vmpc-get-profile-for-address (addr)
  "Return profile for ADDR."
  (unless vmpc-auto-profiles
    (vmpc-load-auto-profiles))
  (let ((prof (cadr (assoc addr vmpc-auto-profiles))))
    (if prof
	(let ((today (vmpc-gregorian-days)))
	  ;; if we found for a profile for this address, we are still
	  ;; using it -- so "touch" the record to ensure it stays
	  ;; newer than vmpc-auto-profiles-expunge-days:
	  (setcdr (cdr (assoc addr vmpc-auto-profiles)) today)
	  (vmpc-save-auto-profiles)))
    prof ))


(defun vmpc-save-profile-for-address (prof addr)
  "Save profile PROF for ADDR, i.e. its association."
  (let ((today (vmpc-gregorian-days))
        (old-association (assoc addr vmpc-auto-profiles)))
    (if old-association
        (setq vmpc-auto-profiles (delete old-association vmpc-auto-profiles)))
    (setq vmpc-auto-profiles (cons (append (list addr prof) today) vmpc-auto-profiles))
    (when vmpc-auto-profiles-expunge-days
      ;; expunge old stuff from the list:
      (setq vmpc-auto-profiles
            (mapcar (lambda (p)
                      (if (> (- today (cddr p)) vmpc-auto-profiles-expunge-days)
                          nil
                        p))
                    vmpc-auto-profiles))
      (setq vmpc-auto-profiles (delete nil vmpc-auto-profiles)))
    (vmpc-save-auto-profiles)))


(defun vmpc-string-extract-address (str)
  "Find the first email address in the string STR and return it.
If no email address in found in STR, returns nil."
  (if (string-match "[^ \t,<]+@[^ \t,>]+" str)
      (match-string 0 str)))

(defun vmpc-split (string separators)
  "Return a list by splitting STRING at SEPARATORS."
  (let (result
        (not-separators (concat "^" separators)))
    (save-excursion
      (set-buffer (get-buffer-create " *split*"))
      (erase-buffer)
      (insert string)
      (goto-char (point-min))
      (while (progn
               (skip-chars-forward separators)
               (skip-chars-forward " \t\n\r")
               (not (eobp)))
        (let ((begin (point))
              p)
          (skip-chars-forward not-separators)
          (setq p (point))
          (skip-chars-backward " \t\n\r")
          (setq result (cons (buffer-substring begin (point)) result))
          (goto-char p)))
      (erase-buffer))
    (nreverse result)))

(defun vmpc-prompt-for-profile (&optional remember re-prompt)
  "Prompt the user for a profile and add it to the list of actions.
A profile is one of the sets of actions named in `vmpc-actions'.

REMEMBER can be set to 'always or 'prompt.  It figures out who your message is
going to, and saves a record in `vmpc-auto-profiles-file' which says to use that
profile for messages to that address in the future, instead of prompting you
for a profile the next time.  If set to 'prompt, it will ask before doing
this, otherwise it will do it automatically.

If you want to change a profile->action mapping call this function
interactivly within a composition buffer.  This will set RE-PROMPT
and thus will prompt you for a profile again."
  (interactive (progn (setq vmpc-current-state 'automorph)
                      (list 'prompt t)))
  
  (if (and (memq vmpc-current-state '(forward resend))
	   remember)
      (error "You can not have vmpc-prompt-for-profile remember when forwarding or resending"))
  (if (or (and (eq vmpc-current-buffer 'none)
	       (not (eq vmpc-current-state 'automorph)))
	  (eq vmpc-current-state 'automorph))
      (let ((headers (if (eq vmpc-current-state 'automorph)
                         '("To" "CC" "BCC")
                       '("Reply-To" "From" "CC")))
            addrs a prof dest)
        ;; search also other headers fro known addresses 
        (while (and headers (not prof))
          (setq addrs (vmpc-split (vmpc-get-header-contents (car headers)) ","))
          (while addrs
            (setq a (vmpc-string-extract-address (car addrs)))
            (if (vm-ignored-reply-to a)
                (setq a nil))
            (if (and (setq prof (vmpc-get-profile-for-address a)))
                (setq dest a headers nil)
              (if (and (not dest) a)
                  (setq dest a)))
            (setq addrs (cdr addrs)))
          (setq headers (cdr headers)))
        
	;; figure out which profile to use
        (if (setq prof (unless re-prompt (or prof (vmpc-get-profile-for-address dest))))
            (setq remember 'already)
          (setq prof (completing-read
                      (format "Profile for \"%s\" (\"%s\"): "
                              dest (caar vmpc-actions))
                      ;; omit those starting with (vmpc-prompt-for-profile ...
                      (mapcar
                       (lambda (a)
                         (if (not (eq (caadr a) 'vmpc-prompt-for-profile)) a))
                       vmpc-actions)
                      nil t nil nil (caar vmpc-actions))))

	(if (not (eq vmpc-current-state 'automorph))
	    ;; add it to the end of the list
            (add-to-list 'vmpc-actions-to-run prof t)
	  ;; or in automorph, run it immediately
	  (let ((vmpc-actions-to-run (list prof)))
            (vmpc-run-actions)))
	
	;; save the association of this profile with this destination address if applicable
	(if (or (and (eq remember 'prompt)
		     (y-or-n-p (format "Always use \"%s\" for \"%s\"? "
				       prof dest)))
		(eq remember 'always))
	    (vmpc-save-profile-for-address prof dest)))))

;; -------------------------------------------------------------------
;; Functions for vmpc-conditions:
;; -------------------------------------------------------------------

(defun vmpc-none-true-yet (&optional &rest exceptions)
  "True if none of the previous evaluated conditions was true.
This is a condition that can appear in `vmpc-conditions'.  If EXCEPTIONS are
specified, it means none were true except those.  For example, if you wanted
to check whether no conditions had yet matched with the exception of the two
conditions named \"default\" and \"blah\", you would make the call like this:
  (vmpc-none-true-yet \"default\" \"blah\")
Then it will return true regardless of whether \"default\" and \"blah\" had
matched."
  (let ((lenex (length exceptions)) (lentc (length vmpc-true-conditions)))
    (cond
     ((> lentc lenex)
      'nil)
     ((<= lentc lenex)
      (let ((i 0) (j 0) (k 0))
	(while (< i lenex)
	  (setq k 0)
	  (while (< k lentc)
	    (if (equal (nth i exceptions) (nth k vmpc-true-conditions))
		(setq j (1+ j)))
	    (setq k (1+ k)))
	  (setq i (1+ i)))
	(if (equal j lentc)
	    't
	  'nil))))))

(defun vmpc-other-cond (condition)
  "Return true if the specified CONDITION in `vmpc-conditions' matched.
CONDITION can only be the name of a condition specified earlier in
`vmpc-conditions' -- that is to say, any conditions which follow the one
containing `vmpc-other-cond' will show up as not having matched, because they
haven't yet been checked when this one is checked."
  (member condition vmpc-true-conditions))

(defun vmpc-header-match (hdrfield regexp &optional clump-sep num)
  "Return true if the contents of specified header HDRFIELD match REGEXP.
For automorph, this means the header in your message, when replying it means
the header in the message being replied to.

CLUMP-SEP is specified, treat HDRFIELD as a regular expression and
return the contents of all header fields which match that regexp,
separated from each other by CLUMP-SEP.

If NUM is specified return the match string NUM."
  (cond ((memq vmpc-current-state '(reply forward resend))
         (let ((hdr (vmpc-get-replied-header-contents hdrfield clump-sep)))
           (and (string-match regexp hdr)
                (if num (match-string num hdr) t))))
        ((eq vmpc-current-state 'automorph)
         (let ((hdr (vmpc-get-current-header-contents hdrfield clump-sep)))
           (and (string-match regexp hdr)
                (if num (match-string num hdr) t))))))

(defun vmpc-body-match (regexp)
  "Return non-nil if the contents of the message body match REGEXP.
For automorph, this means the body of your message; when replying it means the
body of the message being replied to."
  (cond ((and (memq vmpc-current-state '(reply forward resend))
	      (eq vmpc-current-buffer 'none))
	 (string-match regexp (vmpc-get-replied-body-text)))
	((eq vmpc-current-state 'automorph)
	 (string-match regexp (vmpc-get-current-body-text)))))


(defun vmpc-xor (&rest args)
  "Return true if one and only one argument in ARGS is true."
  (= 1 (length (delete nil args))))

;; -------------------------------------------------------------------
;; Support functions for the advices:
;; -------------------------------------------------------------------

(defun vmpc-true-conditions ()
  "Return a list of all true conditions.
Run this function in order to test/check your conditions."
  (interactive)
  (let (vmpc-true-conditions
        vmpc-current-state
        vmpc-current-buffer)
    (if (eq major-mode 'vm-mail-mode)
        (setq vmpc-current-state 'automorph
              vmpc-current-buffer 'composition)
      (setq vmpc-current-state (intern (completing-read
                                        "VMPC state (default is 'reply): "
                                        '(("reply") ("forward") ("resent"))
                                        nil t nil nil "reply"))
            vmpc-current-buffer 'none))
    (vm-follow-summary-cursor)
    (vm-select-folder-buffer)
    (vm-check-for-killed-summary)
    (vm-error-if-folder-empty)
    (vmpc-build-true-conditions-list)
    (message "VMPC true conditions: %S" vmpc-true-conditions)
    vmpc-true-conditions))

(defun vmpc-build-true-conditions-list ()
  "Built list of true conditions and store it in variable `vmpc-true-conditions'."
  (setq vmpc-true-conditions nil)
  (mapcar (lambda (c)
            (if (save-excursion (eval (cons 'progn (cdr c))))
                (setq vmpc-true-conditions (cons (car c) vmpc-true-conditions))))
          vmpc-conditions)
  (setq vmpc-true-conditions (reverse vmpc-true-conditions)))

(defun vmpc-build-actions-to-run-list ()
  "Built a list of the actions to run.
These are the true conditions mapped to actions.  Duplicates will be
eliminated.  You may run it in a composition buffer in order to see what
actions will be run."
  (interactive)
  (if (and (not vmpc-current-state) (interactive-p))
      (error "Run `vmpc-build-actions-to-run-list' in a composition buffer!"))
  (let ((alist (or (symbol-value (intern (format "vmpc-%s-alist" vmpc-current-state)))
                   vmpc-actions-alist))
        actions)
    (mapcar (lambda (c)
              (setq actions (cdr (assoc c alist)))
              ;; TODO warn about unbound conditions?
              (while actions
                (if (not (member (car actions) vmpc-actions-to-run))
                    (setq vmpc-actions-to-run (cons (car actions) vmpc-actions-to-run)))
                (setq actions (cdr actions))))
            vmpc-true-conditions))
  (setq vmpc-actions-to-run (reverse vmpc-actions-to-run))
  (if (interactive-p)
      (message "VMPC actions to run: %S" vmpc-actions-to-run))
  vmpc-actions-to-run)

(defun vmpc-read-actions ()
  "Read a list of actions to run and store it in `vmpc-actions-to-run'."
  (interactive)
  (let ((completion-table (mapcar (lambda (a) (list (car a))) vmpc-actions))
        action)
    (setq vmpc-actions-to-run nil)
    (while (not (string= "" (setq action (completing-read (format "VMPC action to run %S: "
                                                                  vmpc-actions-to-run)
                                                          completion-table nil t))))
      (setq vmpc-actions-to-run (cons action vmpc-actions-to-run)))
    (setq vmpc-actions-to-run (reverse vmpc-actions-to-run)))
  (if (interactive-p)
      (message "VMPC actions to run: %S" vmpc-actions-to-run))
  vmpc-actions-to-run)

(defun vmpc-run-actions ()
  "Run the actions stored in `vmpc-actions-to-run'."
  (interactive)
  (if (and (not vmpc-actions-to-run) (interactive-p))
      (vmpc-read-actions))

  (let ((actions vmpc-actions-to-run) form)
    (while actions
      (setq form (or (assoc (car actions) vmpc-actions)
                     (error "Action %S does not exist!" (car actions)))
            actions (cdr actions))
      (eval (cons 'progn (cdr form))))))

;; ------------------------------------------------------------------------
;; The main functions and advices -- these are the entry points to pcrisis:
;; ------------------------------------------------------------------------
(defun vmpc-init-vars (&optional state buffer)
  "Initialize pcrisis variables and optionally set STATE and BUFFER."
  (setq vmpc-saved-headers-alist nil
        vmpc-actions-to-run nil
        vmpc-true-conditions nil
        vmpc-current-state state
        vmpc-current-buffer (or buffer 'none)))

(defun vmpc-make-vars-local ()
  "Make the pcrisis vars buffer local.

When the vars are first set they cannot be made buffer local as we are not in
the composition buffer then.  Unfortunately making them buffer local while
they are bound by a `let' does not work, see the info for `make-local-variable'.
So we are using the global ones and make them buffer local when in the composition
buffer.  At least for saved-headers-alist this should fix a bug.

The current solution is not reentrant save, but there also should be no
recursion or concurrent calls."
  (let ((saved-headers-alist vmpc-saved-headers-alist)
        (actions-to-run      vmpc-actions-to-run)
        (true-conditions     vmpc-true-conditions)
        (current-state       vmpc-current-state))
    (vmpc-init-vars)
    (make-local-variable 'vmpc-saved-headers-alist)
    (make-local-variable 'vmpc-actions-to-run)
    (make-local-variable 'vmpc-true-conditions)
    (make-local-variable 'vmpc-current-state)
    (make-local-variable 'vmpc-current-buffer)
    (setq vmpc-saved-headers-alist saved-headers-alist
          vmpc-actions-to-run      actions-to-run
          vmpc-true-conditions     true-conditions
          vmpc-current-state       current-state
          vmpc-current-buffer      'composition)))

(defadvice vm-do-reply (around vmpc-reply activate)
  "*Reply to a message with pcrisis voodoo."
  (vmpc-init-vars 'reply)
  (vmpc-build-true-conditions-list)
  (vmpc-build-actions-to-run-list)
  (vmpc-run-actions)
  ad-do-it
  (vmpc-create-sig-and-pre-sig-exerlays)
  (vmpc-make-vars-local)
  (vmpc-run-actions))

(defadvice vm-mail (around vmpc-newmail activate)
  "*Start a new message with pcrisis voodoo."
  (vmpc-init-vars 'newmail)
  (vmpc-build-true-conditions-list)
  (vmpc-build-actions-to-run-list)
  (vmpc-run-actions)
  ad-do-it
  (vmpc-create-sig-and-pre-sig-exerlays)
  (vmpc-make-vars-local)
  (vmpc-run-actions))

(defadvice vm-compose-mail (around vmpc-compose-newmail activate)
  "*Start a new message with pcrisis voodoo."
  (vmpc-init-vars 'newmail)
  (vmpc-build-true-conditions-list)
  (vmpc-build-actions-to-run-list)
  (vmpc-run-actions)
  ad-do-it
  (vmpc-create-sig-and-pre-sig-exerlays)
  (vmpc-make-vars-local)
  (vmpc-run-actions))

(defadvice vm-forward-message (around vmpc-forward activate)
  "*Forward a message with pcrisis voodoo."
  ;; this stuff is already done when replying, but not here:
  (vm-follow-summary-cursor)
  (vm-select-folder-buffer)
  (vm-check-for-killed-summary)
  (vm-error-if-folder-empty)
  ;; the rest is almost exactly the same as replying:
  (vmpc-init-vars 'forward)
  (vmpc-build-true-conditions-list)
  (vmpc-build-actions-to-run-list)
  (vmpc-run-actions)
  ad-do-it
  (vmpc-create-sig-and-pre-sig-exerlays)
  (vmpc-make-vars-local)
  (vmpc-run-actions))

(defadvice vm-resend-message (around vmpc-resend activate)
  "*Resent a message with pcrisis voodoo."
  ;; this stuff is already done when replying, but not here:
  (vm-follow-summary-cursor)
  (vm-select-folder-buffer)
  (vm-check-for-killed-summary)
  (vm-error-if-folder-empty)
  ;; the rest is almost exactly the same as replying:
  (vmpc-init-vars 'resent)
  (vmpc-build-true-conditions-list)
  (vmpc-build-actions-to-run-list)
  (vmpc-run-actions)
  ad-do-it
  (vmpc-create-sig-and-pre-sig-exerlays)
  (vmpc-make-vars-local)
  (vmpc-run-actions))

;;;###autoload
(defun vmpc-automorph ()
  "*Change contents of the current mail message based on its own headers.
Headers and signatures can be changed; pre-signatures added; functions called.
For more information, see the Personality Crisis info file."
  (interactive)
  (vmpc-make-vars-local)
  (vmpc-init-vars 'automorph 'composition)
  (vmpc-build-true-conditions-list)
  (vmpc-build-actions-to-run-list)
  (vmpc-run-actions))

(provide 'vm-pcrisis)

;;; vm-pcrisis.el ends here